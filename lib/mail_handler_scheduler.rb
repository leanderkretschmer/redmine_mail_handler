require 'rufus-scheduler'

class MailHandlerScheduler
  @@scheduler = nil
  @@logger = nil

  def self.start
    return if @@scheduler && @@scheduler.up?
    
    @@logger = MailHandlerLogger.new
    # Verhindere Start, wenn E-Mail-Empfang via ENV deaktiviert ist
    env_flag = ENV['WITH_EMAIL_RECEIVING'].to_s.strip.downcase
    receiving_enabled = (env_flag == 'true' || env_flag == '1' || env_flag == 'yes')
    unless receiving_enabled
      @@logger.info("Scheduler not started: WITH_EMAIL_RECEIVING is not enabled (set to true/1)")
      return false
    end
    
    # Validiere IMAP-Konfiguration vor dem Start
    unless valid_imap_configuration?
      @@logger.error("Scheduler start aborted: Invalid or missing IMAP configuration")
      return false
    end
    
    @@scheduler = Rufus::Scheduler.new
    
    schedule_mail_import
    schedule_daily_reminders
    schedule_deferred_processing
      schedule_deferred_cleanup
    
    @@logger.info("Mail Handler Scheduler started with valid IMAP configuration")
    true
  end

  def self.stop
    if @@scheduler && @@scheduler.up?
      @@scheduler.shutdown
      @@logger&.info("Mail Handler Scheduler stopped")
    end
  end

  def self.restart
    stop
    start
  end

  def self.running?
    @@scheduler && @@scheduler.up?
  end

  private
  
  def self.get_current_hour_mail_count
    current_hour_start = Time.current.beginning_of_hour
    MailHandlerLog.where(
      created_at: current_hour_start..Time.current
    ).where("message LIKE ?", "%[LOAD-BALANCED]%").count
  end

  def self.schedule_mail_import
    settings = Setting.plugin_redmine_mail_handler
    
    return unless settings['auto_import_enabled'] == '1'
    
    if settings['load_balanced_enabled'] == '1'
      schedule_load_balanced_import(settings)
    else
      schedule_regular_import(settings)
    end
  end
  
  def self.schedule_regular_import(settings)
    interval = (settings['import_interval'] || '15').to_i
    interval_unit = settings['import_interval_unit'] || 'minutes'
    
    # Validiere Mindest-Intervall um DB-Überlastung zu vermeiden
    min_interval_seconds = case interval_unit
                          when 'seconds'
                            interval
                          when 'minutes'
                            interval * 60
                          else
                            interval * 60
                          end
    
    # Mindestens 30 Sekunden zwischen Imports um DB-Überlastung zu vermeiden
    if min_interval_seconds < 30
      @@logger&.warn("Import interval too short (#{interval} #{interval_unit}), using minimum of 30 seconds")
      interval = 30
      interval_unit = 'seconds'
    end
    
    # Bestimme das Intervall-Format für rufus-scheduler
    interval_format = case interval_unit
                     when 'seconds'
                       "#{interval}s"
                     when 'minutes'
                       "#{interval}m"
                     else
                       "#{interval}m" # Fallback auf Minuten
                     end
    
    @@scheduler.every interval_format do
      begin
        @@logger.info("Enqueuing scheduled mail import")
        MailHandlerImportJob.perform_later
      rescue => e
        @@logger.error("Scheduled mail import failed: #{e.message}")
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    unit_text = interval_unit == 'seconds' ? 'Sekunden' : 'Minuten'
    @@logger.info("Scheduled regular mail import every #{interval} #{unit_text}")
  end
  
  def self.schedule_load_balanced_import(settings)
    mails_per_hour = (settings['mails_per_hour'] || '60').to_i
    
    # Wenn 0 oder negativ, verwende unbegrenzten Import alle 5 Minuten
    if mails_per_hour <= 0
      @@scheduler.every '5m' do
        begin
          @@logger.info_load_balanced("Enqueuing mail import (unlimited)")
          MailHandlerImportJob.perform_later
        rescue => e
          @@logger.error("Load-balanced mail import failed: #{e.message}")
        ensure
          ActiveRecord::Base.connection_handler.clear_active_connections!
        end
      end
      
      @@logger.info("Scheduled load-balanced mail import every 5 minutes (unlimited)")
      return
    end
    
    # Berechne Intervall für gleichmäßige Verteilung über die Stunde
    # Mindestens alle 2 Minuten, maximal alle 30 Sekunden
    interval_minutes = [120.0 / mails_per_hour, 0.5].max
    interval_minutes = [interval_minutes, 2.0].min
    
    # Berechne Batch-Größe basierend auf dem Intervall
    imports_per_hour = 60.0 / interval_minutes
    batch_size = [mails_per_hour / imports_per_hour, 1].max.ceil
    
    interval_seconds = (interval_minutes * 60).to_i
    
    @@scheduler.every "#{interval_seconds}s" do
      begin
        # Prüfe ob das Stunden-Limit bereits erreicht ist
        current_hour_count = get_current_hour_mail_count
        remaining_mails = [mails_per_hour - current_hour_count, 0].max
        
        if current_hour_count >= mails_per_hour
          next_reset = Time.current.beginning_of_hour + 1.hour
          @@logger.info_load_balanced("#{current_hour_count} mails verarbeitet von #{mails_per_hour} mails erlaubt pro stunde (#{remaining_mails} mails übrig). Import pausiert bis zum Reset um #{next_reset.strftime('%H:%M')}")
          next
        end
        
        # Begrenze Batch-Größe auf verbleibende Mails
        actual_batch_size = [batch_size, remaining_mails].min
        @@logger.info_load_balanced("Starting mail import (max #{actual_batch_size} mails, #{current_hour_count} mails verarbeitet von #{mails_per_hour} mails erlaubt pro stunde, #{remaining_mails} mails übrig)")
        
        MailHandlerImportJob.perform_later(limit: actual_batch_size)
      rescue => e
        @@logger.error("Load-balanced mail import failed: #{e.message}")
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Scheduled load-balanced mail import: #{mails_per_hour} mails/hour, #{batch_size} mails every #{interval_minutes.round(1)} minutes")
  end

  def self.schedule_daily_reminders
    settings = Setting.plugin_redmine_mail_handler
    reminder_time = settings['reminder_time'] || '09:00'
    reminder_type = settings['reminder_type'] || 'redmine'
    
    return unless settings['reminder_enabled'] == '1'
    
    @@scheduler.cron "0 #{reminder_time.split(':')[1]} #{reminder_time.split(':')[0]} * * *" do
      begin
        @@logger.info("Starting daily reminder process using #{reminder_type} functionality")
        
        # Verwende die konfigurierte Reminder-Funktionalität
        ActiveRecord::Base.connection_pool.with_connection do
          send_bulk_reminder
        end
      rescue => e
        @@logger.error("Daily reminder process failed: #{e.message}")
      ensure
        # Stelle sicher, dass Verbindungen freigegeben werden
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Scheduled daily reminders at #{reminder_time} using #{reminder_type} system")
  end

  def self.schedule_deferred_processing
    settings = Setting.plugin_redmine_mail_handler
    deferred_recheck_time = settings['deferred_recheck_time'] || '02:00'
    
    return unless settings['deferred_enabled'] == '1'
    
    @@scheduler.cron "0 #{deferred_recheck_time.split(':')[1]} #{deferred_recheck_time.split(':')[0]} * * *" do
      begin
        @@logger.info("Starting scheduled deferred processing")
        
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.process_deferred_mails
        end
      rescue => e
        @@logger.error("Scheduled deferred processing failed: #{e.message}")
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Scheduled deferred processing at #{deferred_recheck_time}")
  end

  def self.schedule_deferred_cleanup
    settings = Setting.plugin_redmine_mail_handler
    cleanup_time = '03:00' # Feste Zeit für Cleanup, 1 Stunde nach Zurückgestellt-Verarbeitung
    
    return unless settings['deferred_enabled'] == '1'
    
    @@scheduler.cron "0 #{cleanup_time.split(':')[1]} #{cleanup_time.split(':')[0]} * * *" do
      begin
        @@logger.info("Starting scheduled deferred cleanup")
        
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.cleanup_expired_deferred
        end
      rescue => e
        @@logger.error("Scheduled deferred cleanup failed: #{e.message}")
      ensure
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Scheduled deferred cleanup at #{cleanup_time}")
  end

  def self.send_redmine_reminders
    # Verwende Redmines eingebaute Reminder-Funktionalität
    # Standardmäßig werden Reminder für Issues gesendet, die überfällig sind oder in den nächsten 7 Tagen fällig werden
    days = 7
    
    begin
      @@logger.info("Executing Redmine's built-in reminder task for #{days} days")
      
      # Führe Redmines Reminder-Task aus
      # Dies entspricht: bundle exec rake redmine:send_reminders days=7 RAILS_ENV="production"
      require 'rake'
      
      # Lade Redmine's Reminder-Task
      Rake.application.load_rakefile unless Rake.application.tasks.any?
      
      # Setze Umgebungsvariable für days Parameter
      ENV['days'] = days.to_s
      
      # Führe den Reminder-Task aus
      if Rake::Task.task_defined?('redmine:send_reminders')
        Rake::Task['redmine:send_reminders'].invoke
        @@logger.info("Successfully executed Redmine's reminder task")
      else
        @@logger.error("Redmine's send_reminders task not found")
      end
      
    rescue => e
      @@logger.error("Failed to execute Redmine's reminder task: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
    ensure
      # Bereinige Umgebungsvariable
      ENV.delete('days')
    end
    
    @@logger.info("Redmine reminder process completed")
  end





  # Validiere IMAP-Konfiguration
  def self.valid_imap_configuration?
    settings = Setting.plugin_redmine_mail_handler
    
    # Prüfe ob alle erforderlichen IMAP-Einstellungen vorhanden sind
    required_settings = ['imap_host', 'imap_port', 'imap_username', 'imap_password']
    
    required_settings.each do |setting|
      if settings[setting].blank?
        @@logger&.warn("Missing IMAP setting: #{setting}")
        return false
      end
    end
    
    # Teste IMAP-Verbindung
    begin
      service = MailHandlerService.new
      result = service.test_connection
      
      if result[:success]
        @@logger&.debug("IMAP configuration validation successful")
        return true
      else
        @@logger&.error("IMAP connection test failed: #{result[:error]}")
        return false
      end
    rescue => e
      @@logger&.error("IMAP configuration validation error: #{e.message}")
      return false
    end
  end
end
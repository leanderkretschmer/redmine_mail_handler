require 'rufus-scheduler'

class MailHandlerScheduler
  @@scheduler = nil
  @@logger = nil

  def self.start
    return if @@scheduler && @@scheduler.up?
    
    @@logger = MailHandlerLogger.new
    
    settings = Setting.plugin_redmine_mail_handler
    
    # Prüfe ob mindestens eine Funktion aktiviert ist, die den Scheduler benötigt
    auto_import_enabled = settings['auto_import_enabled'] == '1'
    reminder_enabled = settings['reminder_enabled'] == '1'
    deferred_enabled = settings['deferred_enabled'] == '1'
    
    unless auto_import_enabled || reminder_enabled || deferred_enabled
      @@logger.info("Scheduler start skipped: No scheduled features enabled")
      return false
    end
    
    # Validiere IMAP-Konfiguration nur wenn Mail-Import oder Deferred-Verarbeitung aktiviert ist
    if auto_import_enabled || deferred_enabled
      unless valid_imap_configuration?
        @@logger.error("Scheduler start aborted: Invalid or missing IMAP configuration (required for mail import/deferred processing)")
        return false
      end
    end
    
    @@scheduler = Rufus::Scheduler.new
    
    schedule_mail_import
    schedule_deferred_processing
    schedule_deferred_cleanup
    
    features = []
    features << "mail import" if auto_import_enabled
    features << "deferred processing" if deferred_enabled
    
    @@logger.info("Mail Handler Scheduler started with features: #{features.join(', ')}")
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
    logs = MailHandlerLogger.read_logs(max_lines: 5000)
    logs.count { |e| 
      e.created_at >= current_hour_start && 
      e.created_at <= Time.current && 
      e.message.include?("[LOAD-BALANCED]")
    }
  end

  def self.schedule_mail_import
    settings = Setting.plugin_redmine_mail_handler
    
    return unless settings['auto_import_enabled'] == '1'
    
    schedule_regular_import(settings)
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
        @@logger.info("Starting scheduled mail import")
        
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.import_mails
        end
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
          @@logger.info_load_balanced("Starting mail import (unlimited)")
          
          ActiveRecord::Base.connection_pool.with_connection do
            service = MailHandlerService.new
            service.import_mails
          end
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
        
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.import_mails(actual_batch_size)
        end
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
    
    # Parse Zeit-Format (HH:MM)
    hour, minute = reminder_time.split(':').map(&:to_i)
    
    # Validiere Zeit-Format
    unless hour && minute && hour.between?(0, 23) && minute.between?(0, 59)
      @@logger.error("Invalid reminder_time format: #{reminder_time}. Using default 09:00")
      hour, minute = 9, 0
    end
    
    # Cron-Format für rufus-scheduler: "minute hour day month weekday"
    cron_expression = "#{minute} #{hour} * * *"
    
    @@logger.info("Scheduling daily reminders with cron expression: #{cron_expression} (time: #{reminder_time})")
    
    @@scheduler.cron cron_expression do
      begin
        @@logger.info("=== REMINDER TRIGGERED === Starting daily reminder process at #{Time.current}")
        @@logger.info("Reminder settings: time=#{reminder_time}, type=#{reminder_type}")
        
        # Verwende die konfigurierte Reminder-Funktionalität
        ActiveRecord::Base.connection_pool.with_connection do
          send_redmine_reminders
        end
        
        @@logger.info("=== REMINDER COMPLETED === Daily reminder process finished successfully")
      rescue => e
        @@logger.error("=== REMINDER FAILED === Daily reminder process failed: #{e.message}")
        @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      ensure
        # Stelle sicher, dass Verbindungen freigegeben werden
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Successfully scheduled daily reminders at #{reminder_time} (#{hour}:#{minute.to_s.rjust(2, '0')}) using #{reminder_type} system")
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
    # Standardmäßig werden Reminder für Issues gesendet, die überfällig sind oder in den nächsten X Tagen fällig werden
    settings = Setting.plugin_redmine_mail_handler
    days = (settings['reminder_days'] || '7').to_i
    send_redmine_reminders_with_days(days)
  end

  def self.send_redmine_reminders_with_days(days = 7)
    begin
      @@logger.info("Executing Redmine's built-in reminder task for #{days} days")
      
      # Führe Redmines Reminder-Task aus
      # Dies entspricht: bundle exec rake redmine:send_reminders days=7 RAILS_ENV="production"
      require 'rake'
      
      # Lade Redmine's Rakefile falls noch nicht geladen
      unless Rake.application.tasks.any?
        Rake.application.init
        Rake.application.load_rakefile
      end
      
      # Setze Umgebungsvariable für days Parameter
      ENV['days'] = days.to_s
      
      # Führe den Reminder-Task aus
      if Rake::Task.task_defined?('redmine:send_reminders')
        task = Rake::Task['redmine:send_reminders']
        # WICHTIG: Re-enable den Task, damit er mehrfach ausgeführt werden kann
        task.reenable
        task.invoke
        @@logger.info("Successfully executed Redmine's reminder task")
      else
        @@logger.error("Redmine's send_reminders task not found - trying alternative method")
        # Fallback: Versuche Reminder direkt zu versenden
        send_reminders_directly(days)
      end
      
    rescue => e
      @@logger.error("Failed to execute Redmine's reminder task: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      # Versuche Fallback-Methode
      begin
        send_reminders_directly(days)
      rescue => e2
        @@logger.error("Fallback reminder method also failed: #{e2.message}")
      end
    ensure
      # Bereinige Umgebungsvariable
      ENV.delete('days')
    end
    
    @@logger.info("Redmine reminder process completed")
  end
  
  def self.send_reminders_directly(days)
    # Direkte Implementierung der Reminder-Logik basierend auf Redmine's Standard-Verhalten
    # Finde alle offenen Issues, die innerhalb der nächsten X Tage fällig werden
    begin
      target_date = days.days.from_now.to_date
      issues = Issue.open.where("due_date IS NOT NULL AND due_date <= ? AND due_date >= ?", target_date, Date.today)
      
      issues_count = 0
      errors_count = 0
      
      issues.find_each do |issue|
        begin
          # Versende Reminder nur wenn Issue einem aktiven Benutzer zugewiesen ist
          if issue.assigned_to && issue.assigned_to.is_a?(User) && issue.assigned_to.active?
            # Verwende Redmine's Mailer um Reminder zu versenden
            if defined?(Mailer) && Mailer.respond_to?(:issue_reminder)
              Mailer.issue_reminder(issue).deliver_now
              issues_count += 1
            else
              # Fallback: Erstelle eine einfache Reminder-E-Mail
              @@logger.warn("Mailer.issue_reminder not available for issue ##{issue.id}")
            end
          end
        rescue => e
          errors_count += 1
          @@logger.error("Failed to send reminder for issue ##{issue.id}: #{e.message}")
        end
      end
      
      @@logger.info("Sent #{issues_count} reminder emails for issues due within #{days} days (#{errors_count} errors)")
      
    rescue => e
      @@logger.error("Error in direct reminder sending: #{e.message}")
      raise
    end
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
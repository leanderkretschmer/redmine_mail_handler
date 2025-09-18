require 'rufus-scheduler'

class MailHandlerScheduler
  @@scheduler = nil
  @@logger = nil

  def self.start
    return if @@scheduler && @@scheduler.up?
    
    @@logger = MailHandlerLogger.new
    
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
        @@logger.info_load_balanced("Starting mail import (max #{batch_size} mails)")
        
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.import_mails(batch_size)
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

  # DEPRECATED: Diese Methode wird nicht mehr verwendet.
  # Das Plugin nutzt jetzt Redmines eingebaute Reminder-Funktionalität.
  def self.send_reminder_to_user(user, issues)
    @@logger.warn("DEPRECATED: send_reminder_to_user is no longer used. Plugin now uses Redmine's built-in reminder functionality.")
    return false
  end

  # Sende Test-Reminder basierend auf Konfiguration
  def self.send_test_reminder(to_email)
    reminder_type = Setting.plugin_redmine_mail_handler['reminder_type'] || 'redmine'
    
    if reminder_type == 'custom'
      send_custom_test_reminder(to_email)
    else
      send_redmine_test_reminder(to_email)
    end
  end
  
  # Sende Test-Reminder mit Redmines eingebauter Funktionalität
  def self.send_redmine_test_reminder(to_email)
    begin
      @@logger.info("Testing Redmine's built-in reminder functionality for #{to_email}")
      
      # Finde einen Benutzer mit der angegebenen E-Mail-Adresse über EmailAddress
      email_address_obj = EmailAddress.find_by(address: to_email.to_s.strip.downcase)
      user = email_address_obj&.user
      
      if user.nil?
        @@logger.error("No user found with email address: #{to_email}")
        return false
      end
      
      # Führe Redmines Reminder-Task für diesen spezifischen Benutzer aus
      require 'rake'
      
      # Lade Redmine's Reminder-Task
      Rake.application.load_rakefile unless Rake.application.tasks.any?
      
      # Setze Umgebungsvariablen für Test-Reminder
      ENV['days'] = '30'  # Erweitere Zeitraum für Test
      ENV['users'] = user.id.to_s  # Nur für diesen Benutzer
      
      # Führe den Reminder-Task aus
      if Rake::Task.task_defined?('redmine:send_reminders')
        Rake::Task['redmine:send_reminders'].reenable  # Erlaube mehrfache Ausführung
        Rake::Task['redmine:send_reminders'].invoke
        @@logger.info("Test reminder sent to #{to_email} using Redmine's built-in functionality")
        true
      else
        @@logger.error("Redmine's send_reminders task not found")
        false
      end
      
    rescue => e
      @@logger.error("Failed to send test reminder: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      false
    ensure
      # Bereinige Umgebungsvariablen
      ENV.delete('days')
      ENV.delete('users')
    end
  end
  
  # Sende Test-Reminder mit Custom-Plugin-Funktionalität
  def self.send_custom_test_reminder(to_email)
    begin
      @@logger.info("Testing custom plugin reminder functionality for #{to_email}")
      
      # Finde einen Benutzer mit der angegebenen E-Mail-Adresse über EmailAddress
      email_address_obj = EmailAddress.find_by(address: to_email.to_s.strip.downcase)
      user = email_address_obj&.user
      
      if user.nil?
        @@logger.error("No user found with email address: #{to_email}")
        return false
      end
      
      # Finde offene Issues für diesen Benutzer
      issues = Issue.joins(:assigned_to)
                   .where(assigned_to: user)
                   .where(status: IssueStatus.where(is_closed: false))
                   .where('#{Issue.table_name}.updated_on < ?', 30.days.ago)
                   .limit(10)
      
      if issues.empty?
        @@logger.info("No overdue issues found for user #{user.login}")
        return true
      end
      
      # Sende Custom-Reminder-E-Mail
      send_custom_reminder_email(user, issues)
      @@logger.info("Custom test reminder sent to #{to_email} with #{issues.count} issues")
      true
      
    rescue => e
      @@logger.error("Failed to send custom test reminder: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      false
    end
  end

  # Sende Bulk-Reminder basierend auf Konfiguration
  def self.send_bulk_reminder
    reminder_type = Setting.plugin_redmine_mail_handler['reminder_type'] || 'redmine'
    
    if reminder_type == 'custom'
      send_custom_bulk_reminder
    else
      send_redmine_bulk_reminder
    end
  end
  
  # Sende Bulk-Reminder an alle Benutzer mit Redmines eingebauter Funktionalität
  def self.send_redmine_bulk_reminder
    begin
      @@logger.info("Triggering bulk reminder for all users using Redmine's built-in functionality")
      
      # Führe Redmines Reminder-Task für alle Benutzer aus
      require 'rake'
      
      # Lade Redmine's Reminder-Task
      Rake.application.load_rakefile unless Rake.application.tasks.any?
      
      # Setze Umgebungsvariablen für Bulk-Reminder
      ENV['days'] = '30'  # Erweitere Zeitraum für Reminder
      # Keine spezifische Benutzer-ID setzen = alle Benutzer
      
      # Führe den Reminder-Task aus
      if Rake::Task.task_defined?('redmine:send_reminders')
        Rake::Task['redmine:send_reminders'].reenable  # Erlaube mehrfache Ausführung
        Rake::Task['redmine:send_reminders'].invoke
        @@logger.info("Bulk reminder sent to all users using Redmine's built-in functionality")
        true
      else
        @@logger.error("Redmine's send_reminders task not found")
        false
      end
      
    rescue => e
      @@logger.error("Failed to send bulk reminder: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      false
    ensure
      # Bereinige Umgebungsvariablen
      ENV.delete('days')
      ENV.delete('users')
    end
  end
  
  # Sende Custom-Bulk-Reminder an alle Benutzer
  def self.send_custom_bulk_reminder
    begin
      @@logger.info("Triggering custom bulk reminder for all users")
      
      # Finde alle aktiven Benutzer mit überfälligen Issues
      users_with_issues = User.active
                             .joins(:email_addresses)
                             .joins("LEFT JOIN #{Issue.table_name} ON #{Issue.table_name}.assigned_to_id = #{User.table_name}.id")
                             .joins("LEFT JOIN #{IssueStatus.table_name} ON #{Issue.table_name}.status_id = #{IssueStatus.table_name}.id")
                             .where("#{IssueStatus.table_name}.is_closed = ? AND #{Issue.table_name}.updated_on < ?", false, 30.days.ago)
                             .distinct
      
      sent_count = 0
      users_with_issues.find_each do |user|
        issues = Issue.joins(:assigned_to)
                     .where(assigned_to: user)
                     .where(status: IssueStatus.where(is_closed: false))
                     .where('#{Issue.table_name}.updated_on < ?', 30.days.ago)
                     .limit(10)
        
        if issues.any?
          send_custom_reminder_email(user, issues)
          sent_count += 1
        end
      end
      
      @@logger.info("Custom bulk reminder sent to #{sent_count} users")
      true
      
    rescue => e
      @@logger.error("Failed to send custom bulk reminder: #{e.message}")
      @@logger.error("Backtrace: #{e.backtrace.join("\n")}")
      false
    end
   end
   
   # Sende Custom-Reminder-E-Mail an einen Benutzer
   def self.send_custom_reminder_email(user, issues)
     begin
       # Hole die primäre E-Mail-Adresse des Benutzers
       email_address = user.email_addresses.where(is_default: true).first&.address || user.mail
       
       if email_address.blank?
         @@logger.warn("No email address found for user #{user.login}")
         return false
       end
       
       # Erstelle E-Mail-Inhalt
       subject = "[#{Setting.app_title}] Erinnerung: #{issues.count} überfällige Tickets"
       
       body = "Hallo #{user.firstname} #{user.lastname},\n\n"
       body += "Sie haben #{issues.count} überfällige Tickets, die Ihre Aufmerksamkeit benötigen:\n\n"
       
       issues.each do |issue|
         days_overdue = ((Time.current - issue.updated_on) / 1.day).to_i
         body += "• ##{issue.id}: #{issue.subject}\n"
         body += "  Projekt: #{issue.project.name}\n"
         body += "  Status: #{issue.status.name}\n"
         body += "  Überfällig seit: #{days_overdue} Tagen\n"
         body += "  Link: #{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}\n\n"
       end
       
       body += "Bitte überprüfen Sie diese Tickets und aktualisieren Sie den Status entsprechend.\n\n"
       body += "Mit freundlichen Grüßen,\n"
       body += "Ihr #{Setting.app_title} Team"
       
       # Sende E-Mail über Redmines Mailer
       mail = Mail.new do
         from     Setting.mail_from
         to       email_address
         subject  subject
         body     body
       end
       
       mail.delivery_method :smtp, {
         address: Setting.plugin_redmine_mail_handler['smtp_host'],
         port: Setting.plugin_redmine_mail_handler['smtp_port'].to_i,
         user_name: Setting.plugin_redmine_mail_handler['smtp_username'],
         password: Setting.plugin_redmine_mail_handler['smtp_password'],
         authentication: 'plain',
         enable_starttls_auto: Setting.plugin_redmine_mail_handler['smtp_tls'] == '1'
       }
       
       mail.deliver!
       @@logger.info("Custom reminder email sent to #{email_address} for user #{user.login}")
       true
       
     rescue => e
       @@logger.error("Failed to send custom reminder email to user #{user.login}: #{e.message}")
       false
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
require 'rufus-scheduler'

class MailHandlerScheduler
  @@scheduler = nil
  @@logger = nil

  def self.start
    return if @@scheduler && @@scheduler.up?
    
    @@logger = MailHandlerLogger.new
    @@scheduler = Rufus::Scheduler.new
    
    schedule_mail_import
    schedule_daily_reminders
    
    @@logger.info("Mail Handler Scheduler started")
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
    interval = (settings['import_interval'] || '15').to_i
    interval_unit = settings['import_interval_unit'] || 'minutes'
    
    return unless settings['auto_import_enabled'] == '1'
    
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
        
        # Verwende ActiveRecord::Base.connection_pool.with_connection für saubere DB-Verbindungen
        ActiveRecord::Base.connection_pool.with_connection do
          service = MailHandlerService.new
          service.import_mails
        end
      rescue => e
        @@logger.error("Scheduled mail import failed: #{e.message}")
      ensure
        # Stelle sicher, dass Verbindungen freigegeben werden
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    unit_text = interval_unit == 'seconds' ? 'Sekunden' : 'Minuten'
    @@logger.info("Scheduled mail import every #{interval} #{unit_text}")
  end

  def self.schedule_daily_reminders
    settings = Setting.plugin_redmine_mail_handler
    reminder_time = settings['reminder_time'] || '09:00'
    
    return unless settings['reminder_enabled'] == '1'
    
    @@scheduler.cron "0 #{reminder_time.split(':')[1]} #{reminder_time.split(':')[0]} * * *" do
      begin
        @@logger.info("Starting daily reminder process using Redmine's built-in functionality")
        
        # Verwende Redmines eingebaute Reminder-Funktionalität
        ActiveRecord::Base.connection_pool.with_connection do
          send_redmine_reminders
        end
      rescue => e
        @@logger.error("Daily reminder process failed: #{e.message}")
      ensure
        # Stelle sicher, dass Verbindungen freigegeben werden
        ActiveRecord::Base.connection_handler.clear_active_connections!
      end
    end
    
    @@logger.info("Scheduled daily reminders at #{reminder_time} using Redmine's built-in system")
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

  # Sende Test-Reminder mit Redmines eingebauter Funktionalität
  def self.send_test_reminder(to_email)
    begin
      @@logger.info("Testing Redmine's built-in reminder functionality for #{to_email}")
      
      # Finde einen Benutzer mit der angegebenen E-Mail-Adresse
      user = User.find_by(mail: to_email)
      
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
end
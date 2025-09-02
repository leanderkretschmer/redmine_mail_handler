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
    interval = (settings['import_interval'] || '5').to_i
    
    return unless settings['auto_import_enabled'] == '1'
    
    @@scheduler.every "#{interval}m" do
      begin
        @@logger.info("Starting scheduled mail import")
        service = MailHandlerService.new
        service.import_mails
      rescue => e
        @@logger.error("Scheduled mail import failed: #{e.message}")
      end
    end
    
    @@logger.info("Scheduled mail import every #{interval} minutes")
  end

  def self.schedule_daily_reminders
    settings = Setting.plugin_redmine_mail_handler
    reminder_time = settings['reminder_time'] || '09:00'
    
    return unless settings['reminder_enabled'] == '1'
    
    @@scheduler.cron "0 #{reminder_time.split(':')[1]} #{reminder_time.split(':')[0]} * * *" do
      begin
        @@logger.info("Starting daily reminder process")
        send_daily_reminders
      rescue => e
        @@logger.error("Daily reminder process failed: #{e.message}")
      end
    end
    
    @@logger.info("Scheduled daily reminders at #{reminder_time}")
  end

  def self.send_daily_reminders
    # Finde alle offenen Tickets, die älter als 1 Tag sind und heute noch nicht aktualisiert wurden
    overdue_issues = Issue.joins(:status)
                         .where(issue_statuses: { is_closed: false })
                         .where('issues.created_on < ?', 1.day.ago)
                         .where('issues.updated_on < ?', 1.day.ago)
                         .includes(:assigned_to, :project)
    
    # Gruppiere nach zugewiesenem Benutzer
    issues_by_user = overdue_issues.group_by(&:assigned_to)
    
    issues_by_user.each do |user, issues|
      next unless user && user.email_address.present?
      
      begin
        send_reminder_to_user(user, issues)
        @@logger.info("Sent reminder to #{user.email_address} for #{issues.count} issues")
      rescue => e
        @@logger.error("Failed to send reminder to #{user.email_address}: #{e.message}")
      end
    end
    
    @@logger.info("Daily reminder process completed")
  end

  def self.send_reminder_to_user(user, issues)
    # Validiere Benutzer-E-Mail
    if user.email_address.blank?
      @@logger.error("Benutzer #{user.firstname} #{user.lastname} hat keine E-Mail-Adresse")
      return false
    end
    
    # Validiere Absender-Adresse
    if Setting.mail_from.blank?
      @@logger.error("Absender-E-Mail-Adresse ist nicht in Redmine konfiguriert")
      return false
    end
    
    mail = Mail.new do
      from     Setting.mail_from
      to       user.email_address
      subject  "Redmine: Tägliche Erinnerung - #{issues.count} offene Tickets"
      
      body_text = "Hallo #{user.firstname},\n\n"
      body_text += "Sie haben #{issues.count} offene Tickets, die Ihre Aufmerksamkeit benötigen:\n\n"
      
      issues.each do |issue|
        body_text += "• ##{issue.id}: #{issue.subject}\n"
        body_text += "  Projekt: #{issue.project.name}\n"
        body_text += "  Status: #{issue.status.name}\n"
        body_text += "  Erstellt: #{issue.created_on.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M')}\n"
        body_text += "  URL: #{Setting.protocol}://#{Setting.host_name}/issues/#{issue.id}\n\n"
      end
      
      body_text += "Bitte überprüfen Sie diese Tickets und aktualisieren Sie den Status entsprechend.\n\n"
      body_text += "Mit freundlichen Grüßen,\n"
      body_text += "Ihr Redmine System\n\n"
      body_text += "Gesendet am: #{Time.current.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M:%S')}"
      
      body body_text
    end

    # Verwende Plugin-SMTP-Konfiguration
    begin
      require_relative 'mail_handler_service'
      service = MailHandlerService.new
      smtp_config = service.send(:get_smtp_settings)
      
      if smtp_config && smtp_config[:address].present?
        @@logger.debug("Using plugin SMTP settings for reminder: #{smtp_config[:address]}:#{smtp_config[:port]}")
        @@logger.debug("SSL: #{smtp_config[:ssl]}, STARTTLS: #{smtp_config[:enable_starttls_auto]}")
        
        mail.delivery_method :smtp, smtp_config
      else
        @@logger.error("Plugin-SMTP-Konfiguration ist nicht verfügbar für Reminder-E-Mails")
        return false
      end
    rescue => e
      @@logger.error("Fehler beim Laden der Plugin-SMTP-Konfiguration: #{e.message}")
      return false
    end

    mail.deliver!
    true
  end

  # Sende Test-Reminder
  def self.send_test_reminder(to_email)
    begin
      # Erstelle Test-Issues für Demo
      test_issues = [
        OpenStruct.new(
          id: 1234,
          subject: 'Test Ticket 1 - Beispiel Issue',
          project: OpenStruct.new(name: 'Test Projekt'),
          status: OpenStruct.new(name: 'Neu'),
          created_on: 3.days.ago
        ),
        OpenStruct.new(
          id: 5678,
          subject: 'Test Ticket 2 - Weiteres Beispiel',
          project: OpenStruct.new(name: 'Demo Projekt'),
          status: OpenStruct.new(name: 'In Bearbeitung'),
          created_on: 1.week.ago
        )
      ]
      
      user = OpenStruct.new(firstname: 'Test', email_address: to_email)
      send_reminder_to_user(user, test_issues)
      
      @@logger.info("Test reminder sent to #{to_email}")
      true
    rescue => e
      @@logger.error("Failed to send test reminder: #{e.message}")
      false
    end
  end
end
require 'net/imap'
require 'mail'
require 'mime/types'
require 'nokogiri'

class MailHandlerService
  include Redmine::I18n

  def initialize
    @settings = Setting.plugin_redmine_mail_handler
    @logger = MailHandlerLogger.new
  end

  # Hauptmethode für Mail-Import
  def import_mails(limit = nil)
    begin
      @logger.info("Starting mail import process")
      
      imap = connect_to_imap
      return false unless imap

      # Wähle Posteingang
      imap.select(@settings['inbox_folder'] || 'INBOX')
      
      # Hole ungelesene Mails
      message_ids = imap.search(['UNSEEN'])
      
      if limit
        message_ids = message_ids.first(limit.to_i)
      end

      @logger.info("Found #{message_ids.count} unread messages")
      
      processed_count = 0
      message_ids.each do |msg_id|
        begin
          process_message(imap, msg_id)
          processed_count += 1
        rescue => e
          @logger.error("Error processing message #{msg_id}: #{e.message}")
        end
      end

      @logger.info("Processed #{processed_count} messages successfully")
      
      imap.disconnect
      true
    rescue => e
      @logger.error("Mail import failed: #{e.message}")
      false
    end
  end

  # Teste IMAP-Verbindung
  def test_connection
    begin
      imap = connect_to_imap
      return false unless imap
      
      folders = imap.list('', '*')
      imap.disconnect
      
      @logger.info("IMAP connection test successful")
      { success: true, folders: folders.map(&:name) }
    rescue => e
      @logger.error("IMAP connection test failed: #{e.message}")
      { success: false, error: e.message }
    end
  end

  # Sende Test-Mail
  def send_test_mail(to_address, subject = 'Test Mail from Redmine Mail Handler')
    begin
      # Validiere E-Mail-Adresse
      if to_address.blank? || !to_address.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
        @logger.error("Ungültige E-Mail-Adresse: #{to_address}")
        return false
      end
      
      # Validiere Absender-Adresse
      if Setting.mail_from.blank?
        @logger.error("Absender-E-Mail-Adresse ist nicht in Redmine konfiguriert. Bitte konfigurieren Sie die E-Mail-Einstellungen.")
        return false
      end
      
      mail = Mail.new do
        from     Setting.mail_from
        to       to_address
        subject  subject
        body     "Dies ist eine Test-E-Mail vom Redmine Mail Handler Plugin.\n\nZeit: #{Time.current.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M:%S')}"
      end

      # Verwende Redmine's SMTP-Konfiguration
      smtp_settings = ActionMailer::Base.smtp_settings
      if smtp_settings.present? && smtp_settings[:address].present?
        @logger.debug("Using ActionMailer SMTP settings: #{smtp_settings[:address]}:#{smtp_settings[:port]}")
        mail.delivery_method :smtp, smtp_settings
      elsif Setting.email_delivery.present? && Setting.email_delivery['smtp_settings'].present?
        # Fallback auf Redmine's Standard-Konfiguration
        smtp_config = Setting.email_delivery['smtp_settings']
        if smtp_config['address'].present?
          @logger.debug("Using Redmine email_delivery settings: #{smtp_config['address']}:#{smtp_config['port']}")
          mail.delivery_method :smtp, {
            address: smtp_config['address'],
            port: smtp_config['port'] || 587,
            domain: smtp_config['domain'],
            user_name: smtp_config['user_name'],
            password: smtp_config['password'],
            authentication: smtp_config['authentication'] || :plain,
            enable_starttls_auto: smtp_config['enable_starttls_auto'] != false
          }
        else
          @logger.error("SMTP-Server-Adresse ist nicht konfiguriert. Bitte konfigurieren Sie die E-Mail-Einstellungen in Redmine.")
          return false
        end
      else
        @logger.error("Keine SMTP-Konfiguration gefunden. Bitte konfigurieren Sie die E-Mail-Einstellungen in Redmine.")
        return false
      end

      mail.deliver!
      @logger.info("Test mail sent successfully to #{to_address}")
      true
    rescue => e
      @logger.error("Failed to send test mail: #{e.message}")
      false
    end
  end

  private

  # Verbinde zu IMAP-Server
  def connect_to_imap
    begin
      # Validiere IMAP-Einstellungen
      if @settings['imap_host'].blank?
        @logger.error("IMAP-Host ist nicht konfiguriert. Bitte konfigurieren Sie die IMAP-Einstellungen in der Plugin-Konfiguration.")
        return nil
      end
      
      if @settings['imap_username'].blank? || @settings['imap_password'].blank?
        @logger.error("IMAP-Benutzername oder -Passwort ist nicht konfiguriert.")
        return nil
      end
      
      port = @settings['imap_port'].present? ? @settings['imap_port'].to_i : 993
      use_ssl = @settings['imap_ssl'] == '1'
      
      @logger.debug("Connecting to IMAP server #{@settings['imap_host']}:#{port} (SSL: #{use_ssl})")
      
      imap = Net::IMAP.new(
        @settings['imap_host'],
        port: port,
        ssl: use_ssl
      )
      
      imap.login(@settings['imap_username'], @settings['imap_password'])
      @logger.debug("Successfully connected to IMAP server #{@settings['imap_host']}")
      imap
    rescue => e
      @logger.error("Failed to connect to IMAP server #{@settings['imap_host'] || 'nicht konfiguriert'}: #{e.message}")
      nil
    end
  end

  # Verarbeite einzelne Nachricht
  def process_message(imap, msg_id)
    # Hole Mail-Daten
    msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
    mail = Mail.read_from_string(msg_data)
    
    @logger.debug("Processing mail from #{mail.from.first} with subject: #{mail.subject}")
    
    # Extrahiere Ticket-ID aus Betreff
    ticket_id = extract_ticket_id(mail.subject)
    
    # Finde oder erstelle Benutzer
    user = find_or_create_user(mail.from.first)
    
    # Verarbeite basierend auf Benutzer-Status und Ticket-ID
    if user && user.active?
      # Bekannter Benutzer
      if ticket_id
        # Bekannter Benutzer + Ticket-ID
        add_mail_to_ticket(mail, ticket_id, user)
      else
        # Bekannter Benutzer ohne Ticket-ID → Posteingang
        add_mail_to_inbox_ticket(mail, user)
      end
    elsif user && !user.active?
      # Unbekannter Benutzer (neu erstellt)
      if ticket_id
        # Unbekannter Benutzer + Ticket-ID
        add_mail_to_ticket(mail, ticket_id, user)
      else
        # Unbekannter Benutzer ohne Ticket-ID → ignorieren
        @logger.info("Ignoring mail from unknown user #{mail.from.first} without ticket ID")
      end
    else
      # Benutzer konnte nicht erstellt werden → ignorieren
      @logger.warn("Could not process mail from #{mail.from.first}")
    end
    
    # Mail als gelesen markieren und archivieren
    imap.store(msg_id, '+FLAGS', [:Seen])
    archive_message(imap, msg_id)
  end

  # Extrahiere Ticket-ID aus Betreff
  def extract_ticket_id(subject)
    return nil unless subject
    
    match = subject.match(/\[#(\d+)\]/)
    match ? match[1].to_i : nil
  end

  # Finde oder erstelle Benutzer
  def find_or_create_user(email)
    # Suche existierenden Benutzer
    user = User.find_by(mail: email.downcase)
    return user if user
    
    # Erstelle neuen Benutzer (deaktiviert)
    begin
      user = User.new(
        mail: email.downcase,
        firstname: email.split('@').first,
        lastname: 'Auto-created',
        login: email.downcase.gsub(/[^a-zA-Z0-9]/, '_'),
        status: User::STATUS_LOCKED,
        mail_notification: 'none'
      )
      
      if user.save
        @logger.info("Created new user for #{email} (locked)")
        user
      else
        @logger.error("Failed to create user for #{email}: #{user.errors.full_messages.join(', ')}")
        nil
      end
    rescue => e
      @logger.error("Error creating user for #{email}: #{e.message}")
      nil
    end
  end

  # Füge Mail zu spezifischem Ticket hinzu
  def add_mail_to_ticket(mail, ticket_id, user)
    ticket = Issue.find_by(id: ticket_id)
    unless ticket
      @logger.warn("Ticket ##{ticket_id} not found")
      return
    end
    
    # Dekodiere Mail-Inhalt
    content = decode_mail_content(mail)
    
    # Erstelle Journal-Eintrag
    journal = ticket.init_journal(user, content)
    
    if ticket.save
      @logger.info("Added mail content to ticket ##{ticket_id}")
    else
      @logger.error("Failed to add mail to ticket ##{ticket_id}: #{ticket.errors.full_messages.join(', ')}")
    end
  end

  # Füge Mail zu Posteingang-Ticket hinzu
  def add_mail_to_inbox_ticket(mail, user)
    inbox_ticket_id = @settings['inbox_ticket_id'].to_i
    return unless inbox_ticket_id > 0
    
    add_mail_to_ticket(mail, inbox_ticket_id, user)
  end

  # Dekodiere Mail-Inhalt
  def decode_mail_content(mail)
    content = ""
    
    # Betreff hinzufügen
    content += "**Betreff:** #{mail.subject}\n\n" if mail.subject
    
    # Text-Teil extrahieren
    if mail.multipart?
      text_part = mail.text_part
      html_part = mail.html_part
      
      if text_part
        content += text_part.decoded
      elsif html_part
        # HTML zu Text konvertieren
        doc = Nokogiri::HTML(html_part.decoded)
        content += doc.text
      end
    else
      content += mail.decoded
    end
    
    # Anhänge verarbeiten (falls vorhanden)
    if mail.attachments.any?
      content += "\n\n**Anhänge:**\n"
      mail.attachments.each do |attachment|
        content += "- #{attachment.filename} (#{attachment.content_type})\n"
      end
    end
    
    content
  end

  # Archiviere Nachricht
  def archive_message(imap, msg_id)
    return unless @settings['archive_folder'].present?
    
    begin
      imap.move(msg_id, @settings['archive_folder'])
      @logger.debug("Moved message #{msg_id} to archive")
    rescue => e
      @logger.warn("Failed to archive message #{msg_id}: #{e.message}")
    end
  end
end
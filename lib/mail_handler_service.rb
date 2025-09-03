require 'net/imap'
require 'mail'
require 'mime/types'
require 'nokogiri'
require 'timeout'
require 'openssl'

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
      # Verarbeite Nachrichten in umgekehrter Reihenfolge, da das Archivieren
      # die Message-IDs der nachfolgenden Nachrichten ungültig macht
      message_ids.reverse.each do |msg_id|
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
      
      # Bestimme Absender-Adresse
      from_address = get_smtp_from_address
      if from_address.blank?
        @logger.error("Absender-E-Mail-Adresse ist nicht konfiguriert. Bitte konfigurieren Sie die E-Mail-Einstellungen.")
        return false
      end
      
      mail = Mail.new do
        from     from_address
        to       to_address
        subject  subject
        body     "Dies ist eine Test-E-Mail vom Redmine Mail Handler Plugin.\n\nZeit: #{Time.current.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M:%S')}"
      end

      # Konfiguriere SMTP-Einstellungen
      smtp_config = get_smtp_configuration
      if smtp_config
        @logger.debug("Using SMTP settings: #{smtp_config[:address]}:#{smtp_config[:port]} (SSL: #{smtp_config[:ssl]}, STARTTLS: #{smtp_config[:enable_starttls_auto]})")
        mail.delivery_method :smtp, smtp_config
      else
        @logger.error("Keine SMTP-Konfiguration gefunden. Bitte konfigurieren Sie die E-Mail-Einstellungen.")
        return false
      end

      mail.deliver!
      @logger.info("Test mail sent successfully to #{to_address}")
      true
    rescue Net::SMTPAuthenticationError => e
      @logger.error("SMTP Authentication failed: #{e.message}. Bitte überprüfen Sie Benutzername und Passwort.")
      false
    rescue OpenSSL::SSL::SSLError => e
      if e.message.include?('wrong version number')
        @logger.error("SSL-Konfigurationsfehler: #{e.message}. Möglicherweise wird SSL auf einem STARTTLS-Port verwendet. Versuchen Sie Port 587 mit STARTTLS oder Port 465 mit SSL.")
      else
        @logger.error("SSL-Fehler: #{e.message}")
      end
      false
    rescue Errno::ECONNREFUSED => e
      @logger.error("Verbindung zum SMTP-Server verweigert: #{e.message}. Bitte überprüfen Sie Host und Port.")
      false
    rescue => e
      @logger.error("Failed to send test mail: #{e.message}")
      false
    end
  end

  # Liste verfügbare IMAP-Ordner auf (für Debugging)
  def list_imap_folders
    begin
      imap = connect_to_imap
      return [] unless imap
      
      folders = imap.list('', '*')
      folder_names = folders.map(&:name)
      
      @logger.info("Available IMAP folders: #{folder_names.join(', ')}")
      @logger.info("Configured archive folder: '#{@settings['archive_folder']}'")
      
      imap.disconnect
      folder_names
    rescue => e
      @logger.error("Failed to list IMAP folders: #{e.message}")
      []
    end
  end

  private

  # Verbinde zu IMAP-Server mit Retry-Logik
  def connect_to_imap(max_retries = 3)
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
    
    retry_count = 0
    
    begin
      @logger.debug("Connecting to IMAP server #{@settings['imap_host']}:#{port} (SSL: #{use_ssl}) - Attempt #{retry_count + 1}/#{max_retries + 1}")
      
      # Erstelle IMAP-Verbindung mit erweiterten Optionen
      imap_options = {
        port: port,
        ssl: use_ssl
      }
      
      # Füge SSL-Verifikationsoptionen hinzu wenn SSL verwendet wird
      if use_ssl
        imap_options[:ssl] = {
          verify_mode: OpenSSL::SSL::VERIFY_PEER,
          ca_file: nil,
          ca_path: nil,
          cert_store: nil
        }
      end
      
      # Timeout für Verbindungsaufbau setzen
      Timeout::timeout(30) do
        imap = Net::IMAP.new(@settings['imap_host'], **imap_options)
        
        # Login mit Timeout
        Timeout::timeout(15) do
          imap.login(@settings['imap_username'], @settings['imap_password'])
        end
        
        @logger.debug("Successfully connected to IMAP server #{@settings['imap_host']}")
        return imap
      end
      
    rescue Timeout::Error => e
      @logger.warn("IMAP connection timeout on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue Net::IMAP::NoResponseError => e
      @logger.warn("IMAP server returned no response on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue Net::IMAP::BadResponseError => e
      @logger.warn("IMAP server bad response on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue Errno::ECONNREFUSED => e
      @logger.warn("IMAP connection refused on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue Errno::EHOSTUNREACH => e
      @logger.warn("IMAP host unreachable on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue Errno::ETIMEDOUT => e
      @logger.warn("IMAP connection timed out on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue SocketError => e
      @logger.warn("IMAP socket error on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue OpenSSL::SSL::SSLError => e
      @logger.warn("IMAP SSL error on attempt #{retry_count + 1}: #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
      
    rescue => e
      @logger.warn("IMAP connection error on attempt #{retry_count + 1}: #{e.class.name} - #{e.message}")
      retry_count += 1
      
      if retry_count <= max_retries
        wait_time = [2 ** retry_count, 30].min
        @logger.info("Retrying IMAP connection in #{wait_time} seconds...")
        sleep(wait_time)
        retry
      end
    end
    
    @logger.error("Failed to connect to IMAP server #{@settings['imap_host']} after #{max_retries + 1} attempts")
    nil
  end

  # Verarbeite einzelne Nachricht
  def process_message(imap, msg_id)
    # Prüfe ob die Message-ID noch gültig ist
    begin
      imap.fetch(msg_id, 'UID')
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} is invalid or already processed, skipping")
        return
      else
        raise e
      end
    end
    
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
    # Wichtig: Erst markieren, dann archivieren, da move() die Message-ID ungültig macht
    begin
      imap.store(msg_id, '+FLAGS', [:Seen])
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} already processed or invalid, skipping mark as seen")
      else
        @logger.warn("Failed to mark message #{msg_id} as seen: #{e.message}")
      end
    rescue => e
      @logger.warn("Failed to mark message #{msg_id} as seen: #{e.message}")
    end
    
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
    # Suche existierenden Benutzer über EmailAddress-Objekt
    email_address_obj = EmailAddress.find_by(address: email.downcase)
    user = email_address_obj&.user
    return user if user
    
    # Erstelle neuen Benutzer (deaktiviert)
    begin
      user = User.new(
        firstname: email.split('@').first,
        lastname: 'Auto-created',
        login: email.downcase.gsub(/[^a-zA-Z0-9]/, '_'),
        status: User::STATUS_LOCKED,
        mail_notification: 'none'
      )
      
      # Erstelle EmailAddress-Objekt für Redmine 6.x
      email_address = EmailAddress.new(
        address: email.downcase,
        is_default: true
      )
      user.email_addresses = [email_address]
      
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
      @logger.warn("Ticket ##{ticket_id} not found, forwarding to inbox ticket")
      # Fallback: Leite E-Mail an Posteingang-Ticket weiter
      add_mail_to_inbox_ticket(mail, user)
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
    unless inbox_ticket_id > 0
      @logger.warn("No inbox ticket ID configured, cannot process mail from #{mail.from.first}")
      return
    end
    
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
      # Prüfe ob die Message-ID noch gültig ist
      imap.fetch(msg_id, 'UID')
      
      # Prüfe ob der Archiv-Ordner existiert, erstelle ihn falls nötig
      ensure_archive_folder_exists(imap)
      
      imap.move(msg_id, @settings['archive_folder'])
      @logger.debug("Moved message #{msg_id} to archive folder '#{@settings['archive_folder']}'")
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} already moved or invalid, skipping archive")
      elsif e.message.include?('TRYCREATE')
        @logger.info("Archive folder '#{@settings['archive_folder']}' does not exist, creating it...")
        create_archive_folder(imap)
        # Versuche erneut zu verschieben
        begin
          imap.move(msg_id, @settings['archive_folder'])
          @logger.debug("Moved message #{msg_id} to newly created archive folder")
        rescue => retry_e
          @logger.error("Failed to move message #{msg_id} to archive after creating folder: #{retry_e.message}")
        end
      else
        @logger.warn("Failed to archive message #{msg_id}: #{e.message}")
      end
    rescue => e
      @logger.warn("Failed to archive message #{msg_id}: #{e.message}")
    end
  end

  # Stelle sicher, dass der Archiv-Ordner existiert
  def ensure_archive_folder_exists(imap)
    return unless @settings['archive_folder'].present?
    
    begin
      # Liste alle Ordner auf
      folders = imap.list('', '*')
      folder_names = folders.map(&:name)
      
      unless folder_names.include?(@settings['archive_folder'])
        @logger.info("Archive folder '#{@settings['archive_folder']}' not found, creating it...")
        create_archive_folder(imap)
      end
    rescue => e
      @logger.warn("Could not check archive folder existence: #{e.message}")
    end
  end

  # Erstelle den Archiv-Ordner
  def create_archive_folder(imap)
    begin
      imap.create(@settings['archive_folder'])
      @logger.info("Created archive folder '#{@settings['archive_folder']}'")
    rescue => e
      @logger.error("Failed to create archive folder '#{@settings['archive_folder']}': #{e.message}")
    end
  end

  # Hole SMTP-Konfiguration
  def get_smtp_configuration
    # Prüfe ob Plugin-eigene SMTP-Einstellungen verwendet werden sollen
    if @settings['smtp_same_as_imap'] == '1'
      # Verwende IMAP-Einstellungen für SMTP
      return get_smtp_from_imap_settings
    elsif @settings['smtp_host'].present?
      # Verwende Plugin-eigene SMTP-Einstellungen
      return get_plugin_smtp_settings
    else
      # Fallback auf Redmine's SMTP-Konfiguration
      return get_redmine_smtp_settings
    end
  end

  # SMTP-Einstellungen aus IMAP-Konfiguration ableiten
  def get_smtp_from_imap_settings
    return nil if @settings['imap_host'].blank?
    
    # Konvertiere IMAP-Host zu SMTP-Host (häufige Konventionen)
    smtp_host = @settings['imap_host'].gsub(/^imap\./, 'smtp.')
    
    # Bestimme Port und SSL-Einstellungen basierend auf IMAP-SSL
    if @settings['imap_ssl'] == '1'
      # IMAP SSL -> SMTP SSL (Port 465)
      smtp_port = 465
      use_ssl = true
      use_starttls = false
    else
      # IMAP ohne SSL -> SMTP mit STARTTLS (Port 587)
      smtp_port = 587
      use_ssl = false
      use_starttls = true
    end
    
    {
      address: smtp_host,
      port: smtp_port,
      domain: smtp_host.split('.')[1..-1].join('.'),
      user_name: @settings['imap_username'],
      password: @settings['imap_password'],
      authentication: :plain,
      enable_starttls_auto: use_starttls,
      ssl: use_ssl
    }
  end

  # Plugin-eigene SMTP-Einstellungen
  def get_plugin_smtp_settings
    smtp_port = @settings['smtp_port'].present? ? @settings['smtp_port'].to_i : 587
    
    # Bestimme SSL-Einstellungen basierend auf Port und SSL-Flag
    if @settings['smtp_ssl'] == '1' || smtp_port == 465
      # SSL-Verbindung (normalerweise Port 465)
      use_ssl = true
      use_starttls = false
    else
      # STARTTLS-Verbindung (normalerweise Port 587 oder 25)
      use_ssl = false
      use_starttls = true
    end
    
    {
      address: @settings['smtp_host'],
      port: smtp_port,
      domain: @settings['smtp_host'].split('.')[1..-1].join('.'),
      user_name: @settings['smtp_username'],
      password: @settings['smtp_password'],
      authentication: :plain,
      enable_starttls_auto: use_starttls,
      ssl: use_ssl
    }
  end

  # Redmine's SMTP-Einstellungen
  def get_redmine_smtp_settings
    # Versuche ActionMailer-Einstellungen
    smtp_settings = ActionMailer::Base.smtp_settings
    if smtp_settings.present? && smtp_settings[:address].present?
      return smtp_settings
    end
    
    # Fallback auf Redmine's email_delivery Einstellungen
    if Setting.email_delivery.present? && Setting.email_delivery['smtp_settings'].present?
      smtp_config = Setting.email_delivery['smtp_settings']
      if smtp_config['address'].present?
        return {
          address: smtp_config['address'],
          port: smtp_config['port'] || 587,
          domain: smtp_config['domain'],
          user_name: smtp_config['user_name'],
          password: smtp_config['password'],
          authentication: smtp_config['authentication'] || :plain,
          enable_starttls_auto: smtp_config['enable_starttls_auto'] != false
        }
      end
    end
    
    nil
  end

  # Bestimme Absender-Adresse
  def get_smtp_from_address
    # Verwende Plugin-Einstellungen falls verfügbar
    if @settings['smtp_same_as_imap'] == '1' && @settings['imap_username'].present?
      return @settings['imap_username']
    elsif @settings['smtp_username'].present?
      return @settings['smtp_username']
    else
      # Fallback auf Redmine's Standard-Absender
      return Setting.mail_from
    end
  end

  # Alias für Rückwärtskompatibilität
  alias_method :get_smtp_settings, :get_smtp_configuration
end
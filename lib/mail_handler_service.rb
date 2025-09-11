require 'net/imap'
require 'mail'
require 'mime/types'
require 'nokogiri'
require 'premailer'
require 'timeout'
require 'openssl'
require 'tempfile'
require 'cgi'

class MailHandlerService
  include Redmine::I18n

  def initialize
    @settings = Setting.plugin_redmine_mail_handler
    @logger = MailHandlerLogger.new
  end

  # Hauptmethode für Mail-Import
  def import_mails(limit = nil)
    begin
      # Setze Logger-Status zurück für neue Import-Session
      MailHandlerLogger.reset_logger_state
      
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
        rescue Net::IMAP::BadResponseError => e
          if e.message.include?('Invalid messageset')
            @logger.debug("Message #{msg_id} is invalid or already processed, skipping")
          else
            @logger.error("IMAP error processing message #{msg_id}: #{e.message}")
          end
        rescue Mail::Field::ParseError => e
          @logger.error("Mail parsing error for message #{msg_id}: #{e.message}")
        rescue ActiveRecord::RecordInvalid => e
          @logger.error("Database validation error for message #{msg_id}: #{e.message}")
        rescue => e
          @logger.error("Unexpected error processing message #{msg_id}: #{e.class.name} - #{e.message}")
          @logger.debug("Backtrace: #{e.backtrace.first(5).join('\n')}")
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

  # Verarbeite zurückgestellte Mails
  def process_deferred_mails
    @logger.info("Starting deferred mail processing")
    
    imap = connect_to_imap
    return unless imap
    
    begin
      deferred_folder = @settings['deferred_folder'] || 'Deferred'
      
      # Prüfe ob Zurückgestellt-Ordner existiert
      begin
        imap.select(deferred_folder)
      rescue Net::IMAP::NoResponseError
        @logger.info("Deferred folder '#{deferred_folder}' does not exist, nothing to process")
        return
      end
      
      @logger.info("Selected deferred folder: #{deferred_folder}")
      
      # Hole alle Nachrichten-IDs aus Zurückgestellt
      message_ids = imap.search(['ALL'])
      @logger.info("Found #{message_ids.length} messages in deferred")
      
      if message_ids.empty?
        @logger.info("No deferred messages to process")
        return
      end
      
      processed_count = 0
      expired_count = 0
      
      # Verarbeite jede zurückgestellte Nachricht
      message_ids.each do |msg_id|
        begin
          result = process_deferred_message(imap, msg_id)
          case result
          when :processed
            processed_count += 1
          when :expired
            expired_count += 1
          end
        rescue => e
          @logger.error("Error processing deferred message #{msg_id}: #{e.class.name} - #{e.message}")
          # Weiter mit nächster Nachricht
        end
      end
      
      @logger.info("Deferred processing completed: #{processed_count} processed, #{expired_count} expired")
      
    rescue => e
      @logger.error("Deferred processing failed: #{e.class.name} - #{e.message}")
      @logger.debug("Backtrace: #{e.backtrace.first(10).join('\n')}")
    ensure
      imap&.disconnect
    end
   end

  # Bereinige abgelaufene Zurückgestellt-Einträge
  def cleanup_expired_deferred
    @logger.info("Starting cleanup of expired deferred entries")
    
    begin
      # Lösche abgelaufene Einträge aus der Datenbank
      expired_entries = MailDeferredEntry.expired
      deleted_count = expired_entries.count
      
      expired_entries.delete_all
      
      @logger.info("Cleanup completed: #{deleted_count} expired deferred entries removed")
      deleted_count
    rescue => e
      @logger.error("Failed to cleanup expired deferred entries: #{e.message}")
      @logger.error("Backtrace: #{e.backtrace.join("\n")}")
      0
    end
  end

  # Verarbeite einzelne zurückgestellte Nachricht
  def process_deferred_message(imap, msg_id)
    # Hole Mail-Daten
    begin
      msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
      
      if msg_data.blank?
        @logger.error("Empty mail data for deferred message #{msg_id}, skipping")
        return :skipped
      end
      
      mail = Mail.read_from_string(msg_data)
      
      if mail.nil?
        @logger.error("Failed to parse deferred mail object for message #{msg_id}, skipping")
        return :skipped
      end
      
    rescue => e
      @logger.error("Failed to fetch deferred mail data for message #{msg_id}: #{e.message}")
      return :skipped
    end
    
    # Prüfe Zurückgestellt-Status
    deferred_entry = MailDeferredEntry.find_by(message_id: mail.message_id)
    
    if deferred_entry&.expired?
      # Zurückstellung abgelaufen → in Archiv verschieben
      @logger.info("Deferral expired for message #{msg_id}, moving to archive")
      archive_message(imap, msg_id, mail)
      deferred_entry.destroy if deferred_entry
      return :expired
    end
    
    # Prüfe ob Benutzer jetzt existiert
    from_address = mail.from&.first
    return :skipped if from_address.blank?
    
    existing_user = find_existing_user(from_address)
    
    if existing_user
      # Benutzer existiert jetzt → Mail normal verarbeiten
      @logger.info("User #{from_address} now exists, processing deferred message #{msg_id}")
      
      # Extrahiere Ticket-ID (falls vorhanden)
      ticket_id = extract_ticket_id(mail.subject)
      
      if ticket_id
        add_mail_to_ticket(mail, ticket_id, existing_user)
      else
        add_mail_to_inbox_ticket(mail, existing_user)
      end
      
      # Mail archivieren
      archive_message(imap, msg_id, mail)
      
      # Zurückgestellt-Eintrag löschen
      deferred_entry.destroy if deferred_entry
      
      return :processed
    else
      # Benutzer existiert noch nicht → zurückgestellt lassen
      @logger.debug("User #{from_address} still does not exist, keeping message #{msg_id} deferred")
      return :kept
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

  # Verarbeite eine einzelne zurückgestellte E-Mail
  def process_single_deferred_mail(deferred_entry)
    begin
      @logger.info("Processing single deferred mail from #{deferred_entry.from_address}")
      
      # Verbinde zu IMAP
      imap = connect_to_imap
      return false unless imap
      
      # Wähle den zurückgestellten Ordner
      deferred_folder = @settings['deferred_folder'] || 'Deferred'
      imap.select(deferred_folder)
      
      # Suche die E-Mail anhand der Message-ID
      message_ids = imap.search(['HEADER', 'Message-ID', deferred_entry.message_id])
      
      if message_ids.empty?
        @logger.warn("Deferred mail with Message-ID #{deferred_entry.message_id} not found in folder #{deferred_folder}")
        return false
      end
      
      # Verarbeite die erste gefundene Nachricht
      msg_id = message_ids.first
      result = process_message(imap, msg_id)
      
      if result
        # Lösche den Eintrag aus der Datenbank nach erfolgreicher Verarbeitung
        deferred_entry.destroy
        @logger.info("Successfully processed and removed deferred entry for #{deferred_entry.from_address}")
      end
      
      imap.disconnect if imap
      return result
      
    rescue => e
      @logger.error("Error processing single deferred mail: #{e.message}")
      @logger.error("Backtrace: #{e.backtrace.join("\n")}")
      return false
    end
  end

  # Erstelle neuen Benutzer (nur wenn Ticket-ID vorhanden)
  def create_new_user(email)
    # Validiere E-Mail-Adresse
    if email.blank?
      @logger.error("Email address is blank or nil")
      return nil
    end
    
    # Normalisiere E-Mail-Adresse
    normalized_email = email.to_s.strip.downcase
    
    # Validiere E-Mail-Format
    unless normalized_email.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
      @logger.error("Invalid email format: #{email}")
      return nil
    end
    
    # Bestimme Vor- und Nachname basierend auf Konfiguration
    firstname = get_user_firstname(normalized_email)
    lastname = get_user_lastname()
    
    # Erstelle neuen Benutzer (deaktiviert)
    begin
      user = User.new(
        firstname: firstname,
        lastname: lastname,
        login: normalized_email,
        status: User::STATUS_LOCKED,
        mail_notification: 'none'
      )
      
      # Setze E-Mail-Adresse direkt über mail Attribut für Kompatibilität
      user.mail = normalized_email
      
      if user.save
        @logger.info("Created new user for #{normalized_email} (locked) - ticket ID present")
        
        # Erstelle EmailAddress-Objekt nach dem Speichern des Users
        begin
          # Prüfe ob bereits eine EmailAddress für diese E-Mail existiert
          existing_email_address = EmailAddress.find_by(address: normalized_email)
          
          if existing_email_address
            @logger.debug("EmailAddress for #{normalized_email} already exists, skipping creation")
          else
            email_address = EmailAddress.create!(
              user: user,
              address: normalized_email,
              is_default: true
            )
            @logger.debug("Created EmailAddress for user #{user.id}")
          end
        rescue => email_error
          @logger.warn("Failed to create EmailAddress for user #{user.id}: #{email_error.message}")
        end
        
        user
      else
        @logger.error("Failed to create user for #{normalized_email}: #{user.errors.full_messages.join(', ')}")
        nil
      end
    rescue => e
      @logger.error("Error creating user for #{normalized_email}: #{e.message}")
      nil
    end
  end

  # Bestimme Vorname basierend auf Konfiguration
  def get_user_firstname(email)
    firstname_type = @settings['user_firstname_type'] || 'mail_account'
    
    case firstname_type
    when 'mail_account'
      email.split('@').first
    when 'mail_address'
      email
    else
      email.split('@').first # Fallback
    end
  end
  
  # Bestimme Nachname basierend auf Konfiguration
  def get_user_lastname
    @settings['user_lastname_custom'] || 'Auto-generated'
  end

  def should_ignore_email?(from_address)
    return false if @settings['ignore_email_addresses'].blank?
    
    ignore_patterns = @settings['ignore_email_addresses'].split("\n").map(&:strip).reject(&:blank?)
    
    ignore_patterns.any? do |pattern|
      if pattern.include?('*')
        # Wildcard-Matching
        regex_pattern = pattern.gsub('*', '.*')
        from_address.match?(/\A#{regex_pattern}\z/i)
      else
        # Exakte Übereinstimmung
        from_address.downcase == pattern.downcase
      end
    end
  end

  private

  # Helper-Methode für Encoding-Behandlung
   def ensure_utf8_encoding(content)
     return "" if content.blank?
     
     if content.respond_to?(:encoding)
       # Versuche automatische Encoding-Erkennung und Konvertierung zu UTF-8
       if content.encoding != Encoding::UTF_8
         content = content.encode('UTF-8', 
           content.encoding, 
           :invalid => :replace, 
           :undef => :replace, 
           :replace => '?'
         )
       end
     else
       # Fallback: Force UTF-8 encoding
       content = content.to_s.force_encoding('UTF-8')
     end
     
     # URL-Dekodierung für kodierte Inhalte
     content = CGI.unescape(content) rescue content
     
     content
   rescue => e
     @logger&.warn("Encoding-Konvertierung fehlgeschlagen: #{e.message}")
     content.to_s.force_encoding('UTF-8')
   end

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
    begin
      msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
      
      # Validiere Mail-Daten
      if msg_data.blank?
        @logger.error("Empty mail data for message #{msg_id}, skipping")
        return
      end
      
      mail = Mail.read_from_string(msg_data)
      
      # Validiere Mail-Objekt
      if mail.nil?
        @logger.error("Failed to parse mail object for message #{msg_id}, skipping")
        return
      end
      
    rescue => e
      @logger.error("Failed to fetch or parse mail data for message #{msg_id}: #{e.message}")
      raise e
    end
    
    # Validiere From-Adresse
    from_address = mail.from&.first
    if from_address.blank?
      @logger.error("Mail has no valid from address, skipping message #{msg_id}")
      return
    end
    
    @logger.debug_mail("Processing mail from #{from_address} with subject: #{mail.subject}", mail)
    
    # Prüfe ob E-Mail ignoriert werden soll
    if should_ignore_email?(from_address)
      @logger.info("Mail from #{from_address} matches ignore pattern, moving to deferred")
      defer_message(imap, msg_id, mail, 'ignored')
      return # Nicht archivieren, da zurückgestellt
    end
    
    # Extrahiere Ticket-ID aus Betreff
    ticket_id = extract_ticket_id(mail.subject)
    
    # Prüfe ob Benutzer bereits existiert
    existing_user = find_existing_user(from_address)
    
    if existing_user
      # Bekannter Benutzer - kann immer verarbeitet werden
      if ticket_id
        # Bekannter Benutzer + Ticket-ID → an spezifisches Ticket
        add_mail_to_ticket(mail, ticket_id, existing_user)
      else
        # Bekannter Benutzer ohne Ticket-ID → an Posteingang-Ticket
        add_mail_to_inbox_ticket(mail, existing_user)
      end
    elsif ticket_id
      # Unbekannter Benutzer + Ticket-ID → Benutzer erstellen und Mail verarbeiten
      new_user = create_new_user(from_address)
      if new_user
        add_mail_to_ticket(mail, ticket_id, new_user)
      else
        @logger.error("Failed to create user for #{from_address}, cannot process mail")
      end
    else
      # Unbekannter Benutzer ohne Ticket-ID → zurückstellen
      @logger.info("Moving mail from unknown user #{from_address} without ticket ID to deferred")
      defer_message(imap, msg_id, mail)
      return # Nicht archivieren, da zurückgestellt
    end
    
    # Mail archivieren (move() markiert automatisch als gelesen)
    # Wichtig: move() macht die Message-ID ungültig, daher zuerst archivieren
    archive_message(imap, msg_id, mail)
  end

  # Extrahiere Ticket-ID aus Betreff
  def extract_ticket_id(subject)
    return nil unless subject
    
    # Unterstütze beide Formate:
    # [#123] - klassisches Format
    # [Text #123] - neues Format mit Text vor der ID
    match = subject.match(/\[(?:.*?\s)?#(\d+)\]/) || subject.match(/\[#(\d+)\]/)
    match ? match[1].to_i : nil
  end

  # Finde existierenden Benutzer (ohne Erstellung)
  def find_existing_user(email)
    # Validiere E-Mail-Adresse
    if email.blank?
      @logger.debug("Email address is blank or nil")
      return nil
    end
    
    # Normalisiere E-Mail-Adresse
    normalized_email = email.to_s.strip.downcase
    
    # Validiere E-Mail-Format
    unless normalized_email.match?(/\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
      @logger.debug("Invalid email format: #{email}")
      return nil
    end
    
    # Suche existierenden Benutzer über EmailAddress-Objekt
    email_address_obj = EmailAddress.find_by(address: normalized_email)
    user = email_address_obj&.user
    
    if user
      @logger.debug("Found existing user for #{normalized_email}: #{user.login}")
    else
      @logger.debug("No existing user found for #{normalized_email}")
    end
    
    user
  end
  
  # Legacy-Methode für Rückwärtskompatibilität (deprecated)
  def find_or_create_user(email)
    @logger.warn("find_or_create_user is deprecated, use find_existing_user or create_new_user instead")
    find_existing_user(email) || create_new_user(email)
  end

  # Füge Mail zu spezifischem Ticket hinzu
  def add_mail_to_ticket(mail, ticket_id, user)
    ticket = Issue.find_by(id: ticket_id)
    unless ticket
      @logger.error_mail("Ticket ##{ticket_id} not found, forwarding to inbox ticket", mail, ticket_id)
      # Fallback: Leite E-Mail an Posteingang-Ticket weiter
      add_mail_to_inbox_ticket(mail, user)
      return
    end
    
    # Dekodiere Mail-Inhalt
    content = decode_mail_content(mail)
    
    # Erstelle Journal-Eintrag
    journal = ticket.init_journal(user, content)
    
    # Verarbeite Anhänge
    process_mail_attachments(mail, ticket, user)
    
    if ticket.save
      @logger.info_mail("Added mail content to ticket ##{ticket_id}", mail, ticket_id)
    else
      @logger.error_mail("Failed to add mail to ticket ##{ticket_id}: #{ticket.errors.full_messages.join(', ')}", mail, ticket_id)
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
    mail_body = ""
    if mail.multipart?
      text_part = mail.text_part
      html_part = mail.html_part
      
      if text_part
        mail_body = text_part.decoded
        # Encoding-Behandlung für Plain-Text
        mail_body = ensure_utf8_encoding(mail_body)
      elsif html_part
        # HTML zu Text konvertieren mit Formatierung
        mail_body = convert_html_to_text(html_part.decoded)
      end
    else
      mail_body = mail.decoded
      # Encoding-Behandlung für einfache E-Mails
      mail_body = ensure_utf8_encoding(mail_body)
    end
    
    # Bereinige und normalisiere Zeilenumbrüche
    if mail_body.present?
      # Entferne überflüssige Leerzeichen am Anfang und Ende
      mail_body = mail_body.strip
      
      # Normalisiere verschiedene Zeilenumbruch-Formate
      mail_body = mail_body.gsub(/\r\n/, "\n")  # Windows CRLF -> LF
      mail_body = mail_body.gsub(/\r/, "\n")    # Mac CR -> LF
      
      # Entferne übermäßige Leerzeilen (mehr als 2 aufeinanderfolgende)
      mail_body = mail_body.gsub(/\n{3,}/, "\n\n")
      
      # Behandle quoted-printable Encoding-Artefakte
      mail_body = mail_body.gsub(/=\n/, "")  # Entferne soft line breaks
      
      # Füge den bereinigten Inhalt hinzu
      content += mail_body
    end
    
    # Hinweis auf Anhänge (werden separat als Redmine-Attachments verarbeitet)
    if mail.attachments.any?
      content += "\n\n*Diese E-Mail enthält #{mail.attachments.count} Anhang(e), die als separate Dateien angehängt wurden.*"
    end
    
    content
  end

  # Konvertiere HTML zu formatiertem Text mit Premailer und Nokogiri
  def convert_html_to_text(html_content)
    return "" if html_content.blank?
    
    begin
      # Encoding-Behandlung: Konvertiere verschiedene Encodings zu UTF-8
      html_content = ensure_utf8_encoding(html_content)
      
      # URL-Dekodierung für kodierte Inhalte (z.B. %20, %3A, etc.)
      html_content = CGI.unescape(html_content) rescue html_content
      
      # Aggressive CSS und Whitespace-Bereinigung vor HTML-Verarbeitung
      # Entferne alle CSS-Blöcke komplett - erweiterte Patterns
      # Entferne CSS-Selektoren mit geschweiften Klammern (auch mehrzeilig)
      html_content = html_content.gsub(/#[a-zA-Z0-9_-]+[\s\n]*\{[^}]*\}/m, '')  # CSS IDs wie #outlookholder
      html_content = html_content.gsub(/\.[a-zA-Z0-9_-]+[\s\n]*\{[^}]*\}/m, '')  # CSS Klassen wie .qfbf
      html_content = html_content.gsub(/[a-zA-Z0-9_-]+[\s\n]*\{[^}]*\}/m, '')  # Beliebige CSS-Selektoren
      html_content = html_content.gsub(/\{[^}]*\}/m, '')  # Alle verbleibenden geschweiften Klammern
      
      # Entferne spezifische CSS-Properties (auch ohne geschweifte Klammern)
      html_content = html_content.gsub(/font-family[\s\n]*:[^;}\n]*[;}\n]?/im, '')  # font-family
      html_content = html_content.gsub(/width[\s\n]*:[^;}\n]*[;}\n]?/im, '')  # width
      html_content = html_content.gsub(/!important[\s\n]*/i, '')  # !important
      
      # Entferne CSS-Property-Patterns (Eigenschaft: Wert)
      html_content = html_content.gsub(/[a-zA-Z-]+[\s\n]*:[\s\n]*[^;}\n]+[;}\n]?/m, '')  # Generische CSS-Properties
      
      # Entferne alleinstehende Zahlen und CSS-Reste
      html_content = html_content.gsub(/\b\d+\b[\s\n]*/, '')  # Alleinstehende Zahlen wie '96'
      html_content = html_content.gsub(/[{}();,]/, '')  # CSS-Zeichen entfernen
      
      # Aggressive Whitespace-Bereinigung
      html_content = html_content.gsub(/^[\s\n]+/m, '')  # Führende Leerzeichen/Zeilenumbrüche
      html_content = html_content.gsub(/[\s\n]{2,}/, ' ')  # Mehrfache Leerzeichen/Zeilenumbrüche zu einem Leerzeichen
      html_content = html_content.gsub(/\n+/, ' ')  # Alle Zeilenumbrüche zu Leerzeichen
      
      # Verwende Premailer für CSS-Inline-Verarbeitung und bessere HTML-Normalisierung
      premailer = Premailer.new(html_content, 
        :with_html_string => true,
        :warn_level => Premailer::Warnings::NONE,
        :adapter => :nokogiri,
        :remove_comments => true,
        :remove_scripts => true,
        :remove_classes => true,
        :remove_ids => true
      )
      
      # Hole das verarbeitete HTML
      processed_html = premailer.to_inline_css
      
      # Parse mit Nokogiri für strukturierte Text-Extraktion
      doc = Nokogiri::HTML::DocumentFragment.parse(processed_html)
      
      # Entferne unerwünschte Elemente
      doc.css('script, style, meta, link, head').remove
      
      # Konvertiere Block-Elemente zu Text mit Formatierung
      convert_block_elements(doc)
      convert_inline_elements(doc)
      convert_list_elements(doc)
      convert_table_elements(doc)
      convert_link_elements(doc)
      
      # Extrahiere den finalen Text und entferne alle HTML-Reste
      text = doc.text
      
      # Zusätzliche HTML-Bereinigung: Entferne alle HTML-Tags und -Attribute
      text = text.gsub(/<[^>]*>/, ' ')  # Entferne HTML-Tags
      text = text.gsub(/&[a-zA-Z0-9#]+;/, ' ')  # Entferne HTML-Entities
      text = text.gsub(/&lt;[^&]*&gt;/, ' ')  # Entferne escaped HTML-Tags
      text = text.gsub(/&quot;[^&]*&quot;/, '')  # Entferne escaped Quotes
      text = text.gsub(/style\s*=\s*["'][^"']*["']/, '')  # Entferne style-Attribute
      
      # Remove CSS blocks and style definitions - enhanced pattern matching
      text = text.gsub(/#[a-zA-Z0-9_-]+\s*\{[^}]*\}/m, "\n")  # CSS rules like #outlookholder
      text = text.gsub(/\.[a-zA-Z0-9_-]+\s*\{[^}]*\}/m, "\n")  # CSS classes like .qfbf
      text = text.gsub(/\{[^}]*\}/m, "\n")  # Any remaining curly brace blocks
      text = text.gsub(/[a-zA-Z0-9_-]+\s*\{[^}]*\}/m, "\n")  # Any CSS selector with curly braces
      text = text.gsub(/font-family\s*:[^;}]*[;}]?/im, ' ')  # font-family properties
      text = text.gsub(/width\s*:[^;}]*[;}]?/im, ' ')  # width properties
      text = text.gsub(/!important/i, ' ')  # !important declarations
      # Remove any remaining CSS-like patterns
      text = text.gsub(/[a-zA-Z-]+\s*:\s*[^;}]+[;}]/m, ' ')  # Generic CSS properties
      
      text = text.gsub(/\s+/, ' ')  # Normalisiere Whitespace
      text = text.strip  # Entferne führende/nachfolgende Leerzeichen
      
      # Bereinige und normalisiere
      text = normalize_whitespace(text)
      
      return text
    rescue => e
      @logger&.warn("HTML-zu-Text-Konvertierung fehlgeschlagen: #{e.message}")
      # Fallback: Einfache Nokogiri-Extraktion
      fallback_html_to_text(html_content)
    end
  end

  private

  # Konvertiere Block-Elemente
  def convert_block_elements(doc)
    # Überschriften: Vereinfacht ohne spezielle Formatierung
    doc.css('h1, h2, h3, h4, h5, h6').each { |h| h.replace("\n\n#{h.text.strip}\n\n") }
    
    # Absätze und Divs
    doc.css('p').each { |p| p.after("\n\n") }
    doc.css('div').each { |div| div.after("\n") unless div.parent&.name == 'body' }
    
    # Zeilenumbrüche
    doc.css('br').each { |br| br.replace("\n") }
    
    # Blockquotes: Vereinfacht ohne > Zeichen
    doc.css('blockquote').each do |bq|
      text = bq.text.strip
      bq.replace("\n\n#{text}\n\n")
    end
    
    # Horizontale Linien: Vereinfacht
    doc.css('hr').each { |hr| hr.replace("\n\n\n") }
  end

  # Konvertiere Inline-Elemente
  def convert_inline_elements(doc)
    # Entferne alle Style-Attribute vor der Verarbeitung
    doc.css('*').each { |elem| elem.remove_attribute('style') }
    
    # Span-Elemente: Nur Text beibehalten, keine Formatierung
    doc.css('span').each { |elem| elem.replace(elem.text) }
    
    # Fett und kursiv - vereinfacht ohne Markdown-Syntax
    doc.css('strong, b').each { |elem| elem.replace(elem.text) }
    doc.css('em, i').each { |elem| elem.replace(elem.text) }
    doc.css('u').each { |elem| elem.replace(elem.text) }
    
    # Code-Elemente: Nur Text ohne Backticks
    doc.css('code').each { |elem| elem.replace(elem.text) }
    
    # Durchgestrichen: Nur Text
    doc.css('s, strike, del').each { |elem| elem.replace(elem.text) }
  end

  # Konvertiere Listen
  def convert_list_elements(doc)
    # Ungeordnete Listen: Vereinfacht ohne Bullet-Points
    doc.css('ul').each do |ul|
      ul.css('li').each_with_index do |li, index|
        li.replace("\n- #{li.text.strip}")
      end
      ul.after("\n")
    end
    
    # Geordnete Listen: Vereinfacht
    doc.css('ol').each do |ol|
      ol.css('li').each_with_index do |li, index|
        li.replace("\n#{index + 1}. #{li.text.strip}")
      end
      ol.after("\n")
    end
  end

  # Konvertiere Tabellen
  def convert_table_elements(doc)
    doc.css('table').each do |table|
      table_text = "\n\n"
      
      # Tabellenkopf: Vereinfacht ohne Markdown-Tabellen-Syntax
      table.css('thead tr, tr:first-child').each do |row|
        cells = row.css('th, td').map { |cell| cell.text.strip }
        table_text += "#{cells.join(' | ')}\n"
      end
      
      # Tabelleninhalt: Vereinfacht
      table.css('tbody tr, tr:not(:first-child)').each do |row|
        next if row.parent.name == 'thead'
        cells = row.css('td, th').map { |cell| cell.text.strip }
        table_text += "#{cells.join(' | ')}\n"
      end
      
      table_text += "\n"
      table.replace(table_text)
    end
  end

  # Konvertiere Links
  def convert_link_elements(doc)
    doc.css('a').each do |link|
      href = link['href']
      text = link.text.strip
      
      if href.present?
        # Bereinige die URL
        clean_url = href.gsub(/^mailto:/, '').strip
        
        if text.present? && text != clean_url
          # Text und URL anzeigen, damit Redmine Hyperlinks erstellen kann
          link.replace("#{text}: #{clean_url}")
        else
          # Nur URL verwenden
          link.replace(clean_url)
        end
      elsif text.present?
        # Nur Text verwenden
        link.replace(text)
      else
        # Link ohne Text entfernen
        link.remove
      end
    end
  end

  # Normalisiere Whitespace
  def normalize_whitespace(text)
    # Entferne führende und nachfolgende Leerzeichen
    text = text.strip
    
    # Normalisiere verschiedene Zeilenumbruch-Formate
    text = text.gsub(/\r\n/, "\n")  # Windows CRLF -> LF
    text = text.gsub(/\r/, "\n")    # Mac CR -> LF
    
    # Entferne übermäßige Leerzeichen in Zeilen
    text = text.gsub(/ +/, " ")
    
    # Entferne übermäßige Leerzeilen (mehr als 2 aufeinanderfolgende)
    text = text.gsub(/\n{3,}/, "\n\n")
    
    # Entferne führende Leerzeichen am Zeilenanfang, außer bei Bullet-Points
    text = text.split("\n").map do |line|
      # Behalte führende Leerzeichen bei Bullet-Points mit "-" oder "*"
      if line.match?(/^\s*[-*]\s+/)
        line.strip
      # Behalte auch nummerierte Listen
      elsif line.match?(/^\s*\d+\.\s+/)
        line.strip
      else
        # Entferne alle führenden Leerzeichen und Tabs bei anderen Zeilen
        line.gsub(/^[\s\t]+/, '').rstrip
      end
    end.join("\n")
    
    return text
  end

  # Fallback für einfache HTML-zu-Text-Konvertierung
  def fallback_html_to_text(html_content)
    # Encoding-Behandlung auch für Fallback
    html_content = ensure_utf8_encoding(html_content)
    
    # URL-Dekodierung auch für Fallback
    html_content = CGI.unescape(html_content) rescue html_content
    
    doc = Nokogiri::HTML::DocumentFragment.parse(html_content)
    doc.css('script, style').remove
    text = doc.text
    
    # Zusätzliche HTML-Bereinigung auch für Fallback
      text = text.gsub(/<[^>]*>/, ' ')  # Entferne HTML-Tags
      text = text.gsub(/&[a-zA-Z0-9#]+;/, ' ')  # Entferne HTML-Entities
      text = text.gsub(/&lt;[^&]*&gt;/, ' ')  # Entferne escaped HTML-Tags
      text = text.gsub(/&quot;[^&]*&quot;/, '')  # Entferne escaped Quotes
      text = text.gsub(/style\s*=\s*["'][^"']*["']/, '')  # Entferne style-Attribute
      text = text.gsub(/\s+/, ' ')  # Normalisiere Whitespace
      text = text.strip  # Entferne führende/nachfolgende Leerzeichen
    
    normalize_whitespace(text)
  rescue => e
    @logger&.error("Fallback HTML-zu-Text-Konvertierung fehlgeschlagen: #{e.message}")
    html_content.gsub(/<[^>]*>/, ' ').gsub(/\s+/, ' ').strip
  end

  public

  # Verarbeite E-Mail-Anhänge als Redmine-Attachments
  def process_mail_attachments(mail, ticket, user)
    return unless mail.attachments.any?
    
    mail.attachments.each do |attachment|
      begin
        # Überspringe leere oder ungültige Anhänge
        next if attachment.filename.blank? || attachment.body.blank?
        
        # Erstelle temporäre Datei
        temp_file = Tempfile.new([attachment.filename.gsub(/[^\w.-]/, '_'), File.extname(attachment.filename)])
        temp_file.binmode
        temp_file.write(attachment.body.decoded)
        temp_file.rewind
        
        # Erstelle Redmine-Attachment
        redmine_attachment = Attachment.new(
          :file => temp_file,
          :filename => attachment.filename,
          :author => user,
          :content_type => attachment.content_type || 'application/octet-stream'
        )
        
        if redmine_attachment.save
          # Verknüpfe Attachment mit Ticket
          ticket.attachments << redmine_attachment
          @logger.info("Successfully attached file: #{attachment.filename} to ticket ##{ticket.id}")
        else
          @logger.error("Failed to save attachment #{attachment.filename}: #{redmine_attachment.errors.full_messages.join(', ')}")
        end
        
      rescue => e
        @logger.error("Error processing attachment #{attachment.filename}: #{e.message}")
      ensure
        # Bereinige temporäre Datei
        temp_file&.close
        temp_file&.unlink
      end
    end
  end

  # Archiviere Nachricht
  def archive_message(imap, msg_id, mail = nil)
    # Überspringe Archivierung wenn kein Archiv-Ordner konfiguriert ist
    unless @settings['archive_folder'].present?
      @logger.debug("No archive folder configured, skipping archive for message #{msg_id}")
      return
    end
    
    begin
      # Prüfe ob die Message-ID noch gültig ist
      uid_data = imap.fetch(msg_id, 'UID')
      unless uid_data && uid_data.first
        @logger.debug("Message #{msg_id} is invalid or already processed, skipping archive")
        return
      end
      
      # Prüfe ob der Archiv-Ordner existiert, erstelle ihn falls nötig
      ensure_archive_folder_exists(imap)
      
      # Verschiebe die Nachricht (markiert automatisch als gelesen)
      imap.move(msg_id, @settings['archive_folder'])
      @logger.info_mail("Successfully moved message #{msg_id} to archive folder '#{@settings['archive_folder']}'", mail)
      
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} already moved or invalid, skipping archive")
      elsif e.message.include?('TRYCREATE')
        @logger.info("Archive folder '#{@settings['archive_folder']}' does not exist, creating it...")
        create_archive_folder(imap)
        # Versuche erneut zu verschieben
        begin
          imap.move(msg_id, @settings['archive_folder'])
          @logger.info("Successfully moved message #{msg_id} to newly created archive folder")
        rescue => retry_e
          @logger.error("Failed to move message #{msg_id} to archive after creating folder: #{retry_e.message}")
        end
      elsif e.message.include?('NO MOVE')
        @logger.warn("IMAP server does not support MOVE command for message #{msg_id}, trying COPY + EXPUNGE")
        # Fallback: COPY + STORE + EXPUNGE
        begin
          imap.copy(msg_id, @settings['archive_folder'])
          imap.store(msg_id, '+FLAGS', [:Deleted])
          imap.expunge
          @logger.info("Successfully copied and deleted message #{msg_id} to archive folder (fallback method)")
        rescue => copy_e
          @logger.error("Fallback archive method failed for message #{msg_id}: #{copy_e.message}")
        end
      else
        @logger.warn("Failed to archive message #{msg_id}: #{e.message}")
      end
    rescue => e
      @logger.error("Unexpected error archiving message #{msg_id}: #{e.class.name} - #{e.message}")
    end
  end

  # Verschiebe Nachricht in Zurückgestellt-Ordner
  def defer_message(imap, msg_id, mail, reason = 'unknown_user')
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    
    begin
      # Stelle sicher, dass Zurückgestellt-Ordner existiert
      ensure_deferred_folder_exists(imap)
      
      # Verschiebe Mail in Zurückgestellt-Ordner
      imap.move(msg_id, deferred_folder)
      @logger.info_mail("Successfully moved message #{msg_id} to deferred folder '#{deferred_folder}'", mail)
      
      # Speichere Zurückgestellt-Zeitstempel mit Grund
      save_deferred_timestamp(mail, Time.current, reason)
      
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} already moved or invalid, skipping quarantine")
      elsif e.message.include?('TRYCREATE')
        @logger.info("Deferred folder '#{deferred_folder}' does not exist, creating it...")
        create_deferred_folder(imap)
        # Versuche erneut zu verschieben
        begin
          imap.move(msg_id, deferred_folder)
          @logger.info("Successfully moved message #{msg_id} to newly created deferred folder")
          save_deferred_timestamp(mail, Time.current)
        rescue => retry_e
          @logger.error("Failed to move message #{msg_id} to deferred after creating folder: #{retry_e.message}")
        end
      elsif e.message.include?('NO MOVE')
        @logger.warn("IMAP server does not support MOVE command for message #{msg_id}, trying COPY + EXPUNGE")
        # Fallback: COPY + STORE + EXPUNGE
        begin
          imap.copy(msg_id, deferred_folder)
          imap.store(msg_id, '+FLAGS', [:Deleted])
          imap.expunge
          @logger.info("Successfully copied and deleted message #{msg_id} to deferred folder (fallback method)")
          save_deferred_timestamp(mail, Time.current)
        rescue => copy_e
          @logger.error("Fallback defer method failed for message #{msg_id}: #{copy_e.message}")
        end
      else
        @logger.warn("Failed to defer message #{msg_id}: #{e.message}")
      end
    rescue => e
      @logger.error("Unexpected error deferring message #{msg_id}: #{e.class.name} - #{e.message}")
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

  # Stelle sicher, dass der Zurückgestellt-Ordner existiert
  def ensure_deferred_folder_exists(imap)
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    return unless deferred_folder.present?
    
    begin
      # Liste alle Ordner auf
      folders = imap.list('', '*')
      folder_names = folders.map(&:name)
      
      unless folder_names.include?(deferred_folder)
        @logger.info("Deferred folder '#{deferred_folder}' not found, creating it...")
        create_deferred_folder(imap)
      end
    rescue => e
      @logger.warn("Could not check deferred folder existence: #{e.message}")
    end
  end

  # Erstelle Zurückgestellt-Ordner
  def create_deferred_folder(imap)
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    
    begin
      imap.create(deferred_folder)
      @logger.info("Successfully created deferred folder '#{deferred_folder}'")
    rescue => e
      @logger.error("Failed to create deferred folder '#{deferred_folder}': #{e.message}")
    end
  end

  # Speichere Zurückgestellt-Zeitstempel für Mail
  def save_deferred_timestamp(mail, timestamp, reason = 'unknown_user')
    return unless mail&.message_id
    
    begin
      # Erstelle oder aktualisiere Zurückgestellt-Eintrag
      deferred_entry = MailDeferredEntry.find_or_initialize_by(message_id: mail.message_id)
      deferred_entry.update!(
        from_address: mail.from&.first,
        subject: mail.subject,
        deferred_at: timestamp,
        expires_at: timestamp + (@settings['deferred_lifetime_days'] || 30).to_i.days,
        reason: reason
      )
      
      @logger.debug("Saved deferred timestamp for message #{mail.message_id} with reason: #{reason}")
    rescue => e
      @logger.error("Failed to save deferred timestamp for message #{mail.message_id}: #{e.message}")
    end
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
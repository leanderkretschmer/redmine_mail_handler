require 'net/imap'
require 'mail'
require 'mime/types'
require 'nokogiri'
require 'timeout'
require 'openssl'
require 'tempfile'
require 'cgi'

# Mail-Decoder und HTML2Text für robuste Parser-Option
begin
  require 'mail-decoder'
  require 'html2text'
rescue LoadError => e
  # Gems sind optional - nur laden wenn verfügbar
end

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
      
      # Automatische Log-Bereinigung nach Mail-Import
      MailHandlerLog.run_scheduled_cleanup
      
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
      
      # Automatische Log-Bereinigung nach Zurückgestellt-Verarbeitung
      MailHandlerLog.run_scheduled_cleanup
      
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
    
    # Rückdatierung anwenden, wenn aktiviert
    if @settings['backdate_comments'] == '1' && mail.date.present?
      backdate_journal(journal, mail.date)
    end
    
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
    
    # Prüfe ob Mail-Decoder aktiviert ist
    use_mail_decoder = @settings['mail_decoder_enabled'] == '1'
    
    # Betreff hinzufügen mit robustem Decoding
    if mail.subject
      subject = use_mail_decoder ? decode_header_with_mail_decoder(mail.subject) : mail.subject
      content += "**Betreff:** #{subject}\n\n"
    end
    
    # Parser-Modus prüfen
    parser_mode = @settings['parser_mode'] || 'html_to_text'
    
    # Text-Teil extrahieren basierend auf Parser-Modus und Mail-Decoder
    mail_body = ""
    if use_mail_decoder
      mail_body = extract_content_with_mail_decoder(mail)
    elsif parser_mode == 'text_representation'
      mail_body = extract_text_representation(mail)
    else
      # Standard HTML-zu-Text Parser
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
      
      # Regex-Filter anwenden wenn aktiviert
      if @settings['regex_filter_enabled'] == '1'
        mail_body = apply_regex_filter(mail_body)
      end
      
      # Whitespace-Filter anwenden wenn aktiviert
      if @settings['remove_leading_whitespace_enabled'] == '1'
        mail_body = apply_whitespace_filter(mail_body)
      end
      
      # Absatz-Normalisierungs-Filter anwenden wenn aktiviert
      if @settings['normalize_paragraphs_enabled'] == '1'
        mail_body = apply_paragraph_normalization_filter(mail_body)
      end
      
      # Markdown-Link-Filter anwenden wenn aktiviert
      if @settings['markdown_link_filter_enabled'] == '1'
        mail_body = apply_markdown_link_filter(mail_body)
      end
      
      # Füge den bereinigten Inhalt hinzu
      content += mail_body
    end
    
    # Hinweis auf Anhänge (werden separat als Redmine-Attachments verarbeitet)
    if mail.attachments.any?
      content += "\n\n*Diese E-Mail enthält #{mail.attachments.count} Anhang(e), die als separate Dateien angehängt wurden.*"
    end
    
    content
  end

  # Extrahiere Text-Repräsentation der E-Mail
  def extract_text_representation(mail)
    mail_body = ""
    
    if mail.multipart?
      # Bevorzuge Text-Teil wenn vorhanden
      text_part = mail.text_part
      if text_part
        mail_body = text_part.decoded
        mail_body = ensure_utf8_encoding(mail_body)
      else
        # Fallback auf HTML-Teil, aber minimal konvertiert
        html_part = mail.html_part
        if html_part
          html_content = html_part.decoded
          mail_body = simple_html_to_text(html_content)
        end
      end
    else
      # Einfache E-Mail
      mail_body = mail.decoded
      mail_body = ensure_utf8_encoding(mail_body)
      
      # Prüfe ob es HTML-Inhalt ist und konvertiere minimal
      if mail_body.include?('<html') || mail_body.include?('<HTML')
        mail_body = simple_html_to_text(mail_body)
      end
    end
    
    # Bereinige und normalisiere
    if mail_body.present?
      mail_body = mail_body.strip
      mail_body = mail_body.gsub(/\r\n/, "\n")  # Windows CRLF -> LF
      mail_body = mail_body.gsub(/\r/, "\n")    # Mac CR -> LF
      mail_body = mail_body.gsub(/\n{3,}/, "\n\n")  # Reduziere übermäßige Leerzeilen
      mail_body = mail_body.gsub(/=\n/, "")  # Entferne soft line breaks
      
      # Regex-Filter anwenden wenn aktiviert
      if @settings['regex_filter_enabled'] == '1'
        mail_body = apply_regex_filter(mail_body)
      end
      
      # Whitespace-Filter anwenden wenn aktiviert
      if @settings['remove_leading_whitespace_enabled'] == '1'
        mail_body = apply_whitespace_filter(mail_body)
      end
      
      # Absatz-Normalisierungs-Filter anwenden wenn aktiviert
      if @settings['normalize_paragraphs_enabled'] == '1'
        mail_body = apply_paragraph_normalization_filter(mail_body)
      end
      
      # Markdown-Link-Filter anwenden wenn aktiviert
      if @settings['markdown_link_filter_enabled'] == '1'
        mail_body = apply_markdown_link_filter(mail_body)
      end
    end
    
    mail_body
  end

  # Einfache HTML-zu-Text Konvertierung (minimal)
  def simple_html_to_text(html_content)
    return "" if html_content.blank?
    
    begin
      # Verwende Nokogiri für minimale HTML-Bereinigung
      doc = Nokogiri::HTML::DocumentFragment.parse(html_content)
      
      # HTML-Struktur-Filter anwenden wenn aktiviert
      if @settings['html_structure_filter_enabled'] == '1'
        apply_html_structure_filter(doc)
      end
      
      # Entferne Script und Style Tags komplett
      doc.css('script, style').remove
      
      # Konvertiere zu Text und behalte Struktur
      text = doc.inner_text
      
      # Dekodiere HTML-Entities
      text = CGI.unescapeHTML(text)
      
      # Normalisiere Whitespace
      text = text.gsub(/\s+/, ' ').strip
      
      return text
    rescue => e
      @logger.warn("Simple HTML-to-text conversion failed: #{e.message}")
      # Fallback: Entferne nur HTML-Tags mit Regex
      html_content.gsub(/<[^>]*>/, ' ').gsub(/\s+/, ' ').strip
    end
  end

  # Konvertiere HTML zu formatiertem Text mit effizienten Libraries
  def convert_html_to_text(html_content)
    return "" if html_content.blank?
    
    begin
      # Encoding-Behandlung: Konvertiere verschiedene Encodings zu UTF-8
      html_content = ensure_utf8_encoding(html_content)
      
      # URL-Dekodierung für kodierte Inhalte
      html_content = CGI.unescape(html_content) rescue html_content
      
      # Repariere häufige UTF-8-Kodierungsfehler vor der HTML-Verarbeitung
      html_content = fix_encoding_issues(html_content)
      
      # Prüfe ob html2text verfügbar ist und verwende es bevorzugt
      if defined?(Html2Text)
        begin
          # Verwende html2text für bessere Formatierung (Links in Klammern etc.)
          text_content = Html2Text.convert(html_content)
          return ensure_utf8_encoding(text_content)
        rescue => e
          @logger.warn("Html2Text Konvertierung fehlgeschlagen, verwende Nokogiri-Fallback: #{e.message}")
          # Fallback auf Nokogiri bei Fehlern
        end
      end
      
      # Nokogiri-Fallback für robuste HTML-Verarbeitung
      doc = Nokogiri::HTML::DocumentFragment.parse(html_content)
      
      # HTML-Struktur-Filter anwenden wenn aktiviert
      if @settings['html_structure_filter_enabled'] == '1'
        apply_html_structure_filter(doc)
      end
      
      # Entferne alle style-Attribute und CSS-spezifische Elemente
      doc.search('*').each do |element|
        element.remove_attribute('style')
        element.remove_attribute('class') if element['class']&.match?(/mso|gmail|word|signature/i)
      end
      
      # Entferne problematische Tags komplett
      doc.search('style, script, meta, link').remove
      
      # Konvertiere zu Text mit Nokogiri's eingebauter Methode
      text_content = doc.inner_text
      
      # HTML-Entities dekodieren
      text_content = CGI.unescapeHTML(text_content)
      
      # Whitespace normalisieren
      text_content = normalize_whitespace(text_content)
      
      return text_content
      
    rescue => e
      Rails.logger.error "Fehler bei HTML-zu-Text-Konvertierung: #{e.message}"
      # Fallback: Einfache HTML-Tag-Entfernung
      html_content.gsub(/<[^>]*>/, '').strip
    end
  end

  # Dekodiere Header mit Mail-Decoder für robustes Charset-Handling
  def decode_header_with_mail_decoder(header_value)
    return "" if header_value.blank?
    
    begin
      # Prüfe ob mail-decoder verfügbar ist
      if defined?(MailDecoder)
        decoded = MailDecoder.decode_header(header_value)
        return ensure_utf8_encoding(decoded)
      else
        @logger.warn("Mail-Decoder gem nicht verfügbar, verwende Standard-Decoding")
        return ensure_utf8_encoding(header_value)
      end
    rescue => e
      @logger.warn("Mail-Decoder Header-Decoding fehlgeschlagen: #{e.message}")
      # Fallback auf Standard-Encoding-Behandlung
      return ensure_utf8_encoding(header_value)
    end
  end

  # Extrahiere Mail-Inhalt mit Mail-Decoder und HTML2Text
  def extract_content_with_mail_decoder(mail)
    mail_body = ""
    
    begin
      if mail.multipart?
        # Bevorzuge Text-Teil wenn vorhanden
        text_part = mail.text_part
        html_part = mail.html_part
        
        if text_part
          # Dekodiere Text-Teil mit Mail-Decoder
          if defined?(MailDecoder)
            mail_body = MailDecoder.decode_body(text_part)
          else
            mail_body = text_part.decoded
          end
          mail_body = ensure_utf8_encoding(mail_body)
        elsif html_part
          # HTML-Teil mit verbesserter Konvertierung
          html_content = html_part.decoded
          if defined?(MailDecoder)
            html_content = MailDecoder.decode_body(html_part)
          end
          mail_body = convert_html_to_text_with_html2text(html_content)
        end
      else
        # Einfache E-Mail
        if defined?(MailDecoder)
          mail_body = MailDecoder.decode_body(mail)
        else
          mail_body = mail.decoded
        end
        mail_body = ensure_utf8_encoding(mail_body)
        
        # Prüfe ob es HTML-Inhalt ist und konvertiere mit html2text
        if mail_body.include?('<html') || mail_body.include?('<HTML')
          mail_body = convert_html_to_text_with_html2text(mail_body)
        end
      end
      
      # Bereinige und normalisiere
      if mail_body.present?
        mail_body = mail_body.strip
        mail_body = mail_body.gsub(/\r\n/, "\n")  # Windows CRLF -> LF
        mail_body = mail_body.gsub(/\r/, "\n")    # Mac CR -> LF
        mail_body = mail_body.gsub(/\n{3,}/, "\n\n")  # Reduziere übermäßige Leerzeilen
        mail_body = mail_body.gsub(/=\n/, "")  # Entferne soft line breaks
        
        # Regex-Filter anwenden wenn aktiviert
        if @settings['regex_filter_enabled'] == '1'
          mail_body = apply_regex_filter(mail_body)
        end
        
        # Whitespace-Filter anwenden wenn aktiviert
        if @settings['remove_leading_whitespace_enabled'] == '1'
          mail_body = apply_whitespace_filter(mail_body)
        end
        
        # Absatz-Normalisierungs-Filter anwenden wenn aktiviert
        if @settings['normalize_paragraphs_enabled'] == '1'
          mail_body = apply_paragraph_normalization_filter(mail_body)
        end
        
        # Markdown-Link-Filter anwenden wenn aktiviert
        if @settings['markdown_link_filter_enabled'] == '1'
          mail_body = apply_markdown_link_filter(mail_body)
        end
      end
      
      return mail_body
      
    rescue => e
      @logger.error("Mail-Decoder Content-Extraktion fehlgeschlagen: #{e.message}")
      # Fallback auf Standard-Methode
      return extract_text_representation(mail)
    end
  end

  # Konvertiere HTML zu Text mit html2text (schönere Formatierung)
  def convert_html_to_text_with_html2text(html_content)
    return "" if html_content.blank?
    
    begin
      # HTML-Struktur-Filter anwenden wenn aktiviert
      if @settings['html_structure_filter_enabled'] == '1'
        doc = Nokogiri::HTML::DocumentFragment.parse(html_content)
        apply_html_structure_filter(doc)
        html_content = doc.to_html
      end
      
      # Prüfe ob html2text verfügbar ist
      if defined?(Html2Text)
        # Verwende html2text für bessere Formatierung (Links in Klammern etc.)
        text_content = Html2Text.convert(html_content)
        return ensure_utf8_encoding(text_content)
      else
        @logger.debug("Html2Text gem nicht verfügbar, verwende Nokogiri-Fallback")
        # Fallback auf Nokogiri
        return simple_html_to_text(html_content)
      end
    rescue => e
      @logger.warn("Html2Text Konvertierung fehlgeschlagen: #{e.message}")
      # Fallback auf einfache Nokogiri-Konvertierung
      return simple_html_to_text(html_content)
    end
  end
  
  private
  
  # Repariert häufige UTF-8-Kodierungsfehler
  def fix_encoding_issues(content)
    # Doppelt kodierte UTF-8-Zeichen reparieren
    replacements = {
      #'fÃÂ¼r' => 'für',
      #'kÃÂ¶nnen' => 'können',
      'ÃÂ¼' => 'ü',
      'ÃÂ¶' => 'ö',
      'ÃÂ¤' => 'ä',
      'ÃÂÜ' => 'Ü',
      'ÃÂÖ' => 'Ö',
      'ÃÂÄ' => 'Ä',
      'ÃÂß' => 'ß',
      #'MÃÂGLICHKEITEN' => 'MÖGLICHKEITEN',
      #'SchaltflÃÂ¤che' => 'Schaltfläche',
      #'gefÃÂ¤hrdet' => 'gefährdet',
      #'ÃÂ¶ffentlich' => 'öffentlich',
      #'HinzufÃÂÃÂ¼gen' => 'Hinzufügen'
    }
    
    replacements.each { |bad, good| content = content.gsub(bad, good) }
    content
  end
  
  # Normalisiert Whitespace
  def normalize_whitespace(content)
    content.gsub(/\s+/, ' ').strip
  end
  
  # Datiert Journal auf E-Mail-Empfangsdatum zurück
  def backdate_journal(journal, mail_date)
    begin
      # Konvertiere Mail-Datum zu Time-Objekt falls nötig
      target_date = mail_date.is_a?(Time) ? mail_date : Time.parse(mail_date.to_s)
      
      # Setze created_on direkt nach dem Speichern
      journal.created_on = target_date
      
      @logger.debug("Backdating journal to #{target_date}")
      
    rescue => e
      @logger.error("Failed to backdate journal: #{e.message}")
    end
  end



  # Verarbeite E-Mail-Anhänge als Redmine-Attachments
  def process_mail_attachments(mail, ticket, user)
    # Verarbeite reguläre Anhänge
    if mail.attachments.any?
      mail.attachments.each do |attachment|
        begin
          # Überspringe leere oder ungültige Anhänge
          next if attachment.filename.blank? || attachment.body.blank?
          
          # Überspringe ausgeschlossene Dateien
          if should_exclude_attachment?(attachment.filename)
            @logger.info("Skipping excluded attachment: #{attachment.filename}")
            next
          end
          
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
    
    # HTML-Anhang erstellen, wenn aktiviert
    if @settings['html_attachment_enabled'] == '1'
      create_html_attachment(mail, ticket, user)
    end
  end
  
  # Erstelle HTML-Anhang aus E-Mail-Inhalt
  def create_html_attachment(mail, ticket, user)
    begin
      # Extrahiere HTML-Inhalt
      html_content = extract_html_content(mail)
      
      return if html_content.blank?
      
      # Generiere Dateinamen basierend auf Betreff und Datum
      timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
      subject_part = mail.subject.present? ? mail.subject.gsub(/[^\w.-]/, '_')[0..50] : 'email'
      filename = "#{subject_part}_#{timestamp}.html"
      
      # Erstelle temporäre HTML-Datei
      temp_file = Tempfile.new([filename.gsub(/\.html$/, ''), '.html'])
      temp_file.write(html_content)
      temp_file.rewind
      
      # Erstelle Redmine-Attachment
      redmine_attachment = Attachment.new(
        :file => temp_file,
        :filename => filename,
        :author => user,
        :content_type => 'text/html'
      )
      
      if redmine_attachment.save
        # Verknüpfe Attachment mit Ticket
        ticket.attachments << redmine_attachment
        @logger.info("Successfully attached HTML content as #{filename} to ticket ##{ticket.id}")
      else
        @logger.error("Failed to save HTML attachment #{filename}: #{redmine_attachment.errors.full_messages.join(', ')}")
      end
      
    rescue => e
      @logger.error("Error creating HTML attachment: #{e.message}")
    ensure
      # Bereinige temporäre Datei
      temp_file&.close
      temp_file&.unlink
    end
  end
  
  # Extrahiere HTML-Inhalt aus E-Mail
  def extract_html_content(mail)
    html_content = ""
    
    if mail.multipart?
      html_part = mail.html_part
      if html_part
        html_content = html_part.decoded
        html_content = ensure_utf8_encoding(html_content)
      end
    else
      # Prüfe ob es sich um HTML handelt
      if mail.content_type&.include?('text/html')
        html_content = mail.decoded
        html_content = ensure_utf8_encoding(html_content)
      end
    end
    
    # Erstelle vollständiges HTML-Dokument falls nur Fragment vorhanden
    if html_content.present? && !html_content.include?('<html')
      html_content = create_complete_html_document(html_content, mail)
    end
    
    html_content
  end
  
  # Erstelle vollständiges HTML-Dokument
  def create_complete_html_document(html_fragment, mail)
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>#{mail.subject || 'E-Mail'}</title>
        <style>
          body { font-family: Arial, sans-serif; margin: 20px; }
          .email-header { border-bottom: 1px solid #ccc; padding-bottom: 10px; margin-bottom: 20px; }
          .email-meta { color: #666; font-size: 0.9em; }
        </style>
      </head>
      <body>
        <div class="email-header">
          <h2>#{mail.subject || 'Kein Betreff'}</h2>
          <div class="email-meta">
            <strong>Von:</strong> #{mail.from&.first || 'Unbekannt'}<br>
            <strong>Datum:</strong> #{mail.date || Time.current}
          </div>
        </div>
        <div class="email-content">
          #{html_fragment}
        </div>
      </body>
      </html>
    HTML
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
      
      # Bereinige Subject von problematischen Zeichen (Emojis) falls nötig
      subject = mail.subject
      if subject.present?
        # Entferne 4-Byte UTF-8 Zeichen (Emojis) falls die Datenbank sie nicht unterstützt
        # Dies ist ein Fallback für den Fall, dass die Migration noch nicht ausgeführt wurde
        begin
          subject = subject.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
          # Teste ob das Subject gespeichert werden kann
          test_entry = MailDeferredEntry.new(
            message_id: "test_#{SecureRandom.hex(8)}",
            from_address: mail.from&.first || 'test@example.com',
            subject: subject,
            deferred_at: timestamp,
            expires_at: timestamp + 1.day,
            reason: reason
          )
          test_entry.valid? # Triggert Validierung ohne zu speichern
        rescue => encoding_error
          @logger.warn("Subject contains problematic characters, sanitizing: #{encoding_error.message}")
          # Entferne alle 4-Byte UTF-8 Zeichen (Emojis)
          subject = subject.gsub(/[\u{10000}-\u{10FFFF}]/, '?')
        end
      end
      
      deferred_entry.update!(
        from_address: mail.from&.first,
        subject: subject,
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

  # HTML-Struktur-Filter: Entferne störende HTML-Elemente
  def apply_html_structure_filter(doc)
    # Entferne Blockquote-Elemente (Zitate)
    doc.css('blockquote').remove
    
    # Entferne Gmail-spezifische Elemente
    doc.css('.gmail_quote, .gmail_attr').remove
    doc.css('[class*="gmail_quote"], [class*="gmail_attr"]').remove
    
    # Entferne Apple Mail-spezifische Elemente
    doc.css('.apple-msg-attachment, .Apple-converted-space').remove
    doc.css('[class*="apple-msg-attachment"], [class*="Apple-converted-space"]').remove
    
    # Entferne Outlook-spezifische Elemente
    doc.css('.WordSection1, .OutlookMessageHeader, .x_QuotedText').remove
    doc.css('[class*="WordSection"], [class*="OutlookMessageHeader"], [class*="QuotedText"]').remove
    
    # Entferne Yahoo-spezifische Elemente
    doc.css('.yahoo_quoted, .yahoo_quote').remove
    doc.css('[class*="yahoo_quoted"], [class*="yahoo_quote"]').remove
    
    # Entferne Android Mail-spezifische Elemente
    doc.css('.mail_android_quote').remove
    doc.css('[class*="mail_android_quote"]').remove
    
    @logger.debug("HTML-Struktur-Filter angewendet")
  end

  # Regex-Filter: Entferne Text ab typischen E-Mail-Trennern
  def apply_regex_filter(text)
    return text if text.blank?
    
    # Hole Regex-Trenner aus Einstellungen
    separators = @settings['regex_separators'] || "Am .* schrieb .*:\nVon:\nGesendet:\nAn:\nBetreff:\n-----Original Message-----\n-------- Ursprüngliche Nachricht --------"
    
    # Teile Trenner in einzelne Zeilen auf
    separator_patterns = separators.split("\n").map(&:strip).reject(&:blank?)
    
    # Durchsuche Text nach Trennern
    separator_patterns.each do |pattern|
      begin
        # Erstelle Regex-Pattern (case-insensitive und multiline)
        regex = Regexp.new(pattern, Regexp::IGNORECASE | Regexp::MULTILINE)
        
        # Finde erste Übereinstimmung
        match = text.match(regex)
        if match
          # Schneide Text ab der ersten Übereinstimmung ab
          text = text[0, match.begin(0)].strip
          @logger.debug("Regex-Filter angewendet: Text ab '#{pattern}' entfernt")
          break  # Stoppe nach dem ersten gefundenen Trenner
        end
      rescue RegexpError => e
        @logger.warn("Ungültiges Regex-Pattern '#{pattern}': #{e.message}")
        next
      end
    end
    
    text
  end

  # Whitespace-Filter: Entferne führende Leerzeichen und Tabs
  def apply_whitespace_filter(text)
    return text if text.blank?
    
    # Entferne führende Leerzeichen und Tabs von jeder Zeile
    lines = text.split("\n")
    filtered_lines = lines.map { |line| line.lstrip }
    filtered_text = filtered_lines.join("\n")
    
    @logger.debug("Whitespace-Filter angewendet: Führende Leerzeichen entfernt")
    filtered_text
  end

  # Absatz-Normalisierungs-Filter: Reduziere aufeinanderfolgende leere Zeilen
  def apply_paragraph_normalization_filter(text)
    return text if text.blank?
    
    # Hole maximale Anzahl aufeinanderfolgender Absätze aus Einstellungen
    max_paragraphs = (@settings['max_consecutive_paragraphs'] || '1').to_i
    max_paragraphs = [max_paragraphs, 1].max  # Mindestens 1
    max_paragraphs = [max_paragraphs, 5].min  # Maximal 5
    
    # Erstelle Regex-Pattern für mehr als max_paragraphs aufeinanderfolgende Newlines
    pattern = "\\n{#{max_paragraphs + 1},}"
    replacement = "\n" * max_paragraphs
    
    # Wende Filter an
    filtered_text = text.gsub(Regexp.new(pattern), replacement)
    
    @logger.debug("Absatz-Normalisierungs-Filter angewendet: Maximal #{max_paragraphs} aufeinanderfolgende Absätze")
    filtered_text
  end

  # Prüfe ob Anhang ausgeschlossen werden soll
  def should_exclude_attachment?(filename)
    return false unless @settings['exclude_attachments_enabled'] == '1'
    return false if filename.blank?
    
    # Hole Ausschluss-Muster aus Einstellungen
    patterns = @settings['excluded_attachment_patterns']
    return false if patterns.blank?
    
    # Teile Muster in einzelne Zeilen auf
    pattern_list = patterns.split("\n").map(&:strip).reject(&:empty?)
    
    # Prüfe jeden Pattern
    pattern_list.each do |pattern|
      # Konvertiere Wildcard-Pattern zu Regex
      regex_pattern = pattern.gsub('*', '.*')
      
      # Erstelle Regex (case-insensitive)
      begin
        regex = Regexp.new("^#{regex_pattern}$", Regexp::IGNORECASE)
        
        # Prüfe ob Dateiname dem Muster entspricht
        if filename.match?(regex)
          @logger.debug("Attachment '#{filename}' matches exclusion pattern '#{pattern}'")
          return true
        end
      rescue RegexpError => e
        @logger.warn("Invalid exclusion pattern '#{pattern}': #{e.message}")
        next
      end
    end
    
    false
  end

  # Markdown-Link-Filter: Konvertiere verschiedene Link-Formate zu "alt-text":link
  def apply_markdown_link_filter(text)
    return text if text.blank?
    
    converted_text = text.dup
    total_conversions = 0
    
    # Regex für mailto-Links mit Duplikat-Erkennung - MUSS VOR anderen Patterns stehen!
    # Behandelt sowohl: <mailto:email> email als auch email <mailto:email>
    
    # Erst umgekehrte Reihenfolge: <mailto:email> email
    reverse_mailto_pattern = /<\s*mailto:([^>]+)\s*>\s*([\w\.-]+@[\w\.-]+)/
    reverse_conversions = converted_text.scan(reverse_mailto_pattern).count
    converted_text = converted_text.gsub(reverse_mailto_pattern) do
      email_in_mailto = $1.strip
      email_after = $2.strip
      if email_in_mailto == email_after
        email_after  # Duplikat - nur E-Mail behalten
      else
        "[#{email_after}](mailto:#{email_in_mailto})"  # Link erstellen
      end
    end
    
    # Dann normale Reihenfolge: email <mailto:email>
    mailto_pattern = /([\w\.-]+@[\w\.-]+)\s*<\s*mailto:([^>]+)\s*>/
    normal_conversions = converted_text.scan(mailto_pattern).count
    converted_text = converted_text.gsub(mailto_pattern) do
      email_before = $1.strip
      email_in_mailto = $2.strip
      if email_before == email_in_mailto
        email_before  # Duplikat - nur E-Mail behalten
      else
        "[#{email_before}](mailto:#{email_in_mailto})"  # Link erstellen
      end
    end
    
    mailto_conversions = reverse_conversions + normal_conversions
    total_conversions += mailto_conversions
    
    # Regex für Markdown-Links: [alt-text](link) - aber nur für nicht-mailto Links
    markdown_link_pattern = /\[([^\]]+)\]\((?!mailto:)([^\)]+)\)/
    markdown_conversions = converted_text.scan(markdown_link_pattern).count
    converted_text = converted_text.gsub(markdown_link_pattern) do |match|
      alt_text = $1
      link_url = $2
      "\"#{alt_text}\":#{link_url}"
    end
    total_conversions += markdown_conversions
    
    # Regex für Text in Anführungszeichen mit URL in Backticks: "text" ( `url` )
    quoted_text_pattern = /"([^"]+)"\s*\(\s*`([^`]+)`\s*\)/
    quoted_conversions = converted_text.scan(quoted_text_pattern).count
    converted_text = converted_text.gsub(quoted_text_pattern) do
      alt_text = $1.strip
      link_url = $2.strip
      "[#{alt_text}](#{link_url})"
    end
    total_conversions += quoted_conversions
     
    # Regex für mehrzeilige URLs in Backticks: ( \n `url` \n ) - MUSS VOR backtick_url_pattern stehen!
    multiline_backtick_pattern = /\(\s*\n\s*`([^`]+)`\s*\n\s*\)/m
    multiline_conversions = converted_text.scan(multiline_backtick_pattern).count
    converted_text = converted_text.gsub(multiline_backtick_pattern) do
      link_url = $1.strip
      "[#{link_url}](#{link_url})"
    end
    total_conversions += multiline_conversions
     
    # Regex für URLs in Backticks ohne Alt-Text: ( `url` )
    backtick_url_pattern = /\(\s*`([^`]+)`\s*\)/
    backtick_conversions = converted_text.scan(backtick_url_pattern).count
    converted_text = converted_text.gsub(backtick_url_pattern) do
      link_url = $1.strip
      "[#{link_url}](#{link_url})"
    end
    total_conversions += backtick_conversions
     
    # Regex für URLs in Backticks ohne Klammern: \n `url`
    standalone_backtick_pattern = /\n\s*`([^`]+)`\s*(?=\n|$)/
    standalone_conversions = converted_text.scan(standalone_backtick_pattern).count
    converted_text = converted_text.gsub(standalone_backtick_pattern) do
      link_url = $1.strip
      "\n[#{link_url}](#{link_url})"
    end
    total_conversions += standalone_conversions
     
    # Regex für Telefonnummern mit tel:-Links (erfasst nur Telefonnummer vor <tel:>)
    tel_pattern = /([\d\s\(\)\+\-\.]+)\s*<\s*tel:([^>]+)\s*>/
    tel_conversions = converted_text.scan(tel_pattern).count
    converted_text = converted_text.gsub(tel_pattern) do
      phone_text = $1.strip
      tel_link   = $2.strip
      "[#{phone_text}](tel:#{tel_link})"
    end
    total_conversions += tel_conversions
     
    # Regex für URLs: beide Richtungen (Text<URL> oder <URL> Text)
    url_pattern = /
      (?:                             # Entweder:
        ([^\s<>]+)\s*<\s*(https?:\/\/[^>]+)\s*>   # Text vor URL
        |
        <\s*(https?:\/\/[^>]+)\s*>\s*([^\s<>]+)   # URL vor Text
      )
    /x

    url_conversions = converted_text.scan(url_pattern).count
    converted_text = converted_text.gsub(url_pattern) do
      if $1 && $2
        url_text = $1.strip
        url_link = $2.strip
      else
        url_text = $4.strip
        url_link = $3.strip
      end
      "[#{url_text}](#{url_link})"
    end
    total_conversions += url_conversions
    
    # Regex für URLs mit spitzen Klammern und Backticks: < `https://example.com/>`  www.example.com -> [www.example.com](https://example.com/)
    angle_backtick_pattern = /<\s*`([^>]+)>`\s*([^\n]+)/
    angle_backtick_conversions = converted_text.scan(angle_backtick_pattern).count
    converted_text = converted_text.gsub(angle_backtick_pattern) do
      url_link = $1.strip
      url_text = $2.strip
      "[#{url_text}](#{url_link})"
    end
    total_conversions += angle_backtick_conversions
    
    # Log nur wenn Änderungen vorgenommen wurden
     if total_conversions > 0
       @logger.debug("Markdown-Link-Filter angewendet: #{total_conversions} Links konvertiert (#{markdown_conversions} Markdown, #{quoted_conversions} Quoted, #{backtick_conversions} Backtick, #{multiline_conversions} Multiline, #{standalone_conversions} Standalone, #{tel_conversions} Tel, #{url_conversions} URL, #{angle_backtick_conversions} AngleBracket, #{mailto_conversions} Mailto)")
     end
    
    converted_text
  end





  # Alias für Rückwärtskompatibilität
  alias_method :get_smtp_settings, :get_smtp_configuration
end
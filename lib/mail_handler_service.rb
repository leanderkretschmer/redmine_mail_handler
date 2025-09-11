require 'net/imap'
require 'mail'
require 'mime/types'
require 'nokogiri'
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

  # Public API: Import unread mails (optionally limit count)
  def import_mails(limit = nil)
    MailHandlerLogger.reset_logger_state
    @logger.info("Starting mail import process")
    imap = connect_to_imap
    return false unless imap

    imap.select(@settings['inbox_folder'] || 'INBOX')
    message_ids = imap.search(['UNSEEN'])
    message_ids = message_ids.first(limit.to_i) if limit

    @logger.info("Found #{message_ids.count} unread messages")
    processed = 0

    # Process reversed so moves don't invalidate remaining ids
    message_ids.reverse.each do |msg_id|
      begin
        process_message(imap, msg_id)
        processed += 1
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
        @logger.debug("Backtrace: #{e.backtrace&.first(5)&.join("\n")}")
      end
    end

    @logger.info("Processed #{processed} messages successfully")
    imap.disconnect
    true
  rescue => e
    @logger.error("Mail import failed: #{e.message}")
    false
  end

  # Process deferred folder messages
  def process_deferred_mails
    @logger.info("Starting deferred mail processing")
    imap = connect_to_imap
    return unless imap

    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    begin
      imap.select(deferred_folder)
    rescue Net::IMAP::NoResponseError
      @logger.info("Deferred folder '#{deferred_folder}' does not exist, nothing to process")
      imap.disconnect
      return
    end

    message_ids = imap.search(['ALL'])
    @logger.info("Found #{message_ids.length} messages in deferred")
    processed_count = 0
    expired_count = 0

    message_ids.each do |msg_id|
      begin
        result = process_deferred_message(imap, msg_id)
        processed_count += 1 if result == :processed
        expired_count += 1 if result == :expired
      rescue => e
        @logger.error("Error processing deferred message #{msg_id}: #{e.class.name} - #{e.message}")
      end
    end

    @logger.info("Deferred processing completed: #{processed_count} processed, #{expired_count} expired")
  rescue => e
    @logger.error("Deferred processing failed: #{e.class.name} - #{e.message}")
    @logger.debug("Backtrace: #{e.backtrace&.first(10)&.join("\n")}")
  ensure
    imap&.disconnect
  end

  # Cleanup expired deferred DB entries
  def cleanup_expired_deferred
    @logger.info("Starting cleanup of expired deferred entries")
    expired_entries = MailDeferredEntry.expired
    deleted_count = expired_entries.count
    expired_entries.delete_all
    @logger.info("Cleanup completed: #{deleted_count} expired deferred entries removed")
    deleted_count
  rescue => e
    @logger.error("Failed to cleanup expired deferred entries: #{e.message}")
    0
  end

  # Test IMAP connection
  def test_connection
    imap = connect_to_imap
    return { success: false, error: 'Unable to connect' } unless imap
    folders = imap.list('', '*')
    imap.disconnect
    @logger.info("IMAP connection test successful")
    { success: true, folders: folders.map(&:name) }
  rescue => e
    @logger.error("IMAP connection test failed: #{e.message}")
    { success: false, error: e.message }
  end

  # Send a test mail (simple)
  def send_test_mail(to_address, subject = 'Test Mail from Redmine Mail Handler')
    if to_address.blank? || !valid_email_format?(to_address)
      @logger.error("Ungültige E-Mail-Adresse: #{to_address}")
      return false
    end

    from_address = get_smtp_from_address
    if from_address.blank?
      @logger.error("Absender-E-Mail-Adresse ist nicht konfiguriert.")
      return false
    end

    mail = Mail.new do
      from    from_address
      to      to_address
      subject subject
      body    "Dies ist eine Test-E-Mail vom Redmine Mail Handler Plugin.\n\nZeit: #{Time.current.in_time_zone('Europe/Berlin').strftime('%d.%m.%Y %H:%M:%S')}"
    end

    smtp_config = get_smtp_configuration
    unless smtp_config
      @logger.error("Keine SMTP-Konfiguration gefunden.")
      return false
    end

    mail.delivery_method :smtp, smtp_config
    mail.deliver!
    @logger.info("Test mail sent successfully to #{to_address}")
    true
  rescue Net::SMTPAuthenticationError => e
    @logger.error("SMTP Authentication failed: #{e.message}")
    false
  rescue OpenSSL::SSL::SSLError => e
    @logger.error("SSL-Fehler: #{e.message}")
    false
  rescue Errno::ECONNREFUSED => e
    @logger.error("Verbindung zum SMTP-Server verweigert: #{e.message}")
    false
  rescue => e
    @logger.error("Failed to send test mail: #{e.message}")
    false
  end

  # List IMAP folders (debug)
  def list_imap_folders
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

  # Process a single deferred DB entry by searching IMAP for its message-id
  def process_single_deferred_mail(deferred_entry)
    @logger.info("Processing single deferred mail from #{deferred_entry.from_address}")
    imap = connect_to_imap
    return false unless imap
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    imap.select(deferred_folder)
    message_ids = imap.search(['HEADER', 'Message-ID', deferred_entry.message_id])
    if message_ids.empty?
      @logger.warn("Deferred mail with Message-ID #{deferred_entry.message_id} not found in #{deferred_folder}")
      imap.disconnect
      return false
    end
    result = process_message(imap, message_ids.first)
    deferred_entry.destroy if result
    imap.disconnect
    result
  rescue => e
    @logger.error("Error processing single deferred mail: #{e.message}")
    false
  end

  # Create new user (locked) when needed
  def create_new_user(email)
    return nil if email.blank?
    normalized = email.to_s.strip.downcase
    return nil unless valid_email_format?(normalized)

    firstname = get_user_firstname(normalized)
    lastname = get_user_lastname

    user = User.new(
      firstname: firstname,
      lastname: lastname,
      login: normalized,
      status: User::STATUS_LOCKED,
      mail_notification: 'none'
    )
    user.mail = normalized

    if user.save
      @logger.info("Created new user for #{normalized} (locked)")
      begin
        EmailAddress.find_or_create_by!(address: normalized) do |ea|
          ea.user = user
          ea.is_default = true
        end
      rescue => e
        @logger.warn("Failed to create EmailAddress for user #{user.id}: #{e.message}")
      end
      user
    else
      @logger.error("Failed to create user for #{normalized}: #{user.errors.full_messages.join(', ')}")
      nil
    end
  rescue => e
    @logger.error("Error creating user for #{normalized}: #{e.message}")
    nil
  end

  def get_user_firstname(email)
    case (@settings['user_firstname_type'] || 'mail_account')
    when 'mail_account' then email.split('@').first
    when 'mail_address' then email
    else email.split('@').first
    end
  end

  def get_user_lastname
    @settings['user_lastname_custom'] || 'Auto-generated'
  end

  def should_ignore_email?(from_address)
    return false if @settings['ignore_email_addresses'].blank?
    ignore_patterns = @settings['ignore_email_addresses'].split("\n").map(&:strip).reject(&:blank?)
    ignore_patterns.any? do |pattern|
      if pattern.include?('*')
        regex = Regexp.new('\A' + Regexp.escape(pattern).gsub('\\*', '.*') + '\z', Regexp::IGNORECASE)
        from_address =~ regex
      else
        from_address.casecmp?(pattern)
      end
    end
  end

  private

  # --- Encoding / helper utilities ---

  # Try to convert raw content bytes into UTF-8. Accepts an optional charset
  # hint (e.g. "ISO-8859-1" or "utf-8"). Robust fallbacks are attempted.
  def ensure_utf8_encoding(content, charset = nil)
    return "" if content.nil?

    str = content.dup.force_encoding('ASCII-8BIT') # raw bytes

    if charset.present?
      begin
        encoding = Encoding.find(charset) rescue nil
        if encoding
          str.force_encoding(encoding)
          return str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
        end
      rescue => e
        @logger&.warn("Charset conversion failed (#{charset}): #{e.message}")
      end
    end

    # Try common encodings heuristically
    begin
      result = str.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      
      # Remove CSS styling from plain-text emails
      result = result.gsub(/#[a-zA-Z0-9_-]+\s*\{[^}]*\}/, ' ')  # CSS rules like #outlookholder
      result = result.gsub(/\.[a-zA-Z0-9_-]+\s*\{[^}]*\}/, ' ')  # CSS classes like .qfbf
      result = result.gsub(/\{[^}]*\}/, ' ')  # Any remaining curly brace blocks
      result = result.gsub(/font-family\s*:[^;]*;?/i, ' ')  # font-family properties
      result = result.gsub(/width\s*:[^;]*;?/i, ' ')  # width properties
      result = result.gsub(/!important/i, ' ')  # !important declarations
      result = result.gsub(/\s+/, ' ').strip  # Normalize whitespace
      
      return result
    rescue
    end

    ['Windows-1252', 'ISO-8859-1', 'ASCII'].each do |enc|
      begin
        return str.force_encoding(enc).encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      rescue
        next
      end
    end

    # Last resort: force UTF-8
    str.force_encoding('UTF-8')
  rescue => e
    @logger&.warn("ensure_utf8_encoding unexpected error: #{e.message}")
    content.to_s.force_encoding('UTF-8')
  end

  def valid_email_format?(email)
    !!(email =~ /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i)
  end

  # --- IMAP connection with retries ---
  def connect_to_imap(max_retries = 3)
    if @settings['imap_host'].blank?
      @logger.error("IMAP-Host ist nicht konfiguriert.")
      return nil
    end
    if @settings['imap_username'].blank? || @settings['imap_password'].blank?
      @logger.error("IMAP-Benutzername oder -Passwort ist nicht konfiguriert.")
      return nil
    end

    port = (@settings['imap_port'].presence || 993).to_i
    use_ssl = @settings['imap_ssl'] == '1'
    attempts = 0

    begin
      attempts += 1
      @logger.debug("Connecting to IMAP #{@settings['imap_host']}:#{port} SSL=#{use_ssl} (attempt #{attempts})")

      imap_options = { port: port, ssl: use_ssl }
      imap_options[:ssl] = { verify_mode: OpenSSL::SSL::VERIFY_PEER } if use_ssl

      Timeout.timeout(30) do
        imap = Net::IMAP.new(@settings['imap_host'], **imap_options)
        Timeout.timeout(15) { imap.login(@settings['imap_username'], @settings['imap_password']) }
        @logger.debug("Connected to IMAP #{@settings['imap_host']}")
        return imap
      end
    rescue Timeout::Error, Net::IMAP::NoResponseError, Net::IMAP::BadResponseError,
           Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError, OpenSSL::SSL::SSLError => e
      @logger.warn("IMAP connection attempt #{attempts} failed: #{e.class.name} - #{e.message}")
      if attempts <= max_retries
        sleep_time = [2 ** attempts, 30].min
        @logger.info("Retrying IMAP connection in #{sleep_time} seconds...")
        sleep(sleep_time)
        retry
      end
    rescue => e
      @logger.warn("IMAP connection unexpected error: #{e.class.name} - #{e.message}")
    end

    @logger.error("Failed to connect to IMAP after #{max_retries + 1} attempts")
    nil
  end

  # --- Message processing ---

  def process_message(imap, msg_id)
    # Ensure message still valid
    begin
      imap.fetch(msg_id, 'UID')
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('Invalid messageset')
        @logger.debug("Message #{msg_id} is invalid or already processed, skipping")
        return
      else
        raise
      end
    end

    msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822'] rescue nil
    if msg_data.blank?
      @logger.error("Empty mail data for message #{msg_id}, skipping")
      return
    end

    mail = Mail.read_from_string(msg_data) rescue nil
    if mail.nil?
      @logger.error("Failed to parse mail object for message #{msg_id}, skipping")
      return
    end

    from_address = mail.from&.first
    if from_address.blank?
      @logger.error("Mail has no valid from address, skipping message #{msg_id}")
      return
    end

    @logger.debug_mail("Processing mail from #{from_address} subject: #{mail.subject}", mail)

    if should_ignore_email?(from_address)
      @logger.info("Mail from #{from_address} matches ignore pattern, moving to deferred")
      defer_message(imap, msg_id, mail, 'ignored')
      return
    end

    ticket_id = extract_ticket_id(mail.subject)
    existing_user = find_existing_user(from_address)

    if existing_user
      if ticket_id
        add_mail_to_ticket(mail, ticket_id, existing_user)
      else
        add_mail_to_inbox_ticket(mail, existing_user)
      end
    elsif ticket_id
      new_user = create_new_user(from_address)
      if new_user
        add_mail_to_ticket(mail, ticket_id, new_user)
      else
        @logger.error("Failed to create user for #{from_address}, cannot process mail")
      end
    else
      @logger.info("Moving mail from unknown user #{from_address} without ticket ID to deferred")
      defer_message(imap, msg_id, mail)
      return
    end

    archive_message(imap, msg_id, mail)
  end

  def extract_ticket_id(subject)
    return nil unless subject
    match = subject.match(/\[(?:.*?\s)?#(\d+)\]/)
    match ? match[1].to_i : nil
  end

  def find_existing_user(email)
    return nil if email.blank?
    normalized = email.to_s.strip.downcase
    return nil unless valid_email_format?(normalized)
    email_address_obj = EmailAddress.find_by(address: normalized)
    user = email_address_obj&.user
    @logger.debug("Found existing user for #{normalized}: #{user&.login}") if user
    user
  end

  # --- Content handling and HTML stripping ---
  # Ensure all content that becomes a Redmine comment is plain text
  # with no HTML syntax, attributes, spans etc.

  # Decode mail content and produce a plain-text body to be used as comment.
  def decode_mail_content(mail)
    parts_text = []
    parts_text << "**Betreff:** #{mail.subject}\n\n" if mail.subject.present?

    if mail.multipart?
      # Prefer text/plain parts, fallback to text/html, otherwise decode whole mail
      text_part = find_part(mail, 'text/plain')
      if text_part
        charset = part_charset(text_part)
        body = safe_part_body(text_part)
        parts_text << sanitize_to_plain_text(body, html: false, part_charset: charset)
      else
        html_part = find_part(mail, 'text/html')
        if html_part
          charset = part_charset(html_part)
          body = safe_part_body(html_part)
          parts_text << sanitize_to_plain_text(body, html: true, part_charset: charset)
        else
          raw = mail.decoded rescue (mail.body && mail.body.raw_source)
          html_guess = raw.to_s =~ /<\/?[a-z][\s\S]*>/i
          parts_text << sanitize_to_plain_text(raw, html: html_guess)
        end
      end
    else
      # Singlepart: try to use charset info
      part = mail
      charset = part_charset(part)
      body = safe_part_body(part)
      is_html = body.to_s =~ /<\/?[a-z][\s\S]*>/i
      parts_text << sanitize_to_plain_text(body, html: is_html, part_charset: charset)
    end

    if mail.attachments&.any?
      parts_text << "\n\n*Diese E-Mail enthält #{mail.attachments.count} Anhang(e), die als separate Dateien angehängt wurden.*"
    end

    result = parts_text.compact.join("\n\n")
    normalize_whitespace(result)
  end

  # Find part by mime-type (includes nested multipart)
  def find_part(mail, mime_type)
    return mail if (mail.mime_type == mime_type) && mail.body
    if mail.multipart?
      mail.parts.each do |p|
        found = find_part(p, mime_type)
        return found if found
      end
    end
    nil
  end

  def part_charset(part)
    begin
      params = (part.content_type_parameters || {})
      charset = params['charset'] || params[:charset]
      charset&.to_s
    rescue
      nil
    end
  end

  # Safely get decoded body; fallback to raw source if Mail gem fails
  def safe_part_body(part)
    begin
      body = part.decoded
      return body if body.present?
    rescue => e
      @logger.debug("Part decoded error: #{e.message}")
    end
    # fallback
    (part.body && part.body.raw_source) || ''
  end

  # Convert HTML (or plain) content to plain text, aggressively removing any HTML
  # and ensuring no leftover tags, attributes or entities remain.
  def sanitize_to_plain_text(content, html: false, part_charset: nil)
    return "" if content.nil?

    # Step 1: Charset-aware decode to UTF-8
    text = ensure_utf8_encoding(content.to_s, part_charset)

    if html
      # Parse HTML, remove scripts/styles/comments, replace blocks and br with newlines
      doc = Nokogiri::HTML.fragment(text)

      doc.search('script, style').remove
      doc.xpath('//comment()').remove

      # Convert <br> to newline and ensure block elements separated
      doc.search('br').each { |n| n.replace("\n") }
      %w[p div h1 h2 h3 h4 h5 h6 li tr].each do |tag|
        doc.search(tag).each { |n| n.add_next_sibling(Nokogiri::XML::Text.new("\n", doc)) }
      end

      text = doc.text.to_s
    else
      # Plain text: remove soft linebreaks (quoted-printable)
      text = text.gsub(/=\r?\n/, '')
    end

    # Decode HTML entities & URL-encoded pieces
    begin
      text = CGI.unescapeHTML(text)
    rescue
      # ignore
    end
    text = CGI.unescape(text) rescue text

    # Multi-pass HTML tag removal for aggressive cleaning
    3.times do
      text = text.gsub(/<[^>]*>/, ' ')  # Standard tags
      text = text.gsub(/<\s*[^>]*>/, ' ')  # Tags with leading spaces
      text = text.gsub(/\w+\s*=\s*(['"])[^'"]*\1/, ' ')  # Inline style attributes
    end

    # Remove CSS blocks and style definitions
    text = text.gsub(/#[a-zA-Z0-9_-]+\s*\{[^}]*\}/, ' ')  # CSS rules like #outlookholder
    text = text.gsub(/\.[a-zA-Z0-9_-]+\s*\{[^}]*\}/, ' ')  # CSS classes like .qfbf
    text = text.gsub(/\{[^}]*\}/, ' ')  # Any remaining curly brace blocks
    text = text.gsub(/font-family\s*:[^;]*;?/i, ' ')  # font-family properties
    text = text.gsub(/width\s*:[^;]*;?/i, ' ')  # width properties
    text = text.gsub(/!important/i, ' ')  # !important declarations

    # Normalize whitespace and remove control characters
    text = text.gsub(/\r\n?/, "\n")
    text = text.gsub(/\u00A0/, ' ')
    text = text.gsub(/[[:cntrl:]]/, '') # remove control chars
    text = text.gsub(/[ \t]{2,}/, ' ')
    text = text.gsub(/\n{3,}/, "\n\n")
    text = text.strip
    text
  rescue => e
    @logger.warn("sanitize_to_plain_text failed: #{e.message}")
    content.to_s.gsub(/<[^>]*>/, ' ').gsub(/\s+/, ' ').strip
  end

  def normalize_whitespace(text)
    return "" if text.blank?
    text = text.to_s
    text = text.gsub(/\r\n?/, "\n")
    text = text.gsub(/\n{3,}/, "\n\n")
    
    # Intelligente Behandlung von führenden Leerzeichen:
    # - Entferne führende Leerzeichen von jeder Zeile
    # - Erhalte aber die Zeilenstruktur und Absätze
    lines = text.split("\n")
    lines = lines.map do |line|
      # Entferne führende Leerzeichen und Tabs, aber erhalte die Zeile
      line.gsub(/^[ \t]+/, '').rstrip
    end
    
    text = lines.join("\n")
    text.strip
  end

  # --- Attachments processing ---
  def process_mail_attachments(mail, ticket, user)
    return unless mail.attachments&.any?
    mail.attachments.each do |attachment|
      begin
        next if attachment.filename.blank? || attachment.body.blank?

        temp_file = Tempfile.new([sanitize_filename_base(attachment.filename), File.extname(attachment.filename)])
        temp_file.binmode
        temp_file.write(attachment.body.decoded)
        temp_file.rewind

        # Determine MIME type, fallback to mime-types gem
        mime = begin
          ct = (attachment.content_type.to_s || '').split(';').first
          ct.presence
        rescue
          nil
        end

        if mime.blank? || mime =~ %r{\Aapplication/octet-stream}i
          guessed = MIME::Types.type_for(attachment.filename.to_s).first
          mime = guessed&.content_type if guessed
        end

        content_type = mime.presence || 'application/octet-stream'

        redmine_attachment = Attachment.new(
          file: temp_file,
          filename: attachment.filename,
          author: user,
          content_type: content_type
        )

        if redmine_attachment.save
          ticket.attachments << redmine_attachment
          @logger.info("Attached file #{attachment.filename} to ticket ##{ticket.id}")
        else
          @logger.error("Failed to save attachment #{attachment.filename}: #{redmine_attachment.errors.full_messages.join(', ')}")
        end
      rescue => e
        @logger.error("Error processing attachment #{attachment.filename}: #{e.message}")
      ensure
        temp_file&.close
        temp_file&.unlink
      end
    end
  end

  def sanitize_filename_base(name)
    base = File.basename(name, ".*")
    base.gsub(/[^\w\-.]/, '_')[0, 128]
  end

  # --- Add mail to ticket / inbox ticket ---

  def add_mail_to_ticket(mail, ticket_id, user)
    ticket = Issue.find_by(id: ticket_id)
    unless ticket
      @logger.error_mail("Ticket ##{ticket_id} not found, forwarding to inbox ticket", mail, ticket_id)
      add_mail_to_inbox_ticket(mail, user)
      return
    end

    content = decode_mail_content(mail)
    journal = ticket.init_journal(user, content)
    process_mail_attachments(mail, ticket, user)

    if ticket.save
      @logger.info_mail("Added mail content to ticket ##{ticket_id}", mail, ticket_id)
    else
      @logger.error_mail("Failed to add mail to ticket ##{ticket_id}: #{ticket.errors.full_messages.join(', ')}", mail, ticket_id)
    end
  end

  def add_mail_to_inbox_ticket(mail, user)
    inbox_ticket_id = @settings['inbox_ticket_id'].to_i
    unless inbox_ticket_id > 0
      @logger.warn("No inbox ticket ID configured, cannot process mail from #{mail.from&.first}")
      return
    end
    add_mail_to_ticket(mail, inbox_ticket_id, user)
  end

  # --- Archiving / deferring ---

  def archive_message(imap, msg_id, mail = nil)
    return unless @settings['archive_folder'].present?
    uid_data = imap.fetch(msg_id, 'UID') rescue nil
    unless uid_data && uid_data.first
      @logger.debug("Message #{msg_id} invalid or already processed, skipping archive")
      return
    end

    ensure_archive_folder_exists(imap)

    begin
      imap.move(msg_id, @settings['archive_folder'])
      @logger.info_mail("Moved message #{msg_id} to archive '#{@settings['archive_folder']}'", mail)
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('TRYCREATE')
        create_archive_folder(imap)
        retry
      elsif e.message.include?('NO MOVE')
        imap.copy(msg_id, @settings['archive_folder'])
        imap.store(msg_id, '+FLAGS', [:Deleted])
        imap.expunge
        @logger.info("Copied and deleted message #{msg_id} to archive (fallback)")
      else
        @logger.warn("Failed to archive message #{msg_id}: #{e.message}")
      end
    rescue => e
      @logger.error("Unexpected error archiving message #{msg_id}: #{e.class.name} - #{e.message}")
    end
  end

  def defer_message(imap, msg_id, mail, reason = 'unknown_user')
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    ensure_deferred_folder_exists(imap)
    begin
      imap.move(msg_id, deferred_folder)
      @logger.info_mail("Moved message #{msg_id} to deferred '#{deferred_folder}'", mail)
      save_deferred_timestamp(mail, Time.current, reason)
    rescue Net::IMAP::BadResponseError => e
      if e.message.include?('TRYCREATE')
        create_deferred_folder(imap)
        retry
      elsif e.message.include?('NO MOVE')
        imap.copy(msg_id, deferred_folder)
        imap.store(msg_id, '+FLAGS', [:Deleted])
        imap.expunge
        save_deferred_timestamp(mail, Time.current, reason)
      else
        @logger.warn("Failed to defer message #{msg_id}: #{e.message}")
      end
    rescue => e
      @logger.error("Unexpected error deferring message #{msg_id}: #{e.class.name} - #{e.message}")
    end
  end

  def ensure_archive_folder_exists(imap)
    return unless @settings['archive_folder'].present?
    folders = imap.list('', '*') rescue []
    folder_names = folders.map(&:name)
    create_archive_folder(imap) unless folder_names.include?(@settings['archive_folder'])
  rescue => e
    @logger.warn("Could not check archive folder existence: #{e.message}")
  end

  def create_archive_folder(imap)
    imap.create(@settings['archive_folder'])
    @logger.info("Created archive folder '#{@settings['archive_folder']}'")
  rescue => e
    @logger.error("Failed to create archive folder '#{@settings['archive_folder']}': #{e.message}")
  end

  def ensure_deferred_folder_exists(imap)
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    return unless deferred_folder.present?
    folders = imap.list('', '*') rescue []
    folder_names = folders.map(&:name)
    create_deferred_folder(imap) unless folder_names.include?(deferred_folder)
  rescue => e
    @logger.warn("Could not check deferred folder existence: #{e.message}")
  end

  def create_deferred_folder(imap)
    deferred_folder = @settings['deferred_folder'] || 'Deferred'
    imap.create(deferred_folder)
    @logger.info("Created deferred folder '#{deferred_folder}'")
  rescue => e
    @logger.error("Failed to create deferred folder '#{deferred_folder}': #{e.message}")
  end

  def save_deferred_timestamp(mail, timestamp, reason = 'unknown_user')
    return unless mail&.message_id
    deferred_entry = MailDeferredEntry.find_or_initialize_by(message_id: mail.message_id)
    deferred_entry.update!(
      from_address: mail.from&.first,
      subject: mail.subject,
      deferred_at: timestamp,
      expires_at: timestamp + (@settings['deferred_lifetime_days'] || 30).to_i.days,
      reason: reason
    )
    @logger.debug("Saved deferred timestamp for #{mail.message_id} reason: #{reason}")
  rescue => e
    @logger.error("Failed to save deferred timestamp for #{mail.message_id}: #{e.message}")
  end

  def process_deferred_message(imap, msg_id)
    msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822'] rescue nil
    if msg_data.blank?
      @logger.error("Empty mail data for deferred message #{msg_id}, skipping")
      return :skipped
    end

    mail = Mail.read_from_string(msg_data) rescue nil
    return :skipped unless mail

    deferred_entry = MailDeferredEntry.find_by(message_id: mail.message_id)
    if deferred_entry&.expired?
      @logger.info("Deferral expired for message #{msg_id}, moving to archive")
      archive_message(imap, msg_id, mail)
      deferred_entry.destroy if deferred_entry
      return :expired
    end

    from_address = mail.from&.first
    return :skipped if from_address.blank?

    existing_user = find_existing_user(from_address)
    if existing_user
      @logger.info("User #{from_address} now exists, processing deferred message #{msg_id}")
      ticket_id = extract_ticket_id(mail.subject)
      if ticket_id
        add_mail_to_ticket(mail, ticket_id, existing_user)
      else
        add_mail_to_inbox_ticket(mail, existing_user)
      end
      archive_message(imap, msg_id, mail)
      deferred_entry.destroy if deferred_entry
      return :processed
    else
      @logger.debug("User #{from_address} still does not exist, keeping message #{msg_id} deferred")
      return :kept
    end
  end

  # --- SMTP configuration helpers ---

  def get_smtp_configuration
    if @settings['smtp_same_as_imap'] == '1'
      get_smtp_from_imap_settings
    elsif @settings['smtp_host'].present?
      get_plugin_smtp_settings
    else
      get_redmine_smtp_settings
    end
  end

  def get_smtp_from_imap_settings
    return nil if @settings['imap_host'].blank?
    smtp_host = @settings['imap_host'].gsub(/^imap\./, 'smtp.')
    if @settings['imap_ssl'] == '1'
      smtp_port = 465
      use_ssl = true
      use_starttls = false
    else
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

  def get_plugin_smtp_settings
    smtp_port = (@settings['smtp_port'].presence || 587).to_i
    use_ssl = (@settings['smtp_ssl'] == '1' || smtp_port == 465)
    {
      address: @settings['smtp_host'],
      port: smtp_port,
      domain: @settings['smtp_host'].split('.')[1..-1].join('.'),
      user_name: @settings['smtp_username'],
      password: @settings['smtp_password'],
      authentication: :plain,
      enable_starttls_auto: !use_ssl,
      ssl: use_ssl
    }
  end

  def get_redmine_smtp_settings
    smtp_settings = ActionMailer::Base.smtp_settings
    return smtp_settings if smtp_settings.present? && smtp_settings[:address].present?
    if Setting.email_delivery.present? && Setting.email_delivery['smtp_settings'].present?
      cfg = Setting.email_delivery['smtp_settings']
      return {
        address: cfg['address'],
        port: cfg['port'] || 587,
        domain: cfg['domain'],
        user_name: cfg['user_name'],
        password: cfg['password'],
        authentication: cfg['authentication'] || :plain,
        enable_starttls_auto: cfg['enable_starttls_auto'] != false
      } if cfg['address'].present?
    end
    nil
  end

  def get_smtp_from_address
    if @settings['smtp_same_as_imap'] == '1' && @settings['imap_username'].present?
      @settings['imap_username']
    elsif @settings['smtp_username'].present?
      @settings['smtp_username']
    else
      Setting.mail_from
    end
  end

  alias_method :get_smtp_settings, :get_smtp_configuration
end
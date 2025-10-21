class MailHandlerLogger
  require 'fileutils'
  require 'logger'
  
  LOG_LEVELS = {
    'debug' => 0,
    'info' => 1,
    'warn' => 2,
    'error' => 3
  }.freeze

  @@last_message = nil
  @@repeat_count = 0
  @@last_log_id = nil
  @@mutex = Mutex.new
  @@import_session_logs = []
  @@import_session_start = nil
  @@custom_logger = nil

  def initialize
    @settings = Setting.plugin_redmine_mail_handler
    # File-basiertes Logging: keine DB-Tabellenprüfung notwendig
    setup_custom_logger
  end

  private

  def setup_custom_logger
    return if @@custom_logger

    # Primärer Pfad: /usr/src/redmine/log/redmine_mail_handler.log
    # Fallback-Pfad: Rails.root/log/redmine_mail_handler.log
    primary_log_path = '/usr/src/redmine/log/redmine_mail_handler.log'
    fallback_log_path = defined?(Rails) && Rails.root ? 
                        File.join(Rails.root, 'log', 'redmine_mail_handler.log') :
                        File.join(Dir.pwd, 'log', 'redmine_mail_handler.log')
    
    log_file_path = nil
    
    begin
      # Versuche primären Pfad zu verwenden
      log_dir = File.dirname(primary_log_path)
      if Dir.exist?(log_dir) || (FileUtils.mkdir_p(log_dir) rescue false)
        log_file_path = primary_log_path
      else
        raise "Cannot create primary log directory"
      end
    rescue => e
      # Fallback auf Rails log Verzeichnis
      begin
        log_dir = File.dirname(fallback_log_path)
        FileUtils.mkdir_p(log_dir) unless Dir.exist?(log_dir)
        log_file_path = fallback_log_path
        Rails.logger.warn "[MailHandler] Using fallback log path: #{log_file_path} (Primary path failed: #{e.message})"
      rescue => fallback_error
        Rails.logger.error "[MailHandler] Failed to setup custom logger: #{fallback_error.message}"
        @@custom_logger = nil
        return
      end
    end
    
    begin
      # Erstelle Custom Logger
      @@custom_logger = ::Logger.new(log_file_path, 'daily')
      @@custom_logger.level = ::Logger::DEBUG
      @@custom_logger.formatter = proc do |severity, datetime, progname, msg|
        "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
      end
      
      Rails.logger.info "[MailHandler] Custom logger initialized: #{log_file_path}"
    rescue => e
      Rails.logger.error "[MailHandler] Failed to setup custom logger: #{e.message}"
      @@custom_logger = nil
    end
  end

  def write_to_custom_log(level, message)
    return unless @@custom_logger
    
    begin
      case level.to_s.downcase
      when 'debug'
        @@custom_logger.debug(message)
      when 'info'
        @@custom_logger.info(message)
      when 'warn'
        @@custom_logger.warn(message)
      when 'error'
        @@custom_logger.error(message)
      else
        @@custom_logger.info(message)
      end
    rescue => e
      Rails.logger.error "[MailHandler] Failed to write to custom log: #{e.message}"
    end
  end

  public

  def debug(message)
    log('debug', message)
  end

  def info(message)
    log('info', message)
  end

  def warn(message)
    log('warn', message)
  end

  def error(message)
    log('error', message)
  end

  # Erweiterte Logging-Methoden mit Mail-Details
  def log_mail_processing(level, message, mail = nil, ticket_id = nil)
    log_with_details(level, message, mail, ticket_id)
  end

  def info_mail(message, mail = nil, ticket_id = nil)
    log_with_details('info', message, mail, ticket_id)
  end

  def error_mail(message, mail = nil, ticket_id = nil)
    log_with_details('error', message, mail, ticket_id)
  end

  def debug_mail(message, mail = nil, ticket_id = nil)
    log_with_details('debug', message, mail, ticket_id)
  end
  
  # Spezielle Methode für Load-Balanced Import Logging
  def info_load_balanced(message, mail = nil, ticket_id = nil)
    enhanced_message = "[LOAD-BALANCED] #{message}"
    log_with_details('info', enhanced_message, mail, ticket_id)
  end

  # Hole Logs mit Paginierung
  def self.get_logs(page = 1, per_page = 50, level = nil)
    query = MailHandlerLog.order(created_at: :desc)
    query = query.where(level: level) if level.present?
    
    query.page(page).per(per_page)
  end

  # Lösche alte Logs (älter als 30 Tage)
  def self.cleanup_old_logs
    MailHandlerLog.where('created_at < ?', 30.days.ago).delete_all
  end

  # Setze Logger-Status zurück (für neue Import-Sessions)
  def self.reset_logger_state
    @@mutex.synchronize do
      @@last_message = nil
      @@repeat_count = 0
      @@last_log_id = nil
    end
  end

  private

  def log_with_details(level, message, mail = nil, ticket_id = nil)
    return unless should_log?(level)
    
    @@mutex.synchronize do
      # Extrahiere Mail-Details falls verfügbar
      mail_subject = nil
      mail_from = nil
      mail_message_id = nil
      
      if mail.respond_to?(:subject)
        mail_subject = mail.subject.to_s.strip if mail.subject
        mail_from = mail.from&.first.to_s.strip if mail.from&.first
        mail_message_id = mail.message_id.to_s.strip if mail.message_id
      end
      
      # Immer in Rails-Log schreiben (keine DB-Speicherung)
      Rails.logger.send(level, "[MailHandler] #{message}")
      
      # Zusätzlich in Custom Log schreiben
      write_to_custom_log(level, message)
      
      # Zusätzlich in Custom Log schreiben
      write_to_custom_log(level, message)
      
      # Zusätzlich in Custom Log schreiben
      write_to_custom_log(level, message)
    end
  end

  def log(level, message)
    return unless should_log?(level)
    
    @@mutex.synchronize do
      # Prüfe auf Mail-Import-Session
      if is_import_session_message?(message)
        handle_import_session_message(level, message)
        return
      end
      
      # Prüfe auf wiederholte Nachrichten (nur bei identischen Nachrichten)
      if @@last_message == message && @@repeat_count < 100  # Begrenze auf max 100 Wiederholungen
        @@repeat_count += 1
        
        # Aktualisiere die letzte Log-Nachricht mit Zähler
        update_last_log_with_count(level, message)
        return
      else
        # Neue Nachricht - setze Zähler zurück
        @@last_message = message
        @@repeat_count = 0
        @@last_log_id = nil
      end
      # Immer in Rails-Log schreiben (keine DB-Speicherung)
      Rails.logger.send(level, "[MailHandler] #{message}")
    end
  end

  def should_log?(level)
    current_level = LOG_LEVELS[@settings['log_level'] || 'info']
    message_level = LOG_LEVELS[level]
    
    message_level >= current_level
  end

  def update_last_log_with_count(level, message)
    # Bei File-basiertem Logging nur ins Rails-Log mit Zähler schreiben
    count_suffix = " (#{@@repeat_count + 1}x)"
    updated_message = message + count_suffix
    Rails.logger.send(level, "[MailHandler] #{updated_message}")
    
    # Zusätzlich in Custom Log schreiben
    write_to_custom_log(level, updated_message)
  end

  # File-basierter Log-Reader
  def self.read_logs(max_lines: 5000)
    require 'ostruct'
    log_file = File.join(Rails.root.to_s, 'log', "#{Rails.env}.log")
    return [] unless File.exist?(log_file)

    lines = []
    File.open(log_file, 'r') do |f|
      f.each_line { |ln| lines << ln }
    end

    lines = lines.last(max_lines)

    entries = []
    lines.each do |ln|
      next unless ln.include?("[MailHandler]")

      parsed = nil

      # Format A: I, [2025-09-26 07:59:38 +0200 #1234]  INFO -- : [MailHandler] Message
      if ln =~ /(\w), \[(.*?)\s[^\]]*\]\s+(\w+)\s+--\s+:\s+\[MailHandler\]\s+(.*)$/
        timestamp_str = $2
        level_str = $3
        message_str = $4.strip
        parsed = [timestamp_str, level_str, message_str]
      end

      # Format B: [2025-09-26 07:59:38 +0200] INFO -- : [MailHandler] Message
      if parsed.nil? && ln =~ /^\[(.*?)\]\s+(\w+)\s+--\s*:\s*\[MailHandler\]\s+(.*)$/
        timestamp_str = $1
        level_str = $2
        message_str = $3.strip
        parsed = [timestamp_str, level_str, message_str]
      end

      # Format C: 2025-09-26 07:59:38 INFO [MailHandler] Message (tagged logging)
      if parsed.nil? && ln =~ /^(\d{4}-\d{2}-\d{2}[ T][^ ]+)\s+(\w+)\b.*?\[MailHandler\]\s+(.*)$/
        timestamp_str = $1
        level_str = $2
        message_str = $3.strip
        parsed = [timestamp_str, level_str, message_str]
      end

      # Format D: INFO -- : [MailHandler] Message (ohne Timestamp)
      if parsed.nil? && ln =~ /^(\w+)\s+--\s*:\s*\[MailHandler\]\s+(.*)$/
        level_str = $1
        message_str = $2.strip
        parsed = [Time.current.to_s, level_str, message_str]
      end

      # Fallback: alles nach Tag übernehmen
      if parsed.nil?
        parts = ln.split('[MailHandler]')
        message_str = parts.last.to_s.strip
        parsed = [Time.current.to_s, 'INFO', message_str]
      end

      timestamp = Time.parse(parsed[0]) rescue Time.current
      level = parsed[1].to_s.downcase
      level = case level
              when 'debug', 'd' then 'debug'
              when 'info', 'i'  then 'info'
              when 'warn', 'warning', 'w' then 'warn'
              when 'error', 'fatal', 'e', 'f' then 'error'
              else 'info'
              end
      message_str = parsed[2]

      entries << OpenStruct.new(
        id: (timestamp.to_f.to_s + message_str.hash.to_s),
        level: level,
        message: message_str,
        created_at: timestamp
      )
    end

    entries.sort_by { |e| -e.created_at.to_f }
  end
  
  # Prüfe ob die Nachricht Teil einer Mail-Import-Session ist
  def is_import_session_message?(message)
    import_keywords = [
      'Starting scheduled mail import',
      'Starting mail import process',
      'Found \\d+ unread messages',
      'Processed \\d+ messages successfully'
    ]
    
    import_keywords.any? { |keyword| message.match?(/#{keyword}/i) }
  end
  
  # Behandle Mail-Import-Session-Nachrichten
  def handle_import_session_message(level, message)
    case message
    when /Starting scheduled mail import/i
      # Neue Import-Session beginnt
      finalize_previous_import_session if @@import_session_logs.any?
      @@import_session_start = Time.current
      @@import_session_logs = [{ level: level, message: message, timestamp: Time.current }]
      
    when /Starting mail import process/i
      # Import-Prozess startet (Teil der Session)
      @@import_session_logs << { level: level, message: message, timestamp: Time.current }
      
    when /Found (\\d+) unread messages/i
      # Anzahl gefundener Nachrichten
      @@import_session_logs << { level: level, message: message, timestamp: Time.current }
      
    when /Processed (\\d+) messages successfully/i
      # Import abgeschlossen - Session finalisieren
      @@import_session_logs << { level: level, message: message, timestamp: Time.current }
      finalize_import_session
      
    else
      # Andere Import-bezogene Nachrichten
      @@import_session_logs << { level: level, message: message, timestamp: Time.current }
    end
    
    # Immer auch in Rails-Log schreiben
    Rails.logger.send(level, "[MailHandler] #{message}")
    
    # Zusätzlich in Custom Log schreiben
    write_to_custom_log(level, message)
  end
  
  # Finalisiere die aktuelle Import-Session
  def finalize_import_session
    return if @@import_session_logs.empty?
    
    begin
      # Zusammenfassung nur ins Rails-Log schreiben
      duration = Time.current - @@import_session_start if @@import_session_start
      found_messages = extract_number_from_logs(/Found (\\d+) unread messages/i)
      processed_messages = extract_number_from_logs(/Processed (\\d+) messages successfully/i)
      summary_message = "Mail Import Session abgeschlossen"
      summary_message += " - #{found_messages} Nachrichten gefunden" if found_messages
      summary_message += ", #{processed_messages} erfolgreich verarbeitet" if processed_messages
      summary_message += " (Dauer: #{duration.round(2)}s)" if duration
      Rails.logger.info("[MailHandler] #{summary_message}")
      
      # Zusätzlich in Custom Log schreiben
      write_to_custom_log('info', summary_message)
    rescue => e
      Rails.logger.error "Failed to finalize import session: #{e.message}"
      @@import_session_logs.each do |log_entry|
        write_single_log_entry(log_entry[:level], log_entry[:message], log_entry[:timestamp])
      end
    ensure
      # Session zurücksetzen
      @@import_session_logs = []
      @@import_session_start = nil
    end
  end
  
  # Finalisiere vorherige Session falls eine neue beginnt
  def finalize_previous_import_session
    finalize_import_session
  end
  
  # Extrahiere Zahlen aus Log-Nachrichten
  def extract_number_from_logs(pattern)
    log_entry = @@import_session_logs.find { |log| log[:message].match?(pattern) }
    return nil unless log_entry
    
    match = log_entry[:message].match(pattern)
    match ? match[1].to_i : nil
  end
  
  # Schreibe einen einzelnen Log-Eintrag
  def write_single_log_entry(level, message, timestamp)
    Rails.logger.send(level, "[MailHandler] #{message}")
    
    # Zusätzlich in Custom Log schreiben
    write_to_custom_log(level, message)
  end
end
class MailHandlerLogger
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

  def initialize
    @settings = Setting.plugin_redmine_mail_handler
    ensure_log_table_exists
  end

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
      
      # Immer in Rails-Log schreiben
      Rails.logger.send(level, "[MailHandler] #{message}")
      
      # Versuche in DB zu schreiben mit Mail-Details
      begin
        ActiveRecord::Base.connection_pool.with_connection do
          log_entry = MailHandlerLog.create!(
            level: level,
            message: message,
            mail_subject: mail_subject,
            mail_from: mail_from,
            mail_message_id: mail_message_id,
            ticket_id: ticket_id,
            created_at: Time.current.in_time_zone('Europe/Berlin')
          )
          
          @@last_log_id = log_entry.id
        end
        
      rescue ActiveRecord::ConnectionTimeoutError => e
        # Keine weitere Aktion bei Connection Timeout - Rails.logger wurde bereits verwendet
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
        # DB nicht verfügbar - nur Rails.logger verwenden
      rescue => e
        Rails.logger.error "Failed to write mail handler log with details: #{e.message}"
      end
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
      # Immer in Rails-Log schreiben
      Rails.logger.send(level, "[MailHandler] #{message}")
      
      # Versuche in DB zu schreiben mit ordnungsgemäßer Verbindungsverwaltung
      begin
        ActiveRecord::Base.connection_pool.with_connection do
          log_entry = MailHandlerLog.create!(
            level: level,
            message: message,
            created_at: Time.current.in_time_zone('Europe/Berlin')
          )
          
          @@last_log_id = log_entry.id
        end
        
      rescue ActiveRecord::ConnectionTimeoutError => e
        # Keine weitere Aktion bei Connection Timeout - Rails.logger wurde bereits verwendet
      rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
        # DB nicht verfügbar - nur Rails.logger verwenden
      rescue => e
        Rails.logger.error "Failed to write mail handler log: #{e.message}"
      end
    end
  end

  def should_log?(level)
    current_level = LOG_LEVELS[@settings['log_level'] || 'info']
    message_level = LOG_LEVELS[level]
    
    message_level >= current_level
  end

  def update_last_log_with_count(level, message)
    return unless @@last_log_id
    
    begin
      ActiveRecord::Base.connection_pool.with_connection do
        # Finde den letzten Log-Eintrag
        last_log = MailHandlerLog.find_by(id: @@last_log_id)
        return unless last_log
        
        # Aktualisiere die Nachricht mit Zähler
        count_suffix = " (#{@@repeat_count + 1}x)"
        updated_message = message + count_suffix
        
        last_log.update!(
          message: updated_message,
          updated_at: Time.current.in_time_zone('Europe/Berlin')
        )
        
        # Aktualisiere auch Rails-Log
        Rails.logger.send(level, "[MailHandler] #{updated_message}")
      end
      
    rescue ActiveRecord::ConnectionTimeoutError => e
      # Keine weitere Aktion bei Connection Timeout
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      # DB nicht verfügbar
    rescue => e
      Rails.logger.error "Failed to update log with count: #{e.message}"
    end
  end

  def ensure_log_table_exists
    begin
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        unless connection.table_exists?('mail_handler_logs')
          Rails.logger.warn "Mail handler logs table does not exist. Please run migrations."
        end
      end
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn "Database connection not available for mail handler logs: #{e.message}"
    rescue => e
      Rails.logger.error "Error checking mail handler logs table: #{e.message}"
    end
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
  end
  
  # Finalisiere die aktuelle Import-Session
  def finalize_import_session
    return if @@import_session_logs.empty?
    
    begin
      ActiveRecord::Base.connection_pool.with_connection do
        # Erstelle zusammengefasste Log-Nachricht
        duration = Time.current - @@import_session_start if @@import_session_start
        
        # Extrahiere wichtige Informationen
        found_messages = extract_number_from_logs(/Found (\\d+) unread messages/i)
        processed_messages = extract_number_from_logs(/Processed (\\d+) messages successfully/i)
        
        summary_message = "Mail Import Session abgeschlossen"
        summary_message += " - #{found_messages} Nachrichten gefunden" if found_messages
        summary_message += ", #{processed_messages} erfolgreich verarbeitet" if processed_messages
        summary_message += " (Dauer: #{duration.round(2)}s)" if duration
        
        # Erstelle einen einzigen Log-Eintrag für die gesamte Session
        MailHandlerLog.create!(
          level: 'info',
          message: summary_message,
          created_at: @@import_session_start || Time.current.in_time_zone('Europe/Berlin')
        )
      end
      
    rescue => e
      Rails.logger.error "Failed to finalize import session: #{e.message}"
      # Fallback: Schreibe alle Logs einzeln
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
    begin
      ActiveRecord::Base.connection_pool.with_connection do
        MailHandlerLog.create!(
          level: level,
          message: message,
          created_at: timestamp.in_time_zone('Europe/Berlin')
        )
      end
    rescue ActiveRecord::ConnectionTimeoutError => e
      # Keine weitere Aktion bei Connection Timeout
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      # DB nicht verfügbar
    rescue => e
      Rails.logger.error "Failed to write single log entry: #{e.message}"
    end
  end
end
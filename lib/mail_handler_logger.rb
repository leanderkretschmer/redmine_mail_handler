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

  private

  def log(level, message)
    return unless should_log?(level)
    
    @@mutex.synchronize do
      # Prüfe auf wiederholte Nachrichten
      if @@last_message == message
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
      
      # Versuche in DB zu schreiben, aber nur wenn Verbindung verfügbar
      begin
        return unless ActiveRecord::Base.connection_pool.connected?
        
        log_entry = MailHandlerLog.create!(
          level: level,
          message: message,
          created_at: Time.current.in_time_zone('Europe/Berlin')
        )
        
        @@last_log_id = log_entry.id
        
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
      return unless ActiveRecord::Base.connection_pool.connected?
      
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
      # Überprüfe ob eine DB-Verbindung verfügbar ist
      return unless ActiveRecord::Base.connection_pool.connected?
      
      unless ActiveRecord::Base.connection.table_exists?('mail_handler_logs')
        Rails.logger.warn "Mail handler logs table does not exist. Please run migrations."
      end
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      Rails.logger.warn "Database connection not available for mail handler logs: #{e.message}"
    rescue => e
      Rails.logger.error "Error checking mail handler logs table: #{e.message}"
    end
  end
end
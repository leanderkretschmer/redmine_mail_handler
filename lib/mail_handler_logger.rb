class MailHandlerLogger
  LOG_LEVELS = {
    'debug' => 0,
    'info' => 1,
    'warn' => 2,
    'error' => 3
  }.freeze

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
    
    # Immer in Rails-Log schreiben
    Rails.logger.send(level, "[MailHandler] #{message}")
    
    # Versuche in DB zu schreiben, aber nur wenn Verbindung verfügbar
    begin
      return unless ActiveRecord::Base.connection_pool.connected?
      
      MailHandlerLog.create!(
        level: level,
        message: message,
        created_at: Time.current.in_time_zone('Europe/Berlin')
      )
    rescue ActiveRecord::ConnectionTimeoutError => e
      # Keine weitere Aktion bei Connection Timeout - Rails.logger wurde bereits verwendet
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::NoDatabaseError => e
      # DB nicht verfügbar - nur Rails.logger verwenden
    rescue => e
      Rails.logger.error "Failed to write mail handler log: #{e.message}"
    end
  end

  def should_log?(level)
    current_level = LOG_LEVELS[@settings['log_level'] || 'info']
    message_level = LOG_LEVELS[level]
    
    message_level >= current_level
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
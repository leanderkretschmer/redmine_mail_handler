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
    
    begin
      MailHandlerLog.create!(
        level: level,
        message: message,
        created_at: Time.current.in_time_zone('Europe/Berlin')
      )
    rescue => e
      Rails.logger.error "Failed to write mail handler log: #{e.message}"
    end
    
    # Auch in Rails-Log schreiben
    Rails.logger.send(level, "[MailHandler] #{message}")
  end

  def should_log?(level)
    current_level = LOG_LEVELS[@settings['log_level'] || 'info']
    message_level = LOG_LEVELS[level]
    
    message_level >= current_level
  end

  def ensure_log_table_exists
    unless ActiveRecord::Base.connection.table_exists?('mail_handler_logs')
      Rails.logger.warn "Mail handler logs table does not exist. Please run migrations."
    end
  end
end
class MailHandlerLog < ActiveRecord::Base
  validates :level, presence: true, inclusion: { in: %w[debug info warn error] }
  validates :message, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_level, ->(level) { where(level: level) if level.present? }
  scope :today, -> { where('created_at >= ?', Date.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Date.current.beginning_of_week) }
  scope :with_mail_details, -> { where.not(mail_subject: nil) }
  scope :by_ticket, ->(ticket_id) { where(ticket_id: ticket_id) if ticket_id.present? }

  def self.levels
    %w[debug info warn error]
  end

  def level_color
    case level
    when 'debug'
      'gray'
    when 'info'
      'blue'
    when 'warn'
      'orange'
    when 'error'
      'red'
    else
      'black'
    end
  end

  def level_icon
    case level
    when 'debug'
      'icon-info'
    when 'info'
      'icon-ok'
    when 'warn'
      'icon-warning'
    when 'error'
      'icon-error'
    else
      'icon-info'
    end
  end

  def formatted_time
    created_at.strftime('%d.%m.%Y %H:%M:%S')
  end

  def has_mail_details?
    mail_subject.present? || mail_from.present?
  end

  def mail_details_summary
    return nil unless has_mail_details?
    
    details = []
    details << "Von: #{mail_from}" if mail_from.present?
    details << "Betreff: #{mail_subject}" if mail_subject.present?
    details << "Ticket: ##{ticket_id}" if ticket_id.present?
    
    details.join(' | ')
  end

  def truncated_subject(length = 50)
    return nil unless mail_subject.present?
    mail_subject.length > length ? "#{mail_subject[0..length-3]}..." : mail_subject
  end

  # Automatische Log-Bereinigung
  def self.cleanup_logs
    settings = Setting.plugin_redmine_mail_handler || {}
    return unless settings['log_cleanup_enabled'] == '1'

    method = settings['log_cleanup_method'] || 'count'
    
    case method
    when 'count'
      cleanup_by_count(settings)
    when 'days'
      cleanup_by_age(settings)
    end
  end

  def self.cleanup_by_count(settings)
    max_entries = (settings['log_max_entries'] || '1000').to_i
    return if max_entries <= 0

    total_count = count
    return if total_count <= max_entries

    # Lösche die ältesten Einträge
    entries_to_delete = total_count - max_entries
    oldest_entries = order(:created_at).limit(entries_to_delete)
    
    deleted_count = oldest_entries.delete_all
    Rails.logger.info "Mail Handler Log Cleanup: #{deleted_count} alte Einträge gelöscht (Methode: Anzahl, behalten: #{max_entries})"
    
    deleted_count
  end

  def self.cleanup_by_age(settings)
    retention_days = (settings['log_retention_days'] || '30').to_i
    return if retention_days <= 0

    cutoff_date = retention_days.days.ago
    old_entries = where('created_at < ?', cutoff_date)
    
    deleted_count = old_entries.delete_all
    Rails.logger.info "Mail Handler Log Cleanup: #{deleted_count} alte Einträge gelöscht (Methode: Alter, älter als #{retention_days} Tage)"
    
    deleted_count
  end

  def self.should_run_cleanup?
    settings = Setting.plugin_redmine_mail_handler || {}
    return false unless settings['log_cleanup_enabled'] == '1'

    schedule = settings['log_cleanup_schedule'] || 'weekly'
    last_cleanup = settings['last_log_cleanup']
    
    return true if last_cleanup.blank?
    
    last_cleanup_time = Time.parse(last_cleanup) rescue nil
    return true if last_cleanup_time.nil?
    
    case schedule
    when 'daily'
      last_cleanup_time < 1.day.ago
    when 'weekly'
      last_cleanup_time < 1.week.ago
    when 'monthly'
      last_cleanup_time < 1.month.ago
    else
      false
    end
  end

  def self.run_scheduled_cleanup
    return unless should_run_cleanup?
    
    deleted_count = cleanup_logs
    
    # Aktualisiere den Zeitstempel der letzten Bereinigung
    settings = Setting.plugin_redmine_mail_handler || {}
    settings['last_log_cleanup'] = Time.current.to_s
    Setting.plugin_redmine_mail_handler = settings
    
    deleted_count
  end
end
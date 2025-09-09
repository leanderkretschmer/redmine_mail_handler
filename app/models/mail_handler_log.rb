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
end
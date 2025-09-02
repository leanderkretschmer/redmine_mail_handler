class MailHandlerLog < ActiveRecord::Base
  validates :level, presence: true, inclusion: { in: %w[debug info warn error] }
  validates :message, presence: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_level, ->(level) { where(level: level) if level.present? }
  scope :today, -> { where('created_at >= ?', Date.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Date.current.beginning_of_week) }

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
end
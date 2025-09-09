class MailQuarantineEntry < ActiveRecord::Base
  validates :message_id, presence: true, uniqueness: true
  validates :from_address, presence: true
  validates :quarantined_at, presence: true
  validates :expires_at, presence: true
  
  scope :expired, -> { where('expires_at < ?', Time.current) }
  scope :active, -> { where('expires_at >= ?', Time.current) }
  
  def expired?
    expires_at < Time.current
  end
  
  def days_until_expiry
    return 0 if expired?
    ((expires_at - Time.current) / 1.day).ceil
  end
end
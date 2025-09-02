# Load the Redmine helper
require File.expand_path(File.dirname(__FILE__) + '/../../../test/test_helper')

# Add plugin-specific test helpers here
class ActiveSupport::TestCase
  # Plugin-specific fixtures
  self.fixture_path = File.join(File.dirname(__FILE__), 'fixtures')
  
  # Helper methods for mail handler tests
  def create_test_mail(from: 'test@example.com', subject: 'Test Subject', body: 'Test Body')
    Mail.new do
      from from
      to 'redmine@example.com'
      subject subject
      body body
    end
  end
  
  def create_test_mail_with_ticket_id(ticket_id, from: 'test@example.com')
    create_test_mail(
      from: from,
      subject: "Re: Test Issue [##{ticket_id}]",
      body: 'This is a reply to the ticket'
    )
  end
  
  def setup_mail_handler_settings(overrides = {})
    default_settings = {
      'imap_host' => 'test.example.com',
      'imap_port' => '993',
      'imap_ssl' => '1',
      'imap_username' => 'test@example.com',
      'imap_password' => 'password',
      'inbox_folder' => 'INBOX',
      'archive_folder' => 'Archive',
      'inbox_ticket_id' => '1',
      'reminder_time' => '09:00',
      'reminder_enabled' => '1',
      'auto_import_enabled' => '1',
      'import_interval' => '5',
      'log_level' => 'debug'
    }
    
    Setting.plugin_redmine_mail_handler = default_settings.merge(overrides)
  end
  
  def clear_mail_handler_logs
    MailHandlerLog.delete_all if defined?(MailHandlerLog)
  end
end

# Mock IMAP for tests
class MockIMAP
  def initialize(host, options = {})
    @host = host
    @options = options
  end
  
  def login(username, password)
    true
  end
  
  def select(folder)
    true
  end
  
  def search(criteria)
    [1, 2, 3] # Mock message IDs
  end
  
  def fetch(msg_id, attr)
    mock_mail_data = "From: test@example.com\r\nTo: redmine@example.com\r\nSubject: Test [#1]\r\n\r\nTest message"
    [OpenStruct.new(attr: { 'RFC822' => mock_mail_data })]
  end
  
  def store(msg_id, action, flags)
    true
  end
  
  def move(msg_id, folder)
    true
  end
  
  def disconnect
    true
  end
  
  def list(reference, mailbox)
    [OpenStruct.new(name: 'INBOX'), OpenStruct.new(name: 'Archive')]
  end
end
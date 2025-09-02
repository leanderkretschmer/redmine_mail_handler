require File.expand_path('../../test_helper', __FILE__)

class MailHandlerServiceTest < ActiveSupport::TestCase
  fixtures :users, :projects, :issues, :issue_statuses

  def setup
    @service = MailHandlerService.new
    @settings = {
      'imap_host' => 'test.example.com',
      'imap_port' => '993',
      'imap_ssl' => '1',
      'imap_username' => 'test@example.com',
      'imap_password' => 'password',
      'inbox_folder' => 'INBOX',
      'archive_folder' => 'Archive',
      'inbox_ticket_id' => '1',
      'log_level' => 'debug'
    }
    Setting.plugin_redmine_mail_handler = @settings
  end

  def test_extract_ticket_id_with_valid_format
    subject = "Re: Test Issue [#123]"
    ticket_id = @service.send(:extract_ticket_id, subject)
    assert_equal 123, ticket_id
  end

  def test_extract_ticket_id_with_invalid_format
    subject = "Test Issue without ticket ID"
    ticket_id = @service.send(:extract_ticket_id, subject)
    assert_nil ticket_id
  end

  def test_extract_ticket_id_with_multiple_ids
    subject = "Re: Test [#123] and [#456]"
    ticket_id = @service.send(:extract_ticket_id, subject)
    assert_equal 123, ticket_id # Should return first match
  end

  def test_find_existing_user
    user = User.find(1)
    found_user = @service.send(:find_or_create_user, user.mail)
    assert_equal user, found_user
  end

  def test_create_new_user
    email = 'newuser@example.com'
    
    # Mock user creation
    User.any_instance.stubs(:save).returns(true)
    
    user = @service.send(:find_or_create_user, email)
    assert_not_nil user
    assert_equal email.downcase, user.mail
    assert_equal User::STATUS_LOCKED, user.status
    assert_equal 'none', user.mail_notification
  end

  def test_decode_simple_mail_content
    # Create a simple mail object
    mail = Mail.new do
      from 'test@example.com'
      to 'redmine@example.com'
      subject 'Test Subject'
      body 'Test message body'
    end

    content = @service.send(:decode_mail_content, mail)
    assert_includes content, 'Test Subject'
    assert_includes content, 'Test message body'
  end

  def test_decode_multipart_mail_content
    mail = Mail.new do
      from 'test@example.com'
      to 'redmine@example.com'
      subject 'Test Subject'
      
      text_part do
        body 'Text part content'
      end
      
      html_part do
        content_type 'text/html; charset=UTF-8'
        body '<p>HTML part content</p>'
      end
    end

    content = @service.send(:decode_mail_content, mail)
    assert_includes content, 'Test Subject'
    assert_includes content, 'Text part content'
  end

  def test_send_test_mail
    # Mock Mail delivery
    Mail.any_instance.stubs(:deliver!).returns(true)
    
    result = @service.send_test_mail('test@example.com')
    assert result
  end

  def test_send_test_mail_failure
    # Mock Mail delivery failure
    Mail.any_instance.stubs(:deliver!).raises(StandardError.new('SMTP Error'))
    
    result = @service.send_test_mail('test@example.com')
    assert_not result
  end
end
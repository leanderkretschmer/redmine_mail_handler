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
  
  def test_get_user_firstname_mail_account
    @service.instance_variable_set(:@settings, {'user_firstname_type' => 'mail_account'})
    assert_equal 'testuser', @service.get_user_firstname('testuser@example.com')
  end
  
  def test_get_user_firstname_mail_address
    @service.instance_variable_set(:@settings, {'user_firstname_type' => 'mail_address'})
    assert_equal 'testuser@example.com', @service.get_user_firstname('testuser@example.com')
  end
  
  def test_get_user_lastname_custom
    @service.instance_variable_set(:@settings, {'user_lastname_custom' => 'Custom Name'})
    assert_equal 'Custom Name', @service.get_user_lastname
  end
  
  def test_get_user_lastname_default
    @service.instance_variable_set(:@settings, {})
    assert_equal 'Auto-generated', @service.get_user_lastname
  end
  
  def test_should_ignore_email_exact_match
    @service.instance_variable_set(:@settings, {'ignore_email_addresses' => 'noreply@example.com\nsystem@test.com'})
    assert @service.should_ignore_email?('noreply@example.com')
    assert @service.should_ignore_email?('system@test.com')
    assert_not @service.should_ignore_email?('user@example.com')
  end
  
  def test_should_ignore_email_wildcard_match
    @service.instance_variable_set(:@settings, {'ignore_email_addresses' => '*@system.example.com\nautomation@*'})
    assert @service.should_ignore_email?('noreply@system.example.com')
    assert @service.should_ignore_email?('test@system.example.com')
    assert @service.should_ignore_email?('automation@company.com')
    assert @service.should_ignore_email?('automation@test.org')
    assert_not @service.should_ignore_email?('user@example.com')
  end
  
  def test_should_ignore_email_case_insensitive
    @service.instance_variable_set(:@settings, {'ignore_email_addresses' => 'NoReply@Example.Com'})
    assert @service.should_ignore_email?('noreply@example.com')
    assert @service.should_ignore_email?('NOREPLY@EXAMPLE.COM')
  end
  
  def test_should_ignore_email_empty_settings
    @service.instance_variable_set(:@settings, {'ignore_email_addresses' => ''})
    assert_not @service.should_ignore_email?('test@example.com')
  end
  
  def test_should_ignore_email_blank_settings
    @service.instance_variable_set(:@settings, {})
    assert_not @service.should_ignore_email?('test@example.com')
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

  def test_extract_ticket_id_with_text_prefix_format
    subject = "[PFP10368 mobilehomes adria germany - LP2 - Vorplanung #51264] Bayern"
    ticket_id = @service.send(:extract_ticket_id, subject)
    assert_equal 51264, ticket_id
  end

  def test_extract_ticket_id_with_simple_text_prefix
    subject = "Re: [Project ABC #789] Issue description"
    ticket_id = @service.send(:extract_ticket_id, subject)
    assert_equal 789, ticket_id
  end

  def test_extract_ticket_id_mixed_formats
    # Test dass beide Formate funktionieren
    classic_subject = "Re: Test Issue [#123]"
    new_subject = "[Text before #456] After text"
    
    classic_id = @service.send(:extract_ticket_id, classic_subject)
    new_id = @service.send(:extract_ticket_id, new_subject)
    
    assert_equal 123, classic_id
    assert_equal 456, new_id
  end

  def test_find_existing_user
    user = User.find(1)
    found_user = @service.send(:find_or_create_user, user.email_address)
    assert_equal user, found_user
  end

  def test_create_new_user
    email = 'newuser@example.com'
    
    # Mock user creation
    User.any_instance.stubs(:save).returns(true)
    
    user = @service.send(:find_or_create_user, email)
    assert_not_nil user
    assert_equal email.downcase, user.email_address
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

  def test_convert_html_to_text_simple
    html = '<p>Hallo <strong>Welt</strong>!</p>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, 'Hallo **Welt**!'
  end

  def test_convert_html_to_text_with_lists
    html = '<ul><li>Punkt 1</li><li>Punkt 2</li></ul>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, '• Punkt 1'
    assert_includes result, '• Punkt 2'
  end

  def test_convert_html_to_text_with_links
    html = '<p>Besuchen Sie <a href="https://example.com">unsere Website</a></p>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, 'unsere Website (https://example.com)'
  end

  def test_convert_html_to_text_with_headings
    html = '<h1>Haupttitel</h1><h2>Untertitel</h2><h3>Abschnitt</h3>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, '=== Haupttitel ==='
    assert_includes result, '## Untertitel ##'
    assert_includes result, '# Abschnitt #'
  end

  def test_convert_html_to_text_with_table
    html = '<table><tr><th>Name</th><th>Alter</th></tr><tr><td>Max</td><td>25</td></tr></table>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, '| Name | Alter |'
    assert_includes result, '| --- | --- |'
    assert_includes result, '| Max | 25 |'
  end

  def test_convert_html_to_text_with_css_styles
    html = '<div style="color: red; font-weight: bold;">Wichtiger Text</div><p style="margin: 10px;">Normal</p>'
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, 'Wichtiger Text'
    assert_includes result, 'Normal'
  end

  def test_html_only_multipart_mail
    mail = Mail.new do
      from 'test@example.com'
      to 'redmine@example.com'
      subject 'HTML Only Mail'
      
      html_part do
        content_type 'text/html; charset=UTF-8'
        body '<h1>Titel</h1><p>Das ist <strong>wichtig</strong>!</p><ul><li>Punkt A</li><li>Punkt B</li></ul>'
      end
    end

    content = @service.send(:decode_mail_content, mail)
    assert_includes content, 'HTML Only Mail'
    assert_includes content, '=== Titel ==='
    assert_includes content, '**wichtig**'
    assert_includes content, '• Punkt A'
    assert_includes content, '• Punkt B'
  end

  def test_complex_html_email_conversion
    html = <<~HTML
      <html>
        <head><style>body { font-family: Arial; }</style></head>
        <body>
          <h2>Newsletter</h2>
          <p>Liebe Kunden,</p>
          <blockquote>Das ist ein wichtiges Zitat.</blockquote>
          <ol>
            <li>Erster Punkt</li>
            <li>Zweiter Punkt</li>
          </ol>
          <p>Besuchen Sie <a href="https://example.com">unsere Website</a>.</p>
          <hr>
          <p><em>Mit freundlichen Grüßen</em></p>
        </body>
      </html>
    HTML
    
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, '## Newsletter ##'
    assert_includes result, 'Liebe Kunden'
    assert_includes result, '> Das ist ein wichtiges Zitat'
    assert_includes result, '1. Erster Punkt'
    assert_includes result, '2. Zweiter Punkt'
    assert_includes result, 'unsere Website (https://example.com)'
    assert_includes result, '---'
    assert_includes result, '*Mit freundlichen Grüßen*'
  end

  def test_html_structure_filter
    @service.instance_variable_set(:@settings, {'html_structure_filter_enabled' => '1'})
    
    html = <<~HTML
      <p>Wichtiger Inhalt</p>
      <blockquote>Das ist ein Zitat</blockquote>
      <div class="gmail_quote">Gmail Zitat</div>
      <div class="apple-msg-attachment">Apple Anhang</div>
      <p>Mehr wichtiger Inhalt</p>
    HTML
    
    result = @service.send(:convert_html_to_text, html)
    assert_includes result, 'Wichtiger Inhalt'
    assert_includes result, 'Mehr wichtiger Inhalt'
    refute_includes result, 'Das ist ein Zitat'
    refute_includes result, 'Gmail Zitat'
    refute_includes result, 'Apple Anhang'
  end

  def test_regex_filter
    @service.instance_variable_set(:@settings, {
      'regex_filter_enabled' => '1',
      'regex_separators' => "Am .* schrieb .*:\n-----Original Message-----"
    })
    
    text = <<~TEXT
      Das ist der wichtige Inhalt.
      Hier steht noch mehr.
      
      Am 15.01.2024 schrieb test@example.com:
      > Das ist die ursprüngliche Nachricht
      > die entfernt werden soll.
    TEXT
    
    result = @service.send(:apply_regex_filter, text)
    assert_includes result, 'Das ist der wichtige Inhalt'
    assert_includes result, 'Hier steht noch mehr'
    refute_includes result, 'Am 15.01.2024 schrieb'
    refute_includes result, 'ursprüngliche Nachricht'
  end

  def test_regex_filter_with_original_message
    @service.instance_variable_set(:@settings, {
      'regex_filter_enabled' => '1',
      'regex_separators' => "-----Original Message-----"
    })
    
    text = <<~TEXT
      Neue Antwort hier.
      
      -----Original Message-----
      From: sender@example.com
      To: recipient@example.com
      Subject: Test
      
      Ursprüngliche Nachricht Inhalt
    TEXT
    
    result = @service.send(:apply_regex_filter, text)
    assert_includes result, 'Neue Antwort hier'
    refute_includes result, 'Original Message'
    refute_includes result, 'sender@example.com'
  end

  def test_filters_disabled
    @service.instance_variable_set(:@settings, {
      'html_structure_filter_enabled' => '0',
      'regex_filter_enabled' => '0'
    })
    
    html = '<p>Inhalt</p><blockquote>Zitat</blockquote>'
    text = "Inhalt\n\nAm 15.01.2024 schrieb test@example.com:\nZitat"
    
    html_result = @service.send(:convert_html_to_text, html)
    text_result = @service.send(:apply_regex_filter, text)
    
    # Filter sind deaktiviert, also sollten Zitate erhalten bleiben
     assert_includes html_result, 'Zitat'
     assert_includes text_result, 'Am 15.01.2024 schrieb'
   end

   def test_decode_mail_content_with_line_breaks
    # Test verschiedene Zeilenumbruch-Formate
    mail = Mail.new do
      from 'test@example.com'
      to 'redmine@example.com'
      subject 'Test Line Breaks'
      body "Zeile 1\r\nZeile 2\nZeile 3\r\n\r\nAbsatz 2\n\n\n\nZu viele Leerzeilen\n=\nSoft line break"
    end

    content = @service.send(:decode_mail_content, mail)
    
    # Prüfe dass Zeilenumbrüche normalisiert wurden
    assert_includes content, "Zeile 1\nZeile 2\nZeile 3"
    assert_includes content, "Absatz 2\n\nZu viele Leerzeilen"
    assert_includes content, "Soft line break"
    
    # Prüfe dass nicht mehr als 2 aufeinanderfolgende Leerzeilen vorhanden sind
    assert_not_includes content, "\n\n\n"
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

  def test_process_mail_attachments
    # Erstelle Test-Issue
    issue = Issue.create!(
      project: Project.first,
      tracker: Tracker.first,
      author: User.first,
      subject: 'Test Issue for Attachments'
    )
    
    # Erstelle Test-Mail mit Anhang
    mail = Mail.new do
      from 'test@example.com'
      to 'redmine@example.com'
      subject 'Test with Attachment'
      body 'Test message with attachment'
      
      add_file filename: 'test.txt', content: 'Test file content'
    end
    
    user = User.first
    initial_attachment_count = issue.attachments.count
    
    # Verarbeite Anhänge
    @service.send(:process_mail_attachments, mail, issue, user)
    
    # Prüfe ob Anhang hinzugefügt wurde
    issue.reload
    assert_equal initial_attachment_count + 1, issue.attachments.count
    
    attachment = issue.attachments.last
    assert_equal 'test.txt', attachment.filename
    assert_equal user, attachment.author
  end

  def test_whitespace_filter
    @service.instance_variable_set(:@settings, {'remove_leading_whitespace_enabled' => '1'})
    
    text = <<~TEXT
      Normale Zeile
        Zeile mit führenden Leerzeichen
      \t\tZeile mit Tabs
      \t   Zeile mit gemischten Whitespaces
      Noch eine normale Zeile
    TEXT
    
    result = @service.send(:apply_whitespace_filter, text)
    lines = result.split("\n")
    
    assert_equal 'Normale Zeile', lines[0]
    assert_equal 'Zeile mit führenden Leerzeichen', lines[1]
    assert_equal 'Zeile mit Tabs', lines[2]
    assert_equal 'Zeile mit gemischten Whitespaces', lines[3]
    assert_equal 'Noch eine normale Zeile', lines[4]
  end

  def test_paragraph_normalization_filter
    @service.instance_variable_set(:@settings, {
      'normalize_paragraphs_enabled' => '1',
      'max_consecutive_paragraphs' => '2'
    })
    
    text = <<~TEXT
      Erster Absatz
      
      
      
      
      
      Zweiter Absatz nach vielen Leerzeilen
      
      
      Dritter Absatz
    TEXT
    
    result = @service.send(:apply_paragraph_normalization_filter, text)
    
    # Sollte maximal 2 aufeinanderfolgende Newlines haben
    assert_not_includes result, "\n\n\n"
    assert_includes result, 'Erster Absatz'
    assert_includes result, 'Zweiter Absatz nach vielen Leerzeilen'
    assert_includes result, 'Dritter Absatz'
  end

  def test_whitespace_filter_disabled
    @service.instance_variable_set(:@settings, {'remove_leading_whitespace_enabled' => '0'})
    
    text = "    Zeile mit führenden Leerzeichen"
    result = @service.send(:apply_whitespace_filter, text)
    
    # Filter ist deaktiviert, Text sollte unverändert bleiben
    assert_equal text, result
  end

  def test_paragraph_normalization_filter_disabled
    @service.instance_variable_set(:@settings, {'normalize_paragraphs_enabled' => '0'})
    
    text = "Absatz 1\n\n\n\n\nAbsatz 2"
    result = @service.send(:apply_paragraph_normalization_filter, text)
    
    # Filter ist deaktiviert, Text sollte unverändert bleiben
    assert_equal text, result
  end

  def test_should_exclude_attachment_enabled
    @service.instance_variable_set(:@settings, {
      'exclude_attachments_enabled' => '1',
      'excluded_attachment_patterns' => "*.tmp\n*.log\nwinmail.dat\nimage*.png"
    })
    
    # Diese Dateien sollten ausgeschlossen werden
    assert @service.send(:should_exclude_attachment?, 'test.tmp')
    assert @service.send(:should_exclude_attachment?, 'debug.log')
    assert @service.send(:should_exclude_attachment?, 'winmail.dat')
    assert @service.send(:should_exclude_attachment?, 'image001.png')
    assert @service.send(:should_exclude_attachment?, 'image123.png')
    
    # Diese Dateien sollten NICHT ausgeschlossen werden
    assert_not @service.send(:should_exclude_attachment?, 'document.pdf')
    assert_not @service.send(:should_exclude_attachment?, 'test.txt')
    assert_not @service.send(:should_exclude_attachment?, 'photo.jpg')
  end

  def test_should_exclude_attachment_disabled
    @service.instance_variable_set(:@settings, {
      'exclude_attachments_enabled' => '0',
      'excluded_attachment_patterns' => "*.tmp\n*.log"
    })
    
    # Auch wenn Muster definiert sind, sollten keine Dateien ausgeschlossen werden
    assert_not @service.send(:should_exclude_attachment?, 'test.tmp')
    assert_not @service.send(:should_exclude_attachment?, 'debug.log')
  end

  def test_should_exclude_attachment_case_insensitive
    @service.instance_variable_set(:@settings, {
      'exclude_attachments_enabled' => '1',
      'excluded_attachment_patterns' => "*.TMP\nWINMAIL.DAT"
    })
    
    # Case-insensitive Matching
    assert @service.send(:should_exclude_attachment?, 'test.tmp')
    assert @service.send(:should_exclude_attachment?, 'TEST.TMP')
    assert @service.send(:should_exclude_attachment?, 'winmail.dat')
    assert @service.send(:should_exclude_attachment?, 'WINMAIL.DAT')
  end

  def test_should_exclude_attachment_invalid_pattern
    @service.instance_variable_set(:@settings, {
      'exclude_attachments_enabled' => '1',
      'excluded_attachment_patterns' => "[invalid\nvalid.txt"
    })
    
    # Ungültiges Regex-Pattern sollte ignoriert werden
    assert_not @service.send(:should_exclude_attachment?, '[invalid')
    
    # Gültiges Pattern sollte funktionieren
    assert @service.send(:should_exclude_attachment?, 'valid.txt')
  end

  def test_apply_markdown_link_filter_basic
    text = 'Hier ist ein [Link](https://example.com) im Text.'
    expected = 'Hier ist ein "Link":https://example.com im Text.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_multiple_links
    text = 'Erste [Link](https://example.com) und zweite [Seite](http://test.org) Links.'
    expected = 'Erste "Link":https://example.com und zweite "Seite":http://test.org Links.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_no_links
    text = 'Normaler Text ohne Links.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal text, result
  end

  def test_apply_markdown_link_filter_empty_text
    assert_equal '', @service.send(:apply_markdown_link_filter, '')
    assert_nil @service.send(:apply_markdown_link_filter, nil)
  end

  def test_apply_markdown_link_filter_complex_alt_text
    text = 'Link mit [komplexem Alt-Text mit Leerzeichen](https://example.com/path?param=value) hier.'
    expected = 'Link mit "komplexem Alt-Text mit Leerzeichen":https://example.com/path?param=value hier.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_quoted_format
    text = 'Mit "Maßtoleranzen und Normen im Hochbau" ( `https://example.com/link` ) haben Sie alles.'
    expected = 'Mit "Maßtoleranzen und Normen im Hochbau":https://example.com/link haben Sie alles.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_mixed_formats
    text = 'Erste [Link](https://example.com) und "Zweiter Link" ( `http://test.org` ) hier.'
    expected = 'Erste "Link":https://example.com und "Zweiter Link":http://test.org hier.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_multiple_quoted_links
    text = 'Text "Link1" ( `https://example.com` ) und "Link2" ( `http://test.org` ) Ende.'
    expected = 'Text "Link1":https://example.com und "Link2":http://test.org Ende.'
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end

  def test_apply_markdown_link_filter_multiline_backtick
    text = "Online-Zugriff auf Toleranztabellen: ( \n `https://mail.weka.de/test` \n ) ."
    expected = "Online-Zugriff auf Toleranztabellen: https://mail.weka.de/test ."
    result = @service.send(:apply_markdown_link_filter, text)
    assert_equal expected, result
  end
end
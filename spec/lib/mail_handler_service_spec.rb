require 'rspec'
require 'active_support'
require 'active_support/core_ext'

# Stub-Umgebung, damit das Laden der Service-Klasse ohne Redmine möglich ist
module Redmine; module I18n; end; end

class Setting
  def self.plugin_redmine_mail_handler
    {} # minimale Settings
  end

  def self.mail_from
    'redmine@firma.de'
  end
end

class MailHandlerLogger
  def self.reset_logger_state; end
  def info(*) end
  def debug(*) end
  def debug_mail(*) end
  def warn(*) end
  def error(msg = nil, *) $stderr.puts("[error] #{msg}") if ENV['SPEC_DEBUG']; end
  def info_mail(*) end
  def error_mail(*) end
end

class Issue
  def self.find_by(*); end
end

class User
  def self.find_by_login(*); end
  def self.new(*); end
end

class EmailAddress
  def self.find_by(*); end
  def self.create!(*); end
end

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'mail_handler_service'

RSpec.describe MailHandlerService do
  let(:service) { described_class.new }

  # Einfache Attachment-Attrappen
  AttachmentStub = Struct.new(:filename, :content_type, :content_id, :header) do
    def body; OpenStruct.new(decoded: ''); end
  end
  MailStub = Struct.new(:attachments)

  describe '#apply_image_reference_filter' do
    it 'ersetzt U+FFFC Platzhalter sequenziell durch !filename!' do
      allow(Setting).to receive(:text_formatting).and_return('textile')
      img1 = AttachmentStub.new('bild1.png', 'image/png', nil, nil)
      img2 = AttachmentStub.new('foto2.jpg', 'image/jpeg', nil, nil)
      mail = MailStub.new([img1, img2])
      content = "Text \uFFFC und \uFFFC Ende"
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result.gsub(/\s+/, ' ')).to include('Text !bild1.png! und !foto2.jpg! Ende')
    end

    it 'ersetzt cid:CONTENTID durch !filename!' do
      allow(Setting).to receive(:text_formatting).and_return('textile')
      img = AttachmentStub.new('logo.gif', 'image/gif', '<abc123>', { 'content-id' => '<abc123>' })
      mail = MailStub.new([img])
      content = "Bitte siehe cid:abc123 hier."
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to include('Bitte siehe !logo.gif! hier.')
    end

    it 'hängt Bildreferenzen an, wenn keine Platzhalter gefunden werden' do
      allow(Setting).to receive(:text_formatting).and_return('textile')
      img = AttachmentStub.new('diagramm final.svg', 'image/svg+xml', nil, nil)
      mail = MailStub.new([img])
      content = "Beschreibung ohne Bilder"
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to match(/Beschreibung ohne Bilder\s+!diagramm%20final.svg!/m)
    end

    it 'ignoriert blockierte Bild-Anhänge' do
      allow(Setting).to receive(:text_formatting).and_return('textile')
      ok = AttachmentStub.new('ok.png', 'image/png', nil, nil)
      blocked = AttachmentStub.new('blocked.jpg', 'image/jpeg', nil, nil)
      mail = MailStub.new([ok, blocked])
      content = "C"
      result = service.send(:apply_image_reference_filter, content, mail, ['blocked.jpg'])
      expect(result).to match(/C\s+!ok.png!/m)
      expect(result).not_to include('blocked.jpg')
    end

    it 'nutzt Markdown-Syntax bei markdown-Formatierung' do
      allow(Setting).to receive(:text_formatting).and_return('markdown')
      img = AttachmentStub.new('Screenshot 1 (final).jpeg', 'image/jpeg', nil, nil)
      mail = MailStub.new([img])
      content = "Bild: \uFFFC"
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to include('![](attachment:Screenshot%201%20\(final\).jpeg)')
    end

    it 'wandelt vorhandene !filename! in Markdown um' do
      allow(Setting).to receive(:text_formatting).and_return('markdown')
      img = AttachmentStub.new('foto.png', 'image/png', nil, nil)
      mail = MailStub.new([img])
      content = "Hier !foto.png! inline."
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to include('![](attachment:foto.png)')
      expect(result).not_to include('!foto.png!')
    end
  end

  describe '#add_mail_to_ticket' do
    it 'initialisiert Journal vor Attachments, damit Details verknüpft werden' do
      # Mocks
      ticket = double('Issue', id: 1)
      allow(Issue).to receive(:find_by).with(id: 1).and_return(ticket)
      
      user = double('User', id: 1)
      mail = double('Mail', subject: 'Test', from: ['test@example.com'])
      
      # Mock process_mail_attachments
      # Wir erwarten, dass dies NACH init_journal aufgerufen wird
      allow(service).to receive(:process_mail_attachments).and_return({
        blocked: [],
        added: ['test.pdf', 'image.png']
      })
      
      # Mock decode_mail_content und apply_image_reference_filter
      allow(service).to receive(:decode_mail_content).and_return("Original Text")
      allow(service).to receive(:apply_image_reference_filter).and_return("Original Text")
      
      # Mock Journal
      journal = double('Journal')
      # Erwarte init_journal Aufruf zuerst
      expect(ticket).to receive(:init_journal).with(user, "Original Text").ordered.and_return(journal)
      # Erwarte process_mail_attachments danach
      expect(service).to receive(:process_mail_attachments).ordered
      
      allow(journal).to receive(:created_on=)
      allow(journal).to receive(:save).and_return(true)
      allow(ticket).to receive(:save).and_return(true)
      
      # Erwarte, dass Notes aktualisiert werden
      expect(journal).to receive(:notes=).with("Original Text")
      
      # Execute
      service.send(:add_mail_to_ticket, mail, 1, user)
    end
  end

  describe 'Alias-Mails und deferred' do
    let(:imap) { double('IMAP') }
    let(:user) { double('User', id: 7, login: 'neu@extern.de') }
    let(:matrix_settings) { { 'address_matrix' => "support@firma.de:42\n", 'inbox_ticket_id' => '1', 'imap_username' => 'pm@firma.de', 'ignore_email_addresses' => "noreply@firma.de\n" } }

    def build_mail(to:, subject:, from: 'neu@extern.de')
      Mail.new(from: from, to: to, subject: subject, body: 'Hallo')
    end

    before do
      allow(service).to receive(:find_existing_user).and_return(nil)
      allow(service).to receive(:archive_message)
      allow(service).to receive(:defer_message)
      allow(service).to receive(:move_to_ignored_folder)
      allow(service).to receive(:add_mail_to_ticket)
      allow(service).to receive(:add_mail_to_inbox_ticket)
    end

    describe '#system_address?' do
      it 'erkennt IMAP-Konto, Redmine-Absender und Dummy-Domain' do
        service.update_settings(matrix_settings.merge('dummy_mail_enabled' => '1', 'dummy_mail_suffix' => 'dummy.firma.de'))
        expect(service.send(:system_address?, 'pm@firma.de')).to be true
        expect(service.send(:system_address?, 'PM Postfach <PM@firma.de>')).to be true
        expect(service.send(:system_address?, 'redmine@firma.de')).to be true
        expect(service.send(:system_address?, 'jemand@dummy.firma.de')).to be true
        expect(service.send(:system_address?, 'kunde@extern.de')).to be false
      end
    end

    describe '#create_new_user' do
      it 'legt fuer Systemadressen keinen Benutzer an' do
        service.update_settings(matrix_settings)
        expect(User).not_to receive(:new)
        expect(service.send(:create_new_user, 'pm@firma.de')).to be_nil
      end
    end

    describe '#resolve_ticket_id' do
      it 'liefert die ID aus dem Betreff' do
        mail = build_mail(to: 'irgendwer@firma.de', subject: '[#5] Test')
        expect(service.send(:resolve_ticket_id, mail)).to eq([5, :subject])
      end

      it 'liefert die Alias-ID und ergaenzt den Betreff' do
        service.update_settings(matrix_settings)
        mail = build_mail(to: 'support@firma.de', subject: 'Frage')
        expect(service.send(:resolve_ticket_id, mail)).to eq([42, :alias])
        expect(mail.subject).to eq('[#42] Frage')
      end

      it 'liefert nil ohne Treffer' do
        service.update_settings(matrix_settings)
        mail = build_mail(to: 'anders@firma.de', subject: 'Frage')
        expect(service.send(:resolve_ticket_id, mail)).to eq([nil, nil])
      end
    end

    describe '#process_message' do
      before do
        allow(imap).to receive(:fetch).with(1, 'UID').and_return([double(attr: { 'UID' => 1 })])
      end

      def stub_fetch(mail)
        allow(imap).to receive(:fetch).with(1, 'RFC822').and_return([double(attr: { 'RFC822' => mail.to_s })])
      end

      it 'legt bei erkannter Alias-Mail einen Benutzer an statt zurueckzustellen' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'support@firma.de', subject: 'Frage'))
        expect(service).to receive(:create_new_user).with('neu@extern.de').and_return(user)
        expect(service).to receive(:add_mail_to_ticket).with(anything, 42, user)
        expect(service).not_to receive(:defer_message)
        expect(service).to receive(:archive_message)

        service.send(:process_message, imap, 1)
      end

      it 'verschiebt Mails von der eigenen Postfachadresse in den Ignored-Ordner' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'support@firma.de', subject: '[#42] Ticket wurde aktualisiert', from: 'pm@firma.de'))
        expect(service).not_to receive(:create_new_user)
        expect(service).to receive(:move_to_ignored_folder)
        expect(service).not_to receive(:defer_message)

        service.send(:process_message, imap, 1)
      end

      it 'stellt Mails ohne Ticket-Bezug von unbekannten Absendern weiterhin zurueck' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'anders@firma.de', subject: 'Frage'))
        expect(service).not_to receive(:create_new_user)
        expect(service).to receive(:defer_message)
        expect(service).not_to receive(:archive_message)

        service.send(:process_message, imap, 1)
      end
    end

    describe '#process_deferred_message' do
      def stub_fetch(mail)
        allow(imap).to receive(:fetch).with(1, 'RFC822').and_return([double(attr: { 'RFC822' => mail.to_s })])
      end

      it 'verarbeitet eine zurueckgestellte Alias-Mail sofort und legt den Benutzer an' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'support@firma.de', subject: 'Frage'))
        expect(service).to receive(:create_new_user).with('neu@extern.de').and_return(user)
        expect(service).to receive(:add_mail_to_ticket).with(anything, 42, user)
        expect(service).to receive(:archive_message)

        expect(service.process_deferred_message(imap, 1)).to eq(:processed)
      end

      it 'legt bei Ticket-ID im Betreff ohne Alias KEINEN Benutzer an und behaelt die Mail in deferred' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'anders@firma.de', subject: '[#51340] Ticket wurde aktualisiert'))
        expect(service).not_to receive(:create_new_user)
        expect(service).not_to receive(:add_mail_to_ticket)

        expect(service.process_deferred_message(imap, 1)).to eq(:kept)
      end

      it 'verschiebt zurueckgestellte Mails von Ignore-Liste oder Systemadresse in den Ignored-Ordner' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'support@firma.de', subject: '[#42] x', from: 'pm@firma.de'))
        expect(service).not_to receive(:create_new_user)
        expect(service).to receive(:move_to_ignored_folder)
        expect(service.process_deferred_message(imap, 1)).to eq(:ignored)

        stub_fetch(build_mail(to: 'support@firma.de', subject: 'x', from: 'noreply@firma.de'))
        expect(service.process_deferred_message(imap, 1)).to eq(:ignored)
      end

      it 'behaelt Mails ohne Ticket-Bezug von unbekannten Absendern in deferred' do
        service.update_settings(matrix_settings)
        stub_fetch(build_mail(to: 'anders@firma.de', subject: 'Frage'))
        expect(service).not_to receive(:create_new_user)
        expect(service).not_to receive(:archive_message)

        expect(service.process_deferred_message(imap, 1)).to eq(:kept)
      end

      it 'nutzt bei bekanntem Benutzer das Alias-Ticket statt des Inbox-Tickets' do
        service.update_settings(matrix_settings)
        allow(service).to receive(:find_existing_user).and_return(user)
        stub_fetch(build_mail(to: 'support@firma.de', subject: 'Frage'))
        expect(service).to receive(:add_mail_to_ticket).with(anything, 42, user)
        expect(service).not_to receive(:add_mail_to_inbox_ticket)

        expect(service.process_deferred_message(imap, 1)).to eq(:processed)
      end
    end
  end

  describe '#sanitize_utf8_for_mysql' do
    it 'entfernt Emojis (4-Byte UTF-8 Zeichen)' do
      input = "Hallo Welt 😊"
      expected = "Hallo Welt □"
      expect(service.send(:sanitize_utf8_for_mysql, input)).to eq(expected)
    end

    it 'behält normale Zeichen bei' do
      input = "Hallo Welt 123 äöü"
      expect(service.send(:sanitize_utf8_for_mysql, input)).to eq(input)
    end
  end

  describe '#decode_header_with_mail_decoder' do
    it 'dekodiert MIME-Encoded-Words mit Mail::Encodings' do
      input = "=?UTF-8?Q?Test=20Subject?="
      expected = "Test Subject"
      
      # Mock Mail::Encodings
      encodings_double = double('Mail::Encodings')
      allow(encodings_double).to receive(:value_decode).with(input).and_return(expected)
      stub_const('Mail::Encodings', encodings_double)
      
      expect(service.send(:decode_header_with_mail_decoder, input)).to eq(expected)
    end
  end
end

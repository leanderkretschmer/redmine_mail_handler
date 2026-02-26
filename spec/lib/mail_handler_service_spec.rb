require 'rspec'

# Stub-Umgebung, damit das Laden der Service-Klasse ohne Redmine möglich ist
module Redmine; module I18n; end; end

class Setting
  def self.plugin_redmine_mail_handler
    {} # minimale Settings
  end
end

class MailHandlerLogger
  def self.reset_logger_state; end
  def info(*) end
  def debug(*) end
  def warn(*) end
  def error(*) end
  def info_mail(*) end
  def error_mail(*) end
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
      img1 = AttachmentStub.new('bild1.png', 'image/png', nil, nil)
      img2 = AttachmentStub.new('foto2.jpg', 'image/jpeg', nil, nil)
      mail = MailStub.new([img1, img2])
      content = "Text \uFFFC und \uFFFC Ende"
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to include('Text !bild1.png! und !foto2.jpg! Ende')
    end

    it 'ersetzt cid:CONTENTID durch !filename!' do
      img = AttachmentStub.new('logo.gif', 'image/gif', '<abc123>', { 'content-id' => '<abc123>' })
      mail = MailStub.new([img])
      content = "Bitte siehe cid:abc123 hier."
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to include('Bitte siehe !logo.gif! hier.')
    end

    it 'hängt Bildreferenzen an, wenn keine Platzhalter gefunden werden' do
      img = AttachmentStub.new('diagramm.svg', 'image/svg+xml', nil, nil)
      mail = MailStub.new([img])
      content = "Beschreibung ohne Bilder"
      result = service.send(:apply_image_reference_filter, content, mail, [])
      expect(result).to match(/Beschreibung ohne Bilder\s+!diagramm.svg!/m)
    end

    it 'ignoriert blockierte Bild-Anhänge' do
      ok = AttachmentStub.new('ok.png', 'image/png', nil, nil)
      blocked = AttachmentStub.new('blocked.jpg', 'image/jpeg', nil, nil)
      mail = MailStub.new([ok, blocked])
      content = "C"
      result = service.send(:apply_image_reference_filter, content, mail, ['blocked.jpg'])
      expect(result).to match(/C\s+!ok.png!/m)
      expect(result).not_to include('blocked.jpg')
    end
  end
end


require_dependency 'journal'

module MailHandlerJournalPatch
  def self.included(base)
    base.class_eval do
      before_save :repair_disabled_images_if_moved
      after_save  :migrate_disabled_images_attachments_if_moved
    end
  end

  def repair_disabled_images_if_moved
    @_mail_handler_images_to_migrate = nil
    return unless self.notes.present?

    settings = Setting.plugin_redmine_mail_handler || {}
    return unless settings['performance_disable_images'] == '1'

    disabled_ids = settings['performance_disabled_ticket_ids'].to_s.split(',').map(&:strip)
    inbox_id = settings['inbox_ticket_id'].to_s.strip
    disabled_ids << inbox_id if inbox_id.present?

    return unless self.journalized_type == 'Issue'
    return if disabled_ids.include?(self.journalized_id.to_s)

    # Original-Dateinamen aus den DISABLED_IMG-Markern lesen, bevor wir die Notes
    # zurückschreiben. Diese Liste nutzen wir im after_save, um die zugehoerigen
    # PNG-Anhaenge vom Quell-Ticket ans Ziel-Ticket nachzuziehen.
    filenames = self.notes.scan(/\{\{DISABLED_IMG:([^\}]+)\}\}/).flatten.map(&:strip).uniq
    return if filenames.empty?

    fmt = (Setting.respond_to?(:text_formatting) ? Setting.text_formatting.to_s.downcase : 'textile')
    is_markdown = (fmt != 'textile') && !fmt.empty?

    if is_markdown
      self.notes = self.notes.gsub(/!\[\]\(attachment:vorschau_deaktiviert\.png\)\r?\n\{\{DISABLED_IMG:([^\}]+)\}\}/) do
        "![](attachment:#{$1})"
      end
    else
      self.notes = self.notes.gsub(/!vorschau_deaktiviert\.png!\r?\n\{\{DISABLED_IMG:([^\}]+)\}\}/) do
        "!#{$1}!"
      end
    end

    @_mail_handler_images_to_migrate = {
      filenames: filenames,
      source_issue_id: (self.journalized_id_changed? ? self.journalized_id_was : nil)
    }
  end

  def migrate_disabled_images_attachments_if_moved
    pending = @_mail_handler_images_to_migrate
    @_mail_handler_images_to_migrate = nil
    return unless pending.is_a?(Hash)
    return unless self.journalized_type == 'Issue'

    target_issue = Issue.find_by(id: self.journalized_id)
    return unless target_issue

    filenames = pending[:filenames] || []
    source_issue_id = pending[:source_issue_id]
    source_issue = source_issue_id.present? ? Issue.find_by(id: source_issue_id) : nil

    author = User.find_by(id: self.user_id)

    filenames.each do |filename|
      # Bereits am Ziel-Ticket vorhanden -> nichts zu tun
      next if target_issue.attachments.any? { |a| a.filename == filename }

      src_att = nil
      if source_issue
        src_att = source_issue.attachments.find { |a| a.filename == filename }
      end

      unless src_att
        Rails.logger.warn("[mail_handler] DISABLED_IMG #{filename}: Quell-Attachment nicht gefunden (source_issue=#{source_issue_id || 'unbekannt'})")
        next
      end

      disk = src_att.diskfile rescue nil
      unless disk && File.exist?(disk)
        Rails.logger.warn("[mail_handler] DISABLED_IMG #{filename}: Datei auf Disk fehlt (#{disk.inspect})")
        next
      end

      begin
        File.open(disk, 'rb') do |f|
          new_att = Attachment.new(
            :file         => f,
            :filename     => src_att.filename,
            :author       => author || src_att.author,
            :content_type => src_att.content_type,
            :description  => src_att.description,
            :container    => target_issue
          )
          unless new_att.save
            Rails.logger.error("[mail_handler] Konnte Attachment #{filename} nicht ans Ziel-Ticket ##{target_issue.id} kopieren: #{new_att.errors.full_messages.join(', ')}")
          end
        end
      rescue => e
        Rails.logger.error("[mail_handler] Fehler beim Kopieren von DISABLED_IMG #{filename}: #{e.class}: #{e.message}")
      end
    end
  end
end

Rails.application.config.to_prepare do
  unless Journal.included_modules.include?(MailHandlerJournalPatch)
    Journal.send(:include, MailHandlerJournalPatch)
  end
end

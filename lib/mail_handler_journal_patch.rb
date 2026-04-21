require_dependency 'journal'

module MailHandlerJournalPatch
  def self.included(base)
    base.class_eval do
      before_save :repair_disabled_images_if_moved
    end
  end

  def repair_disabled_images_if_moved
    return unless self.notes.present?
    
    settings = Setting.plugin_redmine_mail_handler || {}
    return unless settings['performance_disable_images'] == '1'

    disabled_ids = settings['performance_disabled_ticket_ids'].to_s.split(',').map(&:strip)
    inbox_id = settings['inbox_ticket_id'].to_s.strip
    disabled_ids << inbox_id if inbox_id.present?

    # Repair if the journal is now on an issue that is NOT in the disabled list
    if self.journalized_type == 'Issue' && !disabled_ids.include?(self.journalized_id.to_s)
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
    end
  end
end

Rails.application.config.to_prepare do
  unless Journal.included_modules.include?(MailHandlerJournalPatch)
    Journal.send(:include, MailHandlerJournalPatch)
  end
end

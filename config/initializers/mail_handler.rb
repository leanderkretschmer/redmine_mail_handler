# Mail Handler Plugin Initializer

# Lade Plugin-spezifische Klassen
require_dependency File.join(File.dirname(__FILE__), '../../lib/mail_handler_service')
require_dependency File.join(File.dirname(__FILE__), '../../lib/mail_handler_scheduler')
require_dependency File.join(File.dirname(__FILE__), '../../lib/mail_handler_logger')
require_dependency File.join(File.dirname(__FILE__), '../../lib/mail_handler_hooks')

# Registriere Hooks
Rails.application.config.after_initialize do
  # Stelle sicher, dass die Hooks registriert sind
  unless Redmine::Hook.hook_listeners(:view_layouts_base_html_head).any? { |h| h.is_a?(MailHandlerHooks) }
    Redmine::Hook.add_listener(MailHandlerHooks)
  end
  
  unless Redmine::Hook.hook_listeners(:controller_issues_new_after_save).any? { |h| h.is_a?(MailHandlerModelHooks) }
    Redmine::Hook.add_listener(MailHandlerModelHooks)
  end
  
  # Initialisiere Standard-SMTP-Einstellungen falls nicht vorhanden
  if Setting.plugin_redmine_mail_handler.present?
    settings = Setting.plugin_redmine_mail_handler
    default_smtp_settings = {
      'smtp_same_as_imap' => '1',
      'smtp_host' => '',
      'smtp_port' => '465',
      'smtp_ssl' => '1',
      'smtp_username' => '',
      'smtp_password' => '',
      'user_firstname_type' => 'mail_account',
      'user_lastname_custom' => 'Auto-generated',
      'ignore_email_addresses' => ''
    }
    
    # Füge fehlende SMTP-Einstellungen hinzu
    updated = false
    default_smtp_settings.each do |key, value|
      unless settings.key?(key)
        settings[key] = value
        updated = true
      end
    end
    
    if updated
      Setting.plugin_redmine_mail_handler = settings
      Rails.logger.info "[MailHandler] Added default SMTP settings"
    end
  end
  
  if defined?(MailHandlerScheduler) && Setting.plugin_redmine_mail_handler.present?
    settings = Setting.plugin_redmine_mail_handler
    if settings['auto_import_enabled'] == '1' || settings['deferred_enabled'] == '1'
      begin
        MailHandlerScheduler.start unless MailHandlerScheduler.running?
        Rails.logger.info "[MailHandler] Scheduler started automatically"
      rescue => e
        Rails.logger.error "[MailHandler] Failed to start scheduler: #{e.message}"
      end
    end
  end
end

# Graceful Shutdown für Scheduler
at_exit do
  if defined?(MailHandlerScheduler) && MailHandlerScheduler.running?
    begin
      MailHandlerScheduler.stop
      Rails.logger.info "[MailHandler] Scheduler stopped gracefully"
    rescue => e
      Rails.logger.error "[MailHandler] Error stopping scheduler: #{e.message}"
    end
  end
end

# Konfiguriere Mail-Encoding
if defined?(Mail)
  Mail.defaults do
    charset 'UTF-8'
  end
end

# Erweitere User-Model für Mail-Handler-spezifische Methoden
Rails.application.config.to_prepare do
  User.class_eval do
    # Prüfe ob Benutzer durch Mail Handler erstellt wurde
    def created_by_mail_handler?
      settings = Setting.plugin_redmine_mail_handler || {}
      expected_lastname = settings['user_lastname_custom'] || 'Auto-generated'
      self.status == User::STATUS_LOCKED && self.lastname == expected_lastname
    end
    
    # Aktiviere Benutzer (für Admin-Interface)
    def activate_mail_handler_user!
      if created_by_mail_handler?
        self.status = User::STATUS_ACTIVE
        self.lastname = 'Mail User'
        self.save!
      end
    end
  end
end
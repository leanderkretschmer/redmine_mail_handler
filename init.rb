# Redmine Mail Handler Plugin
# Plugin für erweiterte Mail-Verarbeitung in Redmine 6

Redmine::Plugin.register :redmine_mail_handler do
  name 'Redmine Mail Handler'
  author 'Leander Kretschmer'
  description 'Erweiterte Mail-Verarbeitung für Redmine mit IMAP-Support, automatischer Ticket-Zuweisung und Reminder-Funktionen'
  version '0.3.1'
  url 'https://github.com/leanderkretschmer/redmine_mail_handler'
  author_url 'https://github.com/leanderkretschmer'

  requires_redmine :version_or_higher => '6.0.0'

  # Plugin-Einstellungen definieren
  settings :default => {
    'imap_host' => '',
    'imap_port' => '993',
    'imap_ssl' => '1',
    'imap_username' => '',
    'imap_password' => '',
    'inbox_folder' => 'INBOX',
    'archive_folder' => 'Archive',
    'ignored_folder' => 'Ignored',
    'deferred_folder' => 'Deferred',
    'inbox_ticket_id' => '',
    'dev_mode' => '0',
    'dummy_mail_enabled' => '0',
    'dummy_mail_suffix' => '',
    'dummy_mail_save_original' => '0',
    'auto_import_enabled' => '1',
    'import_interval' => '5',
    'log_level' => 'info',
    'smtp_same_as_imap' => '1',
    'smtp_host' => '',
    'smtp_port' => '465',
    'smtp_ssl' => '1',
    'smtp_username' => '',
    'smtp_password' => '',
    'user_firstname_type' => 'mail_account',
      'user_lastname_custom' => 'Auto-generated',
      'ignore_email_addresses' => '',
      'parser_mode' => 'text_representation',
      'html_attachment_enabled' => '0',
      'backdate_comments' => '1',
      'mail_decoder_enabled' => '1',
      'html_structure_filter_enabled' => '1',
      'regex_filter_enabled' => '1',
      'regex_separators' => "Am .* schrieb .*:\nVon:\nGesendet:\nAn:\nBetreff:\n-----Original Message-----\n-------- Ursprüngliche Nachricht --------",
      'whitespace_filter_enabled' => '1',
      'normalize_paragraphs_enabled' => '1',
      'max_consecutive_paragraphs' => '2',
      'markdown_link_filter_enabled' => '1',
      'exclude_attachments_enabled' => '1',
      'excluded_attachment_patterns' => '',
      'deduplication_enabled' => '1'
    }, :partial => 'settings/mail_handler_settings'

  # Menü-Einträge hinzufügen
  menu :admin_menu, :mail_handler, { :controller => 'mail_handler_admin', :action => 'index' }, 
       :caption => 'Mail Handler', :html => {:class => 'icon icon-email'}

  # Berechtigungen definieren
  project_module :mail_handler do
    permission :view_mail_logs, {:mail_handler_logs => [:index, :show]}
    permission :manage_mail_handler, {:mail_handler_admin => [:index, :test_mail, :manual_import]}
  end
end

# Hooks für Plugin-Initialisierung
if Rails.env.development?
  ActiveSupport::Dependencies.autoload_paths << File.dirname(__FILE__)
end

# Lade Plugin-spezifische Klassen
require File.expand_path('../lib/mail_handler_service', __FILE__)
require File.expand_path('../lib/mail_handler_scheduler', __FILE__)
require File.expand_path('../lib/mail_handler_logger', __FILE__)
require File.expand_path('../lib/mail_handler_hooks', __FILE__)

# Initialisiere Scheduler nach Plugin-Load
Rails.application.config.after_initialize do
  settings = Setting.plugin_redmine_mail_handler
  if settings && (settings['auto_import_enabled'] == '1' || settings['deferred_enabled'] == '1')
    MailHandlerScheduler.start
  end
end
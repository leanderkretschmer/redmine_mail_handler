class MailHandlerHooks < Redmine::Hook::ViewListener
  # Hook für Administration-Menü
  def view_layouts_base_html_head(context = {})
    html = ''
    
    # CSS für Admin-Bereich
    if context[:controller] && context[:controller].is_a?(MailHandlerAdminController)
      html += stylesheet_link_tag('mail_handler', :plugin => 'redmine_mail_handler')
    end
    
    html.html_safe
  end
  
  # Hook für die Anzeige der Issue-Beschreibung
  def view_issues_show_description_bottom(context={})
    controller = context[:controller]
    if controller
      controller.render_to_string(
        partial: 'issues/mail_handler_info',
        locals: {}
      )
    end
  end
  

  
  # Hook für zusätzliche Admin-Links
  def view_admin_index_left(context = {})
    content_tag :p do
      link_to 'Mail Handler', 
              { :controller => 'mail_handler_admin', :action => 'index' },
              :class => 'icon icon-email'
    end
  end
  
  # Hook für Projekt-Einstellungen (falls gewünscht)
  def view_projects_settings_members_table_header(context = {})
    # Hier könnten projektspezifische Mail-Handler-Einstellungen hinzugefügt werden
  end
  
  # Hook für Journal-Anzeige (Kommentare)
  def view_issues_history_journal_bottom(context = {})
    journal = context[:journal]
    issue = context[:issue]
    
    return '' unless journal && issue
    
    # Nur für Admins anzeigen
    return '' unless User.current && User.current.admin?
    
    settings = Setting.plugin_redmine_mail_handler || {}
    
    # Prüfe ob Block-User-Buttons aktiviert sind
    return '' unless settings['block_user_buttons_enabled'] == '1'
    
    # Prüfe ob es sich um das Posteingang-Ticket handelt
    inbox_ticket_id = settings['inbox_ticket_id'].to_i
    return '' unless inbox_ticket_id > 0 && issue.id == inbox_ticket_id
    
    # Prüfe ob der Journal-Eintrag einen Benutzer hat (nicht anonym)
    return '' unless journal.user && journal.user != User.anonymous
    
    # Prüfe ob der Benutzer eine E-Mail-Adresse hat
    user_email = journal.user.mail || journal.user.email_addresses.first&.address
    return '' unless user_email.present?
    
    # Prüfe ob der Benutzer bereits blockiert ist
    ignore_list = settings['ignore_email_addresses'] || ''
    is_blocked = ignore_list.split("\n").map(&:strip).reject(&:blank?).any? do |pattern|
      if pattern.include?('*')
        regex_pattern = pattern.gsub('*', '.*')
        user_email.match?(/\A#{regex_pattern}\z/i)
      else
        user_email.downcase == pattern.downcase
      end
    end
    
    # Rendere Block-Button
    controller = context[:controller]
    if controller
      controller.render_to_string(
        partial: 'mail_handler/block_user_button',
        locals: {
          journal: journal,
          issue: issue,
          user: journal.user,
          user_email: user_email,
          is_blocked: is_blocked
        }
      )
    else
      ''
    end
  end

end

class MailHandlerModelHooks < Redmine::Hook::Listener
  # Hook nach Issue-Erstellung
  def controller_issues_new_after_save(context = {})
    issue = context[:issue]
    logger = MailHandlerLogger.new
    logger.info("New issue created: ##{issue.id} - #{issue.subject}")
  end
  
  # Hook nach Issue-Update
  def controller_issues_edit_after_save(context = {})
    issue = context[:issue]
    journal = context[:journal]
    
    if journal && journal.notes.present?
      logger = MailHandlerLogger.new
      logger.info("Issue ##{issue.id} updated with notes via mail handler")
    end
  end
  
  # Hook nach Benutzer-Erstellung
  def model_user_after_create(context = {})
    user = context[:user]
    
    # Prüfe ob Benutzer durch Mail Handler erstellt wurde
    if user.status == User::STATUS_LOCKED && user.lastname == 'Auto-created'
      logger = MailHandlerLogger.new
      logger.info("Auto-created user for mail processing: #{user.email_address}")
    end
  end


end
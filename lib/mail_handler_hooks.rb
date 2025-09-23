class MailHandlerHooks < Redmine::Hook::ViewListener
  # Hook für Administration-Menü und Block User Funktionalität
  def view_layouts_base_html_head(context = {})
    html = ''
    
    # CSS für Admin-Bereich
    if context[:controller] && context[:controller].is_a?(MailHandlerAdminController)
      html += stylesheet_link_tag('mail_handler', :plugin => 'redmine_mail_handler')
    end
    
    # Block User Funktionalität auf Ticket-Seiten
    if context[:controller] && context[:controller].controller_name == 'issues'
      settings = Setting.plugin_redmine_mail_handler
      
      # Debug-Ausgabe in Rails-Log
      Rails.logger.info "Block User Hook: Controller=#{context[:controller].controller_name}, Action=#{context[:controller].action_name}"
      Rails.logger.info "Block User Hook: Settings present=#{!settings.nil?}, show_block_user=#{settings&.[]('show_block_user')}"
      
      if settings && settings['show_block_user'] == '1'
        # Prüfe ob es sich um das Posteingang-Ticket handelt
        inbox_ticket_id = settings['inbox_ticket_id'].to_i
        current_issue_id = context[:controller].params[:id].to_i
        
        Rails.logger.info "Block User Hook: inbox_ticket_id=#{inbox_ticket_id}, current_issue_id=#{current_issue_id}"
        
        if inbox_ticket_id > 0 && current_issue_id == inbox_ticket_id
          # Lade CSS und JavaScript für Block User Buttons
          html += stylesheet_link_tag('block_user', :plugin => 'redmine_mail_handler')
          html += javascript_include_tag('block_user', :plugin => 'redmine_mail_handler')
          
          Rails.logger.info "Block User Hook: CSS and JS loaded for inbox ticket"
        end
      end
    end
    
    html.html_safe
  end
  
  # Hook für Issue-Ansicht - Optimierte Kommentar-Verschiebung
  def view_issues_show_description_bottom(context = {})
    controller = context[:controller]
    if controller && Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
      controller.render_to_string(
        partial: 'issues/optimized_comment_move',
        locals: {}
      )
    else
      ''
    end
  end
  
  # Hook für Journal-Kommentare - Verschieben-Option im Kontextmenü hinzufügen
  def view_journals_contextual_links(context = {})
    journal = context[:journal]
    
    if journal && journal.notes.present? && 
       Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
      
      link_html = %{
        <li>
          <a href="#" class="optimized-move-comment" data-journal-id="#{journal.id}">
            <span class="icon icon-move"></span> Verschieben
          </a>
        </li>
      }
      
      link_html.html_safe
    else
      ''
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
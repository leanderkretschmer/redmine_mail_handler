class MailHandlerAdminController < ApplicationController
  before_action :require_admin
  before_action :init_service

  def index
    @settings = Setting.plugin_redmine_mail_handler
    @scheduler_running = MailHandlerScheduler.running?
    @load_balanced_enabled = @settings['load_balanced_enabled'] == '1'
    @load_balanced_interval = @settings['load_balanced_interval'] || '5'
    @max_parallel_imports = @settings['max_parallel_imports'] || '3'
    @import_batch_size = @settings['import_batch_size'] || '50'
    @worker_timeout = @settings['worker_timeout'] || '300'
    # Letzte Logs aus Rails-Logdatei lesen und deduplizieren
    raw = MailHandlerLogger.read_logs(max_lines: 5000)
    grouped = group_consecutive_logs(raw)
    @recent_logs = grouped.first(10)
    
    # Load Balancing Counter
    @mails_per_hour = (@settings['mails_per_hour'] || '60').to_i
    @current_hour_count = get_current_hour_mail_count
    @next_reset_time = get_next_reset_time
  end

  def test_connection
    result = @service.test_connection
    
    if result[:success]
      flash[:notice] = "IMAP-Verbindung erfolgreich! Gefundene Ordner: #{result[:folders].join(', ')}"
    else
      flash[:error] = "IMAP-Verbindung fehlgeschlagen: #{result[:error]}"
    end
    
    redirect_to action: :index
  end

  def test_mail
    email = params[:test_email]
    
    if email.blank?
      flash[:error] = "Bitte geben Sie eine E-Mail-Adresse ein."
    elsif @service.send_test_mail(email)
      flash[:notice] = "Test-E-Mail wurde erfolgreich an #{email} gesendet."
    else
      flash[:error] = "Fehler beim Senden der Test-E-Mail."
    end
    
    redirect_to action: :index
  end

  def test_imap_connection
    # Temporär die Plugin-Einstellungen mit den übergebenen Parametern überschreiben
    original_settings = Setting.plugin_redmine_mail_handler.dup
    
    temp_settings = original_settings.merge({
      'imap_host' => params[:imap_host],
      'imap_port' => params[:imap_port],
      'imap_ssl' => params[:imap_ssl],
      'imap_username' => params[:imap_username],
      'imap_password' => params[:imap_password]
    })
    
    # Temporär die Einstellungen setzen
    Setting.plugin_redmine_mail_handler = temp_settings
    
    # Service erstellen und Verbindung testen
    service = MailHandlerService.new
    result = service.test_connection
    
    # Ursprüngliche Einstellungen wiederherstellen
    Setting.plugin_redmine_mail_handler = original_settings
    
    if result[:success]
      render json: { success: true, message: 'IMAP-Verbindung erfolgreich!' }
    else
      render json: { success: false, error: result[:error] }
    end
  rescue => e
    # Sicherstellen, dass die ursprünglichen Einstellungen wiederhergestellt werden
    Setting.plugin_redmine_mail_handler = original_settings if original_settings
    render json: { success: false, error: e.message }
  end

  def test_smtp_connection
    # Temporär die Plugin-Einstellungen mit den übergebenen Parametern überschreiben
    original_settings = Setting.plugin_redmine_mail_handler.dup
    
    temp_settings = original_settings.merge({
      'smtp_host' => params[:smtp_host],
      'smtp_port' => params[:smtp_port],
      'smtp_ssl' => params[:smtp_ssl],
      'smtp_username' => params[:smtp_username],
      'smtp_password' => params[:smtp_password]
    })
    
    # Temporär die Einstellungen setzen
    Setting.plugin_redmine_mail_handler = temp_settings
    
    begin
      # SMTP-Verbindung testen
      require 'net/smtp'
      
      host = params[:smtp_host]
      port = params[:smtp_port].to_i
      ssl = params[:smtp_ssl] == '1'
      username = params[:smtp_username]
      password = params[:smtp_password]
      
      # Validierung
      if host.blank? || username.blank? || password.blank?
        raise 'Bitte füllen Sie alle SMTP-Felder aus'
      end
      
      # SMTP-Verbindung aufbauen
      smtp = Net::SMTP.new(host, port)
      smtp.enable_ssl if ssl
      smtp.start(host, username, password, :login)
      smtp.finish
      
      # Ursprüngliche Einstellungen wiederherstellen
      Setting.plugin_redmine_mail_handler = original_settings
      
      render json: { success: true, message: 'SMTP-Verbindung erfolgreich!' }
    rescue => e
      # Ursprüngliche Einstellungen wiederherstellen
      Setting.plugin_redmine_mail_handler = original_settings if original_settings
      render json: { success: false, error: e.message }
    end
  end

  def get_imap_folders
    # Temporär die Plugin-Einstellungen mit den übergebenen Parametern überschreiben
    original_settings = Setting.plugin_redmine_mail_handler.dup
    
    temp_settings = original_settings.merge({
      'imap_host' => params[:imap_host],
      'imap_port' => params[:imap_port],
      'imap_ssl' => params[:imap_ssl],
      'imap_username' => params[:imap_username],
      'imap_password' => params[:imap_password]
    })
    
    # Temporär die Einstellungen setzen
    Setting.plugin_redmine_mail_handler = temp_settings
    
    # Service erstellen und Ordner laden
    service = MailHandlerService.new
    folders = service.list_imap_folders
    
    # Ursprüngliche Einstellungen wiederherstellen
    Setting.plugin_redmine_mail_handler = original_settings
    
    render json: { success: true, folders: folders }
  rescue => e
    # Sicherstellen, dass die ursprünglichen Einstellungen wiederhergestellt werden
    Setting.plugin_redmine_mail_handler = original_settings if original_settings
    render json: { success: false, error: e.message }
  end

  def manual_import
    limit = params[:import_limit].to_i
    limit = nil if limit <= 0
    
    if @service.import_mails(limit)
      message = limit ? "#{limit} E-Mails wurden erfolgreich importiert." : "Alle E-Mails wurden erfolgreich importiert."
      flash[:notice] = message
    else
      flash[:error] = "Fehler beim E-Mail-Import. Überprüfen Sie die Logs für Details."
    end
    
    redirect_to action: :index
  end

  def process_deferred
    begin
      @service.process_deferred_mails
      flash[:notice] = "Zurückgestellt-Verarbeitung wurde erfolgreich durchgeführt."
    rescue => e
      flash[:error] = "Zurückgestellt-Verarbeitung fehlgeschlagen: #{e.message}"
    end
    
    redirect_to action: :index
  end

  def deferred_status
    begin
      # Hole Statistiken aus IMAP-Ordner
      @deferred_stats = @service.count_deferred_messages
      
      # Für die Anzeige: Keine einzelnen Einträge mehr, nur Statistiken
      @deferred_entries = []
      @total_count = @deferred_stats[:total]
      @total_pages = 0
      @page = 1
      @per_page = 25
      @per_page_options = valid_per_page_options
      
    rescue => e
      @deferred_entries = []
      @deferred_stats = { total: 0, active: 0, expired: 0 }
      @total_count = 0
      @total_pages = 0
      @page = 1
      @per_page = 25
      @per_page_options = valid_per_page_options
      flash[:error] = "Fehler beim Abrufen der Deferred-Statistiken: #{e.message}"
    end
    
    render partial: 'deferred_status' if request.xhr?
  end

  def toggle_scheduler
    if MailHandlerScheduler.running?
      MailHandlerScheduler.stop
      flash[:notice] = "Scheduler wurde gestoppt."
    else
      MailHandlerScheduler.start
      flash[:notice] = "Scheduler wurde gestartet."
    end
    
    redirect_to action: :index
  end

  def restart_scheduler
    MailHandlerScheduler.restart
    flash[:notice] = "Scheduler wurde neu gestartet."
    redirect_to action: :index
  end

  def clear_logs
    # File-basiertes Logging: kein DB-Clear. Hinweis anzeigen.
    flash[:notice] = "File-basiertes Logging aktiv – keine DB-Logs zu löschen."
    redirect_to action: :index
  end

  def cleanup_old_logs
    # File-basiertes Logging: keine DB-Logs aufzuräumen. Hinweis anzeigen.
    flash[:notice] = "File-basiertes Logging aktiv – Aufräumen nicht erforderlich."
    redirect_to action: :index
  end

  def toggle_load_balancing
    settings = Setting.plugin_redmine_mail_handler
    current_state = settings['load_balanced_enabled'] == '1'
    
    # Toggle Load-Balancing Status
    new_settings = settings.dup
    new_settings['load_balanced_enabled'] = current_state ? '0' : '1'
    
    Setting.plugin_redmine_mail_handler = new_settings
    
    if current_state
      flash[:notice] = "Load-Balanced Importing wurde deaktiviert."
    else
      flash[:notice] = "Load-Balanced Importing wurde aktiviert."
      # Restart scheduler to apply new settings
      if MailHandlerScheduler.running?
        MailHandlerScheduler.restart
        flash[:notice] += " Scheduler wurde neu gestartet."
      end
    end
    
    redirect_to action: :index
  end

  def create_user_from_mail
    # Diese Funktion ist nicht mehr verfügbar, da keine einzelnen deferred Einträge mehr angezeigt werden
    flash[:error] = "Diese Funktion ist nicht mehr verfügbar. Benutzer können über die normale Redmine-Benutzerverwaltung erstellt werden."
    redirect_to action: :deferred_status
  end

  def process_deferred_mail
    # Diese Funktion ist nicht mehr verfügbar, da keine einzelnen deferred Einträge mehr verarbeitet werden
    flash[:error] = "Diese Funktion ist nicht mehr verfügbar. Verwenden Sie 'Alle zurückgestellten E-Mails verarbeiten'."
    redirect_to action: :deferred_status
  end



  def delete_anonymous_comments
    begin
      # Finde alle Journals von anonymen Benutzern (User.anonymous)
      anonymous_user = User.anonymous
      anonymous_journals = Journal.joins(:issue)
                                 .where(user_id: anonymous_user.id)
                                 .where('journals.id > (SELECT MIN(j2.id) FROM journals j2 WHERE j2.issue_id = journals.issue_id)')
      
      deleted_count = anonymous_journals.count
      
      if deleted_count > 0
        # Lösche auch alle Journal-Details (Änderungen) der anonymen Kommentare
        JournalDetail.where(journal_id: anonymous_journals.pluck(:id)).delete_all
        
        # Lösche die anonymen Journals
        anonymous_journals.delete_all
        
        logger = MailHandlerLogger.new
        logger.info("Deleted #{deleted_count} anonymous comments from all tickets")
        
        flash[:notice] = "#{deleted_count} anonyme Kommentare wurden erfolgreich aus allen Tickets gelöscht."
      else
        flash[:notice] = "Keine anonymen Kommentare zum Löschen gefunden."
      end
      
    rescue => e
      logger = MailHandlerLogger.new
      logger.error("Error deleting anonymous comments: #{e.message}")
      flash[:error] = "Fehler beim Löschen der anonymen Kommentare: #{e.message}"
    end
    
    redirect_to :action => 'index'
  end

  def delete_orphaned_attachments
    begin
      # Finde alle Attachments die keinem Journal zugeordnet sind
      # Attachments können entweder direkt an Issues oder an Journals gehängt sein
      orphaned_attachments = Attachment.joins("LEFT JOIN journals ON attachments.container_id = journals.id AND attachments.container_type = 'Journal'")
                                      .joins("LEFT JOIN issues ON attachments.container_id = issues.id AND attachments.container_type = 'Issue'")
                                      .where("journals.id IS NULL AND issues.id IS NULL")
      
      deleted_count = orphaned_attachments.count
      
      if deleted_count > 0
        # Lösche die physischen Dateien und Datenbankeinträge
        orphaned_attachments.each do |attachment|
          begin
            # Lösche die physische Datei
            if attachment.diskfile && File.exist?(attachment.diskfile)
              File.delete(attachment.diskfile)
            end
          rescue => e
            logger = MailHandlerLogger.new
            logger.warn("Could not delete physical file for orphaned attachment #{attachment.id}: #{e.message}")
          end
        end
        
        # Lösche die Attachment-Datenbankeinträge
        orphaned_attachments.delete_all
        
        logger = MailHandlerLogger.new
        logger.info("Deleted #{deleted_count} orphaned attachments")
        
        flash[:notice] = "#{deleted_count} unzugeordnete Dateien wurden erfolgreich gelöscht."
      else
        flash[:notice] = "Keine unzugeordneten Dateien zum Löschen gefunden."
      end
      
    rescue => e
      logger = MailHandlerLogger.new
      logger.error("Error deleting orphaned attachments: #{e.message}")
      flash[:error] = "Fehler beim Löschen der unzugeordneten Dateien: #{e.message}"
    end
    
    redirect_to :action => 'index'
  end

  def delete_all_comments
    begin
      settings = Setting.plugin_redmine_mail_handler
      inbox_ticket_id = settings['inbox_ticket_id'].to_i
      
      if inbox_ticket_id <= 0
        flash[:error] = 'Kein Posteingang-Ticket konfiguriert.'
        redirect_to :action => 'index'
        return
      end
      
      # Finde das Posteingang-Ticket
      inbox_ticket = Issue.find_by(id: inbox_ticket_id)
      unless inbox_ticket
        flash[:error] = "Posteingang-Ticket ##{inbox_ticket_id} nicht gefunden."
        redirect_to :action => 'index'
        return
      end
      
      # Lösche alle Journals (Kommentare) des Tickets, außer dem ersten (Ticket-Erstellung)
       journals_to_delete = inbox_ticket.journals.where('id > ?', inbox_ticket.journals.first.id)
       deleted_comments_count = journals_to_delete.count
       
       # Lösche alle angehängten Dateien des Tickets
       attachments_to_delete = inbox_ticket.attachments
       deleted_attachments_count = attachments_to_delete.count
       
       total_deleted = 0
       
       if deleted_comments_count > 0
         # Lösche auch alle Journal-Details (Änderungen)
         JournalDetail.where(journal_id: journals_to_delete.pluck(:id)).delete_all
         
         # Lösche die Journals
         journals_to_delete.delete_all
         total_deleted += deleted_comments_count
       end
       
       if deleted_attachments_count > 0
         # Lösche die physischen Dateien und Datenbankeinträge
         attachments_to_delete.each do |attachment|
           begin
             # Lösche die physische Datei
             if attachment.diskfile && File.exist?(attachment.diskfile)
               File.delete(attachment.diskfile)
             end
           rescue => e
             logger = MailHandlerLogger.new
             logger.warn("Could not delete physical file for attachment #{attachment.id}: #{e.message}")
           end
         end
         
         # Lösche die Attachment-Datenbankeinträge
         attachments_to_delete.delete_all
         total_deleted += deleted_attachments_count
       end
       
       if total_deleted > 0
         # Aktualisiere das Ticket (updated_on)
         inbox_ticket.touch
         
         logger = MailHandlerLogger.new
         logger.info("Deleted #{deleted_comments_count} comments and #{deleted_attachments_count} attachments from inbox ticket ##{inbox_ticket_id}")
         
         message_parts = []
         message_parts << "#{deleted_comments_count} Kommentare" if deleted_comments_count > 0
         message_parts << "#{deleted_attachments_count} Dateien" if deleted_attachments_count > 0
         
         flash[:notice] = "#{message_parts.join(' und ')} wurden erfolgreich aus Ticket ##{inbox_ticket_id} gelöscht."
       else
         flash[:notice] = "Keine Kommentare oder Dateien zum Löschen gefunden in Ticket ##{inbox_ticket_id}."
       end
      
    rescue => e
      logger = MailHandlerLogger.new
      logger.error("Error deleting comments: #{e.message}")
      flash[:error] = "Fehler beim Löschen der Kommentare: #{e.message}"
    end
    
    redirect_to :action => 'index'
  end





  private

  def valid_per_page_options
    [10, 25, 50, 100]
  end

  def require_admin
    render_403 unless User.current.admin?
  end
  
  private

  def init_service
    @service = MailHandlerService.new
  end
  
  def get_current_hour_mail_count
    current_hour_start = Time.current.beginning_of_hour
    logs = MailHandlerLogger.read_logs(max_lines: 5000)
    logs.count { |e| e.created_at >= current_hour_start && e.created_at <= Time.current && e.message.include?("[LOAD-BALANCED]") }
  end
  
  def get_next_reset_time
    Time.current.beginning_of_hour + 1.hour
  end

  # --- Logging-Gruppierung wie in Logs-Controller ---
  def group_consecutive_logs(raw_logs)
    require 'ostruct'
    list = raw_logs.to_a
    groups = []
    current = nil

    list.each do |log|
      normalized = normalize_message_for_grouping(log.message)
      if current && log.level == current[:level] && normalized == current[:normalized_message]
        current[:count] += 1
        current[:min_time] = log.created_at if log.created_at < current[:min_time]
        current[:max_time] = log.created_at if log.created_at > current[:max_time]
        current[:last_id] = log.id
      else
        groups << current if current
        current = {
          level: log.level,
          message: log.message,
          normalized_message: normalized,
          count: 1,
          min_time: log.created_at,
          max_time: log.created_at,
          first_id: log.id,
          last_id: log.id
        }
      end
    end
    groups << current if current

    groups.map do |g|
      OpenStruct.new(
        id: g[:first_id],
        level: g[:level],
        level_icon: level_icon_for(g[:level]),
        level_color: level_color_for(g[:level]),
        message: g[:count] > 1 ? "#{g[:normalized_message]} (x#{g[:count]})" : g[:message],
        formatted_time: formatted_time_range(g[:min_time], g[:max_time], g[:count])
      )
    end
  end

  def normalize_message_for_grouping(message)
    return '' if message.nil?
    message.to_s.sub(/\s*\(Dauer:\s*[^\)]*\)\s*$/, '')
  end

  def formatted_time_range(min_time, max_time, count)
    if count > 1
      "#{min_time.strftime('%d.%m.%Y %H:%M:%S')} – #{max_time.strftime('%d.%m.%Y %H:%M:%S')}"
    else
      max_time.strftime('%d.%m.%Y %H:%M:%S')
    end
  end

  def level_icon_for(level)
    case level
    when 'debug' then 'icon-info'
    when 'info'  then 'icon-ok'
    when 'warn'  then 'icon-warning'
    when 'error' then 'icon-error'
    else 'icon-info'
    end
  end

  def level_color_for(level)
    case level
    when 'debug' then 'gray'
    when 'info'  then 'blue'
    when 'warn'  then 'orange'
    when 'error' then 'red'
    else 'black'
    end
  end
end
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
    @recent_logs = MailHandlerLog.recent.limit(10)
    
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

  def test_reminder
    email = params[:reminder_email]
    
    if email.blank?
      flash[:error] = "Bitte geben Sie eine E-Mail-Adresse ein."
    elsif MailHandlerScheduler.send_test_reminder(email)
      flash[:notice] = "Test-Reminder wurde erfolgreich an #{email} gesendet."
    else
      flash[:error] = "Fehler beim Senden des Test-Reminders."
    end
    
    redirect_to action: :index
  end

  def send_bulk_reminder
    if MailHandlerScheduler.send_bulk_reminder
      flash[:notice] = "Bulk-Reminder wurde erfolgreich an alle Benutzer gesendet."
    else
      flash[:error] = "Fehler beim Senden des Bulk-Reminders."
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
      # Paginierung Parameter
      @per_page = params[:per_page].to_i
      @per_page = 25 if @per_page <= 0 || !valid_per_page_options.include?(@per_page)
      @page = [params[:page].to_i, 1].max
      
      # Basis Query
      deferred_query = MailDeferredEntry.includes([]).order(deferred_at: :desc)
      
      # Gesamtanzahl für Paginierung
      @total_count = deferred_query.count
      @total_pages = (@total_count.to_f / @per_page).ceil
      @page = [@page, @total_pages].min if @total_pages > 0
      
      # Deferred Entries mit Paginierung laden
      offset = (@page - 1) * @per_page
      @deferred_entries = deferred_query.limit(@per_page).offset(offset)
      
      @per_page_options = valid_per_page_options
      
      @deferred_stats = {
        total: MailDeferredEntry.count,
        active: MailDeferredEntry.active.count,
        expired: MailDeferredEntry.expired.count
      }
    rescue ActiveRecord::StatementInvalid => e
      @deferred_entries = []
      @deferred_stats = { total: 0, active: 0, expired: 0 }
      @total_count = 0
      @total_pages = 0
      @page = 1
      @per_page = 25
      @per_page_options = valid_per_page_options
      flash[:error] = "Zurückgestellt-Tabelle nicht gefunden. Bitte führen Sie die Datenbankmigrationen aus."
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
    count = MailHandlerLog.count
    MailHandlerLog.delete_all
    flash[:notice] = "#{count} Log-Einträge wurden gelöscht."
    redirect_to action: :index
  end

  def cleanup_old_logs
    count = MailHandlerLog.where('created_at < ?', 30.days.ago).count
    MailHandlerLogger.cleanup_old_logs
    flash[:notice] = "#{count} alte Log-Einträge wurden gelöscht."
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
    entry_id = params[:id]
    entry = MailDeferredEntry.find_by(id: entry_id)
    
    unless entry
      flash[:error] = "Zurückgestellte E-Mail nicht gefunden."
      redirect_to action: :deferred_status
      return
    end
    
    begin
      # Erstelle Benutzer aus E-Mail-Adresse
      user = @service.create_new_user(entry.from_address)
      
      if user && user.persisted?
        flash[:notice] = "Benutzer #{user.login} wurde erfolgreich erstellt."
      else
        flash[:error] = "Fehler beim Erstellen des Benutzers: #{user&.errors&.full_messages&.join(', ') || 'Unbekannter Fehler'}"
      end
    rescue => e
      flash[:error] = "Fehler beim Erstellen des Benutzers: #{e.message}"
    end
    
    redirect_to action: :deferred_status
  end

  def process_deferred_mail
    entry_id = params[:id]
    entry = MailDeferredEntry.find_by(id: entry_id)
    
    unless entry
      flash[:error] = "Zurückgestellte E-Mail nicht gefunden."
      redirect_to action: :deferred_status
      return
    end
    
    begin
      # Verarbeite die zurückgestellte E-Mail
      result = @service.process_single_deferred_mail(entry)
      
      if result
        flash[:notice] = "E-Mail von #{entry.from_address} wurde erfolgreich verarbeitet."
      else
        flash[:error] = "Fehler beim Verarbeiten der E-Mail von #{entry.from_address}."
      end
    rescue => e
      flash[:error] = "Fehler beim Verarbeiten der E-Mail: #{e.message}"
    end
    
    redirect_to action: :deferred_status
  end
  
  def block_user
    user_id = params[:user_id]
    user = User.find_by(id: user_id)
    
    unless user
      render json: { success: false, error: 'Benutzer nicht gefunden' }
      return
    end
    
    begin
      # Hole aktuelle Ignore-Liste
      settings = Setting.plugin_redmine_mail_handler
      current_ignore_list = settings['ignore_email_addresses'] || ''
      
      # Sammle alle E-Mail-Adressen des Benutzers
      user_emails = []
      user_emails << user.mail if user.mail.present?
      user.email_addresses.each { |ea| user_emails << ea.address if ea.address.present? }
      
      # Füge E-Mail-Adressen zur Ignore-Liste hinzu
      ignore_list = current_ignore_list.split(',').map(&:strip).reject(&:blank?)
      user_emails.each do |email|
        ignore_list << email unless ignore_list.include?(email)
      end
      
      # Aktualisiere Einstellungen
      settings['ignore_email_addresses'] = ignore_list.join(', ')
      Setting.plugin_redmine_mail_handler = settings
      
      # Lösche den Benutzer
      user.destroy
      
      render json: { 
        success: true, 
        message: "Benutzer #{user.login} wurde blockiert und gelöscht. E-Mail-Adressen zur Ignore-Liste hinzugefügt: #{user_emails.join(', ')}"
      }
      
    rescue => e
      render json: { success: false, error: "Fehler beim Blockieren des Benutzers: #{e.message}" }
    end
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
    MailHandlerLog.where(
      created_at: current_hour_start..Time.current
    ).where("message LIKE ?", "%[LOAD-BALANCED]%").count
  end
  
  def get_next_reset_time
    Time.current.beginning_of_hour + 1.hour
  end
end
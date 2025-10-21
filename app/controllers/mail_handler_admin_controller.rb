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
    # Log-Vorschau entfernt – Logging nur im Terminal/Rails-Log
    @recent_logs = []
    
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

  def deferred_mails
    begin
      # Suchparameter
      @search_from = params[:search_from]
      @search_subject = params[:search_subject]
      
      # Initialisiere Logging-Variablen
      @imap_debug_info = []
      
      # Teste IMAP-Verbindung zuerst
      @imap_connection_available = test_imap_connection_available
      
      if @imap_connection_available
        @imap_debug_info << "✓ IMAP-Verbindung erfolgreich hergestellt"
        
        # Hole alle Mails aus dem deferred Ordner
        @deferred_mails = get_deferred_mails_from_imap
        
        @imap_debug_info << "✓ #{@deferred_mails.length} E-Mails aus IMAP-Ordner geladen"
        
        # Automatisch abgelaufene E-Mails archivieren
        archived_count = archive_expired_mails(@deferred_mails)
        if archived_count > 0
          @imap_debug_info << "✓ #{archived_count} abgelaufene E-Mails archiviert"
        end
        
        # Nach der Archivierung erneut laden
        @deferred_mails = get_deferred_mails_from_imap
        @imap_debug_info << "✓ Nach Archivierung: #{@deferred_mails.length} E-Mails verfügbar"
      else
        @imap_debug_info << "✗ IMAP-Verbindung fehlgeschlagen - verwende Beispieldaten"
        # Falls IMAP-Verbindung nicht verfügbar, erstelle Test-Daten
        @deferred_mails = create_sample_deferred_mails
      end
      
      # Filtere nach Suchkriterien
      original_count = @deferred_mails.length
      if @search_from.present?
        @deferred_mails = @deferred_mails.select { |mail| mail[:from]&.downcase&.include?(@search_from.downcase) }
        @imap_debug_info << "✓ Nach Absender-Filter (#{@search_from}): #{@deferred_mails.length} E-Mails"
      end
      
      if @search_subject.present?
        @deferred_mails = @deferred_mails.select { |mail| mail[:subject]&.downcase&.include?(@search_subject.downcase) }
        @imap_debug_info << "✓ Nach Betreff-Filter (#{@search_subject}): #{@deferred_mails.length} E-Mails"
      end
      
      if (@search_from.present? || @search_subject.present?) && @deferred_mails.length < original_count
        filtered_out = original_count - @deferred_mails.length
        @imap_debug_info << "ℹ #{filtered_out} E-Mails durch Suchfilter ausgeblendet"
      end
      
      @total_count = @deferred_mails.length
      
      # Pagination - Standard auf 20 E-Mails pro Seite
      @page = (params[:page] || 1).to_i
      @per_page = (params[:per_page] || 20).to_i
      @per_page_options = [10, 20, 50, 100]
      
      # Berechne Pagination
      @total_pages = (@total_count.to_f / @per_page).ceil
      offset = (@page - 1) * @per_page
      @deferred_mails = @deferred_mails[offset, @per_page] || []
      
    rescue => e
      @deferred_mails = []
      @total_count = 0
      @total_pages = 0
      @page = 1
      @per_page = 20
      @per_page_options = [10, 20, 50, 100]
      @search_from = nil
      @search_subject = nil
      flash[:error] = "Fehler beim Laden der zurückgestellten E-Mails: #{e.message}"
    end
  end

  def rescan_deferred_mails
    selected_ids = params[:selected_ids] || []
    
    if selected_ids.empty?
      flash[:error] = "Bitte wählen Sie mindestens eine E-Mail aus."
      redirect_to action: :deferred_mails
      return
    end
    
    begin
      processed_count = rescan_selected_mails(selected_ids)
      flash[:notice] = "#{processed_count} E-Mails wurden erfolgreich neu gescannt."
    rescue => e
      flash[:error] = "Fehler beim Neu-Scannen: #{e.message}"
    end
    
    redirect_to action: :deferred_mails
  end

  def archive_deferred_mails
    selected_ids = params[:selected_ids] || []

    if selected_ids.empty?
      flash[:error] = "Bitte wählen Sie mindestens eine E-Mail aus."
      redirect_to action: :deferred_mails
      return
    end

    begin
      # Load current plugin settings to get the archive folder
      current_settings = Setting.plugin_redmine_mail_handler
      archive_folder = current_settings['archive_folder'].presence || 'Archive'
      
      # Verify archive folder is set (should always be true now with default)
      if archive_folder.blank?
        flash[:error] = "Kein Archiv-Ordner in den Plugin-Einstellungen konfiguriert. Bitte konfigurieren Sie den Archiv-Ordner unter Administration > Plugins > Mail Handler > Verarbeitung."
        redirect_to action: :deferred_mails
        return
      end
      
      Rails.logger.info "Using archive folder from plugin settings: #{archive_folder}"
      
      # Ensure archive folder is in settings before updating service
      current_settings['archive_folder'] = archive_folder
      
      # Update service settings to ensure they are current
      @service.update_settings(current_settings)
      
      archived_count = archive_selected_mails_simple(selected_ids)
      if archived_count > 0
        flash[:notice] = "#{archived_count} E-Mails wurden erfolgreich in '#{archive_folder}' archiviert."
      else
        flash[:warning] = "Keine E-Mails konnten archiviert werden."
      end
    rescue => e
      Rails.logger.error "Archive error: #{e.message}"
      Rails.logger.error "Backtrace: #{e.backtrace.join("\n")}"
      flash[:error] = "Fehler beim Archivieren: #{e.message}"
    end

    redirect_to action: :deferred_mails
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
    # Entfernt – Logging nur im Terminal
    flash[:notice] = "Logging erfolgt im Terminal – keine Logs zu löschen."
    redirect_to action: :index
  end

  def cleanup_old_logs
    # Entfernt – Logging nur im Terminal
    flash[:notice] = "Logging erfolgt im Terminal – Aufräumen nicht erforderlich."
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
    message_id = params[:message_id]
    
    if message_id.blank?
      flash[:error] = "Keine Message-ID angegeben."
      redirect_to action: :deferred_mails
      return
    end
    
    begin
      # Hole die Mail aus dem deferred Ordner
      mail = get_mail_by_message_id(message_id)
      
      if mail.nil?
        flash[:error] = "E-Mail mit Message-ID #{message_id} nicht gefunden."
        redirect_to action: :deferred_mails
        return
      end
      
      from_address = mail.from&.first
      if from_address.blank?
        flash[:error] = "Keine Absender-Adresse in der E-Mail gefunden."
        redirect_to action: :deferred_mails
        return
      end
      
      # Prüfe ob Benutzer bereits existiert
      existing_user = @service.find_existing_user(from_address)
      if existing_user
        flash[:notice] = "Benutzer für #{from_address} existiert bereits."
        redirect_to action: :deferred_mails
        return
      end
      
      # Erstelle neuen Benutzer
      new_user = @service.create_new_user(from_address)
      
      if new_user
        flash[:notice] = "Benutzer für #{from_address} wurde erfolgreich erstellt und ist gesperrt. Aktivieren Sie den Benutzer in der Benutzerverwaltung."
      else
        flash[:error] = "Fehler beim Erstellen des Benutzers für #{from_address}."
      end
      
    rescue => e
      flash[:error] = "Fehler beim Erstellen des Benutzers: #{e.message}"
    end
    
    redirect_to action: :deferred_mails
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





  # Archiviere automatisch abgelaufene E-Mails
  def archive_expired_mails(mails)
    return 0 if mails.empty?
    
    expired_mails = mails.select { |mail| mail[:expired] }
    return 0 if expired_mails.empty?
    
    begin
      imap = @service.connect_to_imap
      return 0 unless imap
      
      # Wähle den deferred Ordner
      settings = Setting.plugin_redmine_mail_handler
      deferred_folder = settings['deferred_folder'].presence || 'Deferred'
      imap.select(deferred_folder)
      
      # Wähle oder erstelle den Archive-Ordner gemäß Plugin-Einstellung
      archived_folder = settings['archive_folder'].presence || 'Archive'
      begin
        imap.select(archived_folder)
      rescue Net::IMAP::NoResponseError
        imap.create(archived_folder)
        imap.select(archived_folder)
      end
      
      # Wechsle zurück zum deferred Ordner
      imap.select(deferred_folder)
      
      expired_count = 0
      expired_mails.each do |mail|
        begin
          # Suche die E-Mail anhand der Message-ID
          search_result = imap.search(['HEADER', 'Message-ID', mail[:message_id]])
          next if search_result.empty?
          
          msg_seq = search_result.first
          
          # Verschiebe die E-Mail zum Archive-Ordner
          imap.move(msg_seq, archived_folder)
          # Entferne gelöschte Nachrichten aus dem Quellordner
          begin
            imap.expunge
          rescue => expunge_err
            Rails.logger.warn("Expunge nach MOVE fehlgeschlagen: #{expunge_err.message}")
          end
          
          expired_count += 1
          
        rescue => e
          Rails.logger.error "Fehler beim Archivieren der E-Mail #{mail[:message_id]}: #{e.message}"
        end
      end
      
      if expired_count > 0
        Rails.logger.info "#{expired_count} abgelaufene E-Mails automatisch archiviert"
        flash[:notice] = "#{expired_count} abgelaufene E-Mails wurden automatisch archiviert."
      end
      
      return expired_count
      
    rescue => e
      Rails.logger.error "Fehler beim automatischen Archivieren: #{e.message}"
      return 0
    ensure
      imap&.disconnect rescue nil
    end
  end

  # Teste IMAP-Verbindung und lade E-Mails neu
  def reload_deferred_mails
    begin
      # Teste IMAP-Verbindung
      imap = @service.connect_to_imap
<<<<<<< HEAD
      if imap
        deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'INBOX.deferred'
        begin
          imap.select(deferred_folder)
          flash[:notice] = "IMAP-Verbindung erfolgreich. Deferred Ordner '#{deferred_folder}' gefunden."
        rescue Net::IMAP::NoResponseError
          flash[:error] = "IMAP-Verbindung erfolgreich, aber deferred Ordner '#{deferred_folder}' nicht gefunden."
        end
        imap.disconnect rescue nil
      else
        flash[:error] = "IMAP-Verbindung fehlgeschlagen. Überprüfen Sie die Plugin-Einstellungen."
=======
    if imap
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      begin
        imap.select(deferred_folder)
        flash[:notice] = "IMAP-Verbindung erfolgreich. Deferred Ordner '#{deferred_folder}' gefunden."
      rescue Net::IMAP::NoResponseError
        flash[:error] = "IMAP-Verbindung erfolgreich, aber deferred Ordner '#{deferred_folder}' nicht gefunden."
>>>>>>> c9355c6b8de98cf1e8f388aa5415d9935223b4f1
      end
      imap.disconnect rescue nil
    else
      flash[:error] = "IMAP-Verbindung fehlgeschlagen. Überprüfen Sie die Plugin-Einstellungen."
    end
    rescue => e
      flash[:error] = "IMAP-Verbindungsfehler: #{e.message}"
    end
    
    redirect_to action: 'deferred_mails'
  end

  # Erstelle Beispiel-Daten für die Anzeige wenn keine echten E-Mails verfügbar sind
  def create_sample_deferred_mails
    [
      {
        id: 1,
        message_id: '<sample1@example.com>',
        from: 'user1@example.com',
        subject: 'Beispiel E-Mail 1 - Zurückgestellt wegen fehlender Berechtigung',
        date: 2.days.ago,
        deferred_at: 2.days.ago,
        expires_at: 28.days.from_now,
        reason: 'Benutzer nicht gefunden',
        expired: false
      },
      {
        id: 2,
        message_id: '<sample2@example.com>',
        from: 'user2@company.com',
        subject: 'Projekt-Update benötigt Admin-Freigabe',
        date: 1.day.ago,
        deferred_at: 1.day.ago,
        expires_at: 29.days.from_now,
        reason: 'Projekt nicht gefunden',
        expired: false
      },
      {
        id: 3,
        message_id: '<sample3@example.com>',
        from: 'external@partner.org',
        subject: 'Externe Anfrage - Benutzer muss erstellt werden',
        date: 3.hours.ago,
        deferred_at: 3.hours.ago,
        expires_at: 29.days.from_now,
        reason: 'Externe E-Mail-Adresse',
        expired: false
      },
      {
        id: 4,
        message_id: '<sample4@example.com>',
        from: 'old-user@example.com',
        subject: 'Abgelaufene E-Mail - sollte archiviert werden',
        date: 35.days.ago,
        deferred_at: 35.days.ago,
        expires_at: 5.days.ago,
        reason: 'Benutzer deaktiviert',
        expired: true
      }
    ]
  end

  def reload_deferred_mails
    init_service
    
    # Teste IMAP-Verbindung
    imap = @service.connect_to_imap
    if imap.nil?
      flash[:error] = 'IMAP-Verbindung fehlgeschlagen. Bitte überprüfen Sie die Plugin-Einstellungen.'
      redirect_to deferred_mails_mail_handler_admin_index_path
      return
    end

    begin
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      
      # Teste ob der deferred Ordner existiert
      begin
        imap.select(deferred_folder)
        flash[:notice] = "IMAP-Verbindung erfolgreich. Deferred-Ordner '#{deferred_folder}' gefunden und verbunden."
      rescue Net::IMAP::NoResponseError => e
        # Liste verfügbare Ordner
        available_folders = []
        begin
          folders = imap.list('', '*')
          available_folders = folders.map(&:name) if folders
        rescue => list_error
          Rails.logger.error("Could not list folders: #{list_error.message}")
        end
        
        if available_folders.any?
          flash[:error] = "Deferred-Ordner '#{deferred_folder}' nicht gefunden. Verfügbare Ordner: #{available_folders.join(', ')}"
        else
          flash[:error] = "Deferred-Ordner '#{deferred_folder}' nicht gefunden und konnte verfügbare Ordner nicht auflisten."
        end
      end
    rescue => e
      flash[:error] = "IMAP-Fehler: #{e.message}"
    ensure
      imap&.disconnect
    end

    redirect_to deferred_mails_mail_handler_admin_index_path
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

  def get_mail_by_message_id(message_id)
    imap = @service.connect_to_imap
    return nil unless imap

    begin
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      
      # Prüfe ob Ordner existiert
      begin
        imap.select(deferred_folder)
      rescue Net::IMAP::NoResponseError
        return nil
      end

      msg_ids = imap.search(['ALL'])

      msg_ids.each do |msg_id|
        begin
          msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
          next if msg_data.blank?

          mail = Mail.read_from_string(msg_data)
          next if mail.nil?

          return mail if mail.message_id == message_id
        rescue => e
          Rails.logger.warn("Failed to process message #{msg_id}: #{e.message}")
          next
        end
      end

      nil
    ensure
      imap&.disconnect
    end
  end

  def get_deferred_mails_from_imap
    Rails.logger.info("=== Starting get_deferred_mails_from_imap ===")
    
    imap = @service.connect_to_imap
    if imap.nil?
      Rails.logger.error("IMAP connection failed - @service.connect_to_imap returned nil")
      @imap_debug_info << "✗ IMAP-Verbindung fehlgeschlagen"
      return []
    end
    Rails.logger.info("IMAP connection successful")

    begin
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      Rails.logger.info("Attempting to connect to deferred folder: '#{deferred_folder}'")
      @imap_debug_info << "ℹ Verbinde mit Ordner: '#{deferred_folder}'"
      
      # Prüfe ob Ordner existiert
      begin
        imap.select(deferred_folder)
        Rails.logger.info("Successfully selected deferred folder: #{deferred_folder}")
        @imap_debug_info << "✓ Ordner erfolgreich ausgewählt"
      rescue Net::IMAP::NoResponseError => e
        Rails.logger.error("Deferred folder not found: #{deferred_folder} - #{e.message}")
        @imap_debug_info << "✗ Ordner nicht gefunden: #{deferred_folder}"
        Rails.logger.info("Available folders:")
        @imap_debug_info << "ℹ Verfügbare Ordner:"
        begin
          folders = imap.list('', '*')
          folders.each do |folder| 
            Rails.logger.info("  - #{folder.name}")
            @imap_debug_info << "  - #{folder.name}"
          end
        rescue => list_error
          Rails.logger.error("Could not list folders: #{list_error.message}")
          @imap_debug_info << "✗ Fehler beim Listen der Ordner: #{list_error.message}"
        end
        return []
      end

      # Hole detaillierte Ordner-Informationen
      begin
        status = imap.status(deferred_folder, ['MESSAGES', 'RECENT', 'UNSEEN'])
        Rails.logger.info("Folder status: #{status}")
        @imap_debug_info << "ℹ Ordner-Status: #{status['MESSAGES']} Nachrichten, #{status['UNSEEN']} ungelesen, #{status['RECENT']} neu"
        
        if status['MESSAGES'] == 0
          @imap_debug_info << "ℹ Ordner ist leer (0 Nachrichten)"
          return []
        end
      rescue => status_error
        Rails.logger.error("Could not get folder status: #{status_error.message}")
        @imap_debug_info << "✗ Konnte Ordner-Status nicht abrufen: #{status_error.message}"
      end

      msg_ids = []
      
      # Versuche verschiedene Suchkriterien um ALLE E-Mails zu finden
      search_criteria_list = [
        ['NOT', 'DELETED'],         # Nicht gelöschte E-Mails zuerst bevorzugen
        ['UNSEEN'],                 # Ungelesene E-Mails
        ['SEEN'],                   # Gelesene E-Mails
        ['ALL'],                    # Alle E-Mails (inkl. \Deleted)
        []                          # Leere Suche (sollte alle zurückgeben)
      ]
      
      @imap_debug_info << "ℹ Versuche verschiedene Suchkriterien..."
      
      search_criteria_list.each do |criteria|
        begin
          if criteria.empty?
            # Versuche alle Message-IDs direkt zu bekommen
            status = imap.status(deferred_folder, ['MESSAGES'])
            total_messages = status['MESSAGES']
            Rails.logger.info("Folder status shows #{total_messages} total messages")
            @imap_debug_info << "ℹ Direkte Methode: #{total_messages} Nachrichten gefunden"
            
            if total_messages > 0
              # Hole alle Message-IDs von 1 bis total_messages
              msg_ids = (1..total_messages).to_a
              Rails.logger.info("Using sequential message IDs: #{msg_ids}")
              @imap_debug_info << "✓ Verwende sequenzielle IDs: #{msg_ids.join(', ')}"
              break
            end
          else
            search_result = imap.search(criteria)
            Rails.logger.info("Search with #{criteria.inspect} found #{search_result.length} messages: #{search_result}")
            @imap_debug_info << "ℹ Suche #{criteria.inspect}: #{search_result.length} Ergebnisse #{search_result.any? ? search_result.join(', ') : ''}"
            
            if search_result.any?
              msg_ids = search_result
              @imap_debug_info << "✓ Erfolgreich mit #{criteria.inspect}"
              break
            end
          end
        rescue => search_error
          Rails.logger.warn("Search with #{criteria.inspect} failed: #{search_error.message}")
          @imap_debug_info << "✗ Suche #{criteria.inspect} fehlgeschlagen: #{search_error.message}"
          next
        end
      end
      
      Rails.logger.info("Final message IDs to process: #{msg_ids}")
      @imap_debug_info << "ℹ Finale Message-IDs zum Verarbeiten: #{msg_ids.join(', ')}"
      
      if msg_ids.empty?
        Rails.logger.error("No messages found with any search criteria!")
        @imap_debug_info << "✗ Keine Nachrichten mit allen Suchkriterien gefunden!"
        # Versuche noch eine alternative Methode
        begin
          # Hole Folder-Informationen
          status = imap.status(deferred_folder, ['MESSAGES', 'RECENT', 'UNSEEN'])
          Rails.logger.info("Folder status: #{status}")
          @imap_debug_info << "ℹ Letzte Chance - Ordner-Status: #{status}"
          
          # Versuche FETCH auf alle möglichen Message-IDs
          if status['MESSAGES'] > 0
            Rails.logger.info("Trying to fetch messages 1 to #{status['MESSAGES']}")
            @imap_debug_info << "ℹ Versuche Nachrichten 1 bis #{status['MESSAGES']} zu holen"
            msg_ids = (1..status['MESSAGES']).to_a
          end
        rescue => status_error
          Rails.logger.error("Could not get folder status: #{status_error.message}")
          @imap_debug_info << "✗ Konnte Ordner-Status nicht abrufen: #{status_error.message}"
        end
      end
      
      if msg_ids.empty?
        Rails.logger.error("Still no messages found after all attempts!")
        @imap_debug_info << "✗ Immer noch keine Nachrichten nach allen Versuchen gefunden!"
        return []
      end
      
      @imap_debug_info << "ℹ Beginne Verarbeitung von #{msg_ids.length} Nachrichten..."
      mails = []

      msg_ids.each do |msg_id|
        begin
          Rails.logger.debug("Processing message ID: #{msg_id}")
          
          # Versuche verschiedene FETCH-Methoden
          msg_data = nil
          fetch_methods = [
            'RFC822',           # Vollständige E-Mail
            'BODY[]',          # E-Mail-Body
            'BODY.PEEK[]'      # E-Mail-Body ohne als gelesen zu markieren
          ]
          
          fetch_methods.each do |method|
            begin
              fetch_result = imap.fetch(msg_id, method)
              if fetch_result && fetch_result[0]
                msg_data = fetch_result[0].attr[method] || fetch_result[0].attr['BODY[]']
                Rails.logger.debug("Successfully fetched message #{msg_id} using #{method}")
                break
              end
            rescue => fetch_error
              Rails.logger.warn("Fetch method #{method} failed for message #{msg_id}: #{fetch_error.message}")
              @imap_debug_info << "✗ FETCH #{method} für Nachricht #{msg_id} fehlgeschlagen: #{fetch_error.message}"
              next
            end
          end
          
          if msg_data.blank?
            Rails.logger.warn("Message #{msg_id} has no data after trying all fetch methods")
            next
          end

          mail = Mail.read_from_string(msg_data)
          if mail.nil?
            Rails.logger.warn("Could not parse mail for message #{msg_id}")
            next
          end

          Rails.logger.info("Successfully processed mail from: #{mail.from&.first}, subject: #{mail.subject}")

          # Hole Deferred-Informationen
          deferred_info = @service.get_mail_deferred_info(mail)
          
          # Fallback für E-Mails ohne deferred Header (manuell verschoben)
          if deferred_info.nil?
            Rails.logger.info("No deferred header found for message #{msg_id}, using fallback values")
            deferred_info = {
              deferred_at: mail.date || Time.current,
              expires_at: (mail.date || Time.current) + 30.days,
              reason: 'manual_defer'
            }
          end
          
          mail_data = {
            id: msg_id,
            message_id: mail.message_id,
            from: mail.from&.first,
            subject: mail.subject,
            date: mail.date,
            deferred_at: deferred_info[:deferred_at],
            expires_at: deferred_info[:expires_at],
            reason: deferred_info[:reason],
            expired: deferred_info ? @service.mail_deferred_expired?(mail) : false
          }
          
          mails << mail_data
          Rails.logger.info("Added mail to list: #{mail_data[:from]} - #{mail_data[:subject]}")
        rescue => e
          Rails.logger.error("Failed to process deferred message #{msg_id}: #{e.message}")
          Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
          @imap_debug_info << "✗ Fehler beim Verarbeiten von Nachricht #{msg_id}: #{e.message}"
          next
        end
      end

      Rails.logger.info("=== Returning #{mails.length} processed mails ===")
      @imap_debug_info << "✓ Erfolgreich #{mails.length} E-Mails verarbeitet und zurückgegeben"
      mails.sort_by { |m| m[:deferred_at] || Time.current }.reverse
    rescue => e
      Rails.logger.error("=== Error in get_deferred_mails_from_imap: #{e.message} ===")
      Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
      @imap_debug_info << "✗ Schwerwiegender Fehler in get_deferred_mails_from_imap: #{e.message}"
      []
    ensure
      imap&.disconnect
    end
  end

  def rescan_selected_mails(selected_ids)
    imap = @service.connect_to_imap
    return 0 unless imap

    begin
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      imap.select(deferred_folder)
      
      processed_count = 0
      
      selected_ids.each do |msg_id|
        begin
          result = @service.process_deferred_message(imap, msg_id.to_i)
          processed_count += 1 if result == :processed
        rescue => e
          Rails.logger.error("Failed to rescan message #{msg_id}: #{e.message}")
        end
      end
      
      processed_count
    ensure
      imap&.disconnect
    end
  end

  # Einfache Archivierungs-Methode ohne komplexe Message-ID Logik
  def archive_selected_mails_simple(selected_ids)
    Rails.logger.info "Starting simple archive for IDs: #{selected_ids.inspect}"
    
    # Initialize settings
    @settings = Setting.plugin_redmine_mail_handler
    
    archived_count = 0
    
    begin
      # IMAP-Verbindung über Service aufbauen
      imap = @service.connect_to_imap
      unless imap
        Rails.logger.error "Could not establish IMAP connection"
        raise "IMAP-Verbindung konnte nicht hergestellt werden"
      end
      
      # Deferred-Ordner auswählen
      imap.select(@settings['deferred_folder'])
      Rails.logger.info "Selected deferred folder: #{@settings['deferred_folder']}"
      
      # Alle Nachrichten im Ordner abrufen
      all_messages = imap.search('ALL')
      Rails.logger.info "Found #{all_messages.length} messages in deferred folder"
      
      # Iteriere durch die ausgewählten IDs (diese sind die Sequenznummern aus der Tabelle)
      selected_ids.each do |sequence_id|
        begin
          seq_num = sequence_id.to_i
          
          # Prüfe ob die Sequenznummer gültig ist
          if seq_num > 0 && seq_num <= all_messages.length
            actual_uid = all_messages[seq_num - 1] # Array ist 0-basiert, Sequenznummern 1-basiert
            
            Rails.logger.info "Archiving message at sequence #{seq_num} (UID: #{actual_uid})"
            
            # Archiviere die Nachricht über den Service
            @service.archive_message(imap, actual_uid)
            archived_count += 1
            
            Rails.logger.info "Successfully archived message #{actual_uid}"
          else
            Rails.logger.warn "Invalid sequence number: #{seq_num} (total messages: #{all_messages.length})"
          end
          
        rescue => e
          Rails.logger.error "Error archiving message #{sequence_id}: #{e.message}"
          # Weiter mit der nächsten Nachricht
        end
      end
      
    ensure
      # IMAP-Verbindung schließen
      if imap
        begin
          imap.disconnect
        rescue => e
          Rails.logger.warn "Error disconnecting IMAP: #{e.message}"
        end
      end
    end
    
    Rails.logger.info "Archive operation completed: #{archived_count} messages archived"
    archived_count
  end

  def get_current_hour_mail_count
    current_hour_start = Time.current.beginning_of_hour
    logs = MailHandlerLogger.read_logs(max_lines: 5000)
    logs.count { |e| e.created_at >= current_hour_start && e.created_at <= Time.current && e.message.include?("[LOAD-BALANCED]") }
  end
  
  def get_next_reset_time
    Time.current.beginning_of_hour + 1.hour
  end

  def test_imap_connection_available
    Rails.logger.info("=== Testing IMAP connection availability ===")
    imap = @service.connect_to_imap
    if imap.nil?
      Rails.logger.error("IMAP connection failed - service returned nil")
      return false
    end
    Rails.logger.info("IMAP connection established successfully")

    begin
      deferred_folder = Setting.plugin_redmine_mail_handler['deferred_folder'] || 'Deferred'
      Rails.logger.info("Testing deferred folder: '#{deferred_folder}'")
      
      imap.select(deferred_folder)
      Rails.logger.info("Successfully selected deferred folder")
      
      # Zusätzliche Informationen über den Ordner
      begin
        status = imap.status(deferred_folder, ['MESSAGES', 'RECENT', 'UNSEEN'])
        Rails.logger.info("Folder status: #{status}")
      rescue => status_error
        Rails.logger.warn("Could not get folder status: #{status_error.message}")
      end
      
      return true
    rescue Net::IMAP::NoResponseError => e
      Rails.logger.error("Deferred folder '#{deferred_folder}' not found: #{e.message}")
      
      # Liste verfügbare Ordner
      begin
        folders = imap.list('', '*')
        if folders
          Rails.logger.info("Available folders:")
          folders.each { |folder| Rails.logger.info("  - #{folder.name}") }
        end
      rescue => list_error
        Rails.logger.error("Could not list folders: #{list_error.message}")
      end
      
      return false
    rescue => e
      Rails.logger.error("IMAP connection test failed: #{e.message}")
      Rails.logger.error("Backtrace: #{e.backtrace.join("\n")}")
      return false
    ensure
      imap&.disconnect
    end
  end

  # Logging-Helfer entfernt
end
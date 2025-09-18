class MailHandlerLogsController < ApplicationController
  before_action :require_admin
  
  def index
    # Paginierung Parameter
    @per_page = params[:per_page].to_i
    @per_page = 50 if @per_page <= 0 || !valid_per_page_options.include?(@per_page)
    @page = [params[:page].to_i, 1].max
    
    # Basis Query
    logs_query = MailHandlerLog.includes([])
                              .by_level(params[:level])
                              .recent
    
    # Journal-Move Filter
    if params[:filter] == 'journal_move'
      logs_query = logs_query.where("message LIKE ?", "%[JOURNAL-MOVE]%")
    end
    
    # Gesamtanzahl für Paginierung
    @total_count = logs_query.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [@page, @total_pages].min if @total_pages > 0
    
    # Logs mit Paginierung laden
    offset = (@page - 1) * @per_page
    @logs = logs_query.limit(@per_page).offset(offset)
    
    @levels = MailHandlerLog.levels
    @selected_level = params[:level]
    @per_page_options = valid_per_page_options
    
    # Statistiken für Dashboard
    @stats = {
      total: MailHandlerLog.count,
      today: MailHandlerLog.today.count,
      this_week: MailHandlerLog.this_week.count,
      by_level: MailHandlerLog.group(:level).count,
      journal_move: {
        total: MailHandlerLog.where("message LIKE ?", "%[JOURNAL-MOVE]%").count,
        today: MailHandlerLog.where("message LIKE ? AND created_at >= ?", "%[JOURNAL-MOVE]%", Date.current.beginning_of_day).count,
        this_week: MailHandlerLog.where("message LIKE ? AND created_at >= ?", "%[JOURNAL-MOVE]%", Date.current.beginning_of_week).count
      }
    }
  end

  def show
    @log = MailHandlerLog.find(params[:id])
  end

  def export
    logs_query = MailHandlerLog.by_level(params[:level]).recent
    
    # Journal-Move Filter für Export
    if params[:filter] == 'journal_move'
      logs_query = logs_query.where("message LIKE ?", "%[JOURNAL-MOVE]%")
    end
    
    @logs = logs_query.limit(1000)
    
    respond_to do |format|
      format.csv do
        csv_data = generate_csv(@logs)
        send_data csv_data, 
                  filename: "mail_handler_logs_#{Date.current.strftime('%Y%m%d')}.csv",
                  type: 'text/csv'
      end
    end
  end

  def move_journal
    journal_id = params[:journal_id]
    target_issue_id = params[:target_issue_id]
    
    Rails.logger.info "[JOURNAL-MOVE] Starting journal move: journal_id=#{journal_id}, target_issue_id=#{target_issue_id}"
    
    if journal_id.blank? || target_issue_id.blank?
      Rails.logger.error "[JOURNAL-MOVE] Parameter fehlen: journal_id=#{journal_id}, target_issue_id=#{target_issue_id}"
      MailHandlerLog.create!(
        level: 'error',
        message: "[JOURNAL-MOVE] Fehler: Fehlende Parameter - journal_id=#{journal_id}, target_issue_id=#{target_issue_id}"
      )
      render json: { success: false, message: 'Journal ID und Target Issue ID sind erforderlich' }
      return
    end
    
    journal = Journal.find_by(id: journal_id)
    target_issue = Issue.find_by(id: target_issue_id)
    
    if journal.nil?
      Rails.logger.error "[JOURNAL-MOVE] Journal nicht gefunden: ID #{journal_id}"
      MailHandlerLog.create!(
        level: 'error',
        message: "[JOURNAL-MOVE] Fehler: Journal ##{journal_id} nicht gefunden"
      )
      render json: { success: false, message: 'Journal nicht gefunden' }
      return
    end
    
    if target_issue.nil?
      Rails.logger.error "[JOURNAL-MOVE] Ziel-Issue nicht gefunden: ID #{target_issue_id}"
      MailHandlerLog.create!(
        level: 'error',
        message: "[JOURNAL-MOVE] Fehler: Ziel-Issue ##{target_issue_id} nicht gefunden"
      )
      render json: { success: false, message: 'Ziel-Issue nicht gefunden' }
      return
    end
    
    # Prüfe ob Journal Kommentar-Text hat
    if journal.notes.blank?
      Rails.logger.warn "[JOURNAL-MOVE] Journal #{journal_id} hat keinen Kommentar-Text - Verschiebung abgelehnt"
      MailHandlerLog.create!(
        level: 'warn',
        message: "[JOURNAL-MOVE] Warnung: Journal ##{journal_id} hat keinen Kommentar-Text - Verschiebung abgelehnt"
      )
      render json: { success: false, message: 'Nur Journals mit Kommentar-Text können verschoben werden' }
      return
    end
    
    Rails.logger.info "[JOURNAL-MOVE] Validierung erfolgreich - starte Verschiebung von Journal #{journal_id} (Issue #{journal.journalized_id}) zu Issue #{target_issue_id}"
    
    # Prüfe Kopier-Modus aus Plugin-Einstellungen
    settings = Setting.plugin_redmine_mail_handler || {}
    copy_mode = settings['journal_move_copy_mode'] == '1'
    
    # Erstelle detaillierten Log-Eintrag vor der Verschiebung
    original_issue = Issue.find_by(id: journal.journalized_id)
    action_text = copy_mode ? "Kopierung" : "Verschiebung"
    MailHandlerLog.create!(
      level: 'info',
      message: "[JOURNAL-MOVE] Starte #{action_text}: Journal ##{journal_id} von Issue ##{journal.journalized_id} (#{original_issue&.subject || 'Unbekannt'}) zu Issue ##{target_issue_id} (#{target_issue.subject})"
    )
    
    result = copy_mode ? perform_copy_journal_move(journal, target_issue) : perform_single_journal_move(journal, target_issue)
    
    if result[:success]
      Rails.logger.info "[JOURNAL-MOVE] Erfolgreich abgeschlossen: Journal #{journal_id} verschoben"
      
      # Detaillierter Erfolgs-Log mit Attachment-Info
      attachment_info = result[:moved_attachments] ? " (#{result[:moved_attachments]} Dateien #{copy_mode ? 'kopiert' : 'verschoben'})" : " (keine Dateien)"
      action_past = copy_mode ? "kopiert" : "verschoben"
      MailHandlerLog.create!(
        level: 'info',
        message: "[JOURNAL-MOVE] Erfolgreich: Journal ##{journal_id} von Issue ##{journal.journalized_id} zu Issue ##{target_issue_id} #{action_past}#{attachment_info}"
      )
      
      render json: { success: true, message: 'Journal und Dateien erfolgreich verschoben' }
    else
      Rails.logger.error "[JOURNAL-MOVE] Fehlgeschlagen: #{result[:error]}"
      
      # Fehler-Log
      MailHandlerLog.create!(
        level: 'error',
        message: "[JOURNAL-MOVE] Fehler: Journal ##{journal_id} konnte nicht verschoben werden - #{result[:error]}"
      )
      
      render json: { success: false, message: result[:error] }
    end
  rescue => e
    Rails.logger.error "[JOURNAL-MOVE] Unerwarteter Fehler: #{e.message}"
    Rails.logger.error "[JOURNAL-MOVE] Backtrace: #{e.backtrace.join("\n")}"
    
    MailHandlerLog.create!(
      level: 'error',
      message: "[JOURNAL-MOVE] Kritischer Fehler: #{e.message} (#{e.class.name})"
    )
    
    render json: { success: false, message: "Fehler beim Verschieben: #{e.message}" }
  end

  private

  def perform_single_journal_move(journal, target_issue)
    Rails.logger.info "[JOURNAL-MOVE] perform_single_journal_move gestartet für Journal #{journal&.id} zu Issue #{target_issue&.id}"
    
    return { success: false, error: 'Journal oder Target Issue fehlt' } unless journal && target_issue
    
    original_issue_id = journal.journalized_id
    Rails.logger.info "[JOURNAL-MOVE] Original Issue ID: #{original_issue_id}, Ziel Issue ID: #{target_issue.id}"
    
    ActiveRecord::Base.transaction do
      Rails.logger.info "[JOURNAL-MOVE] Transaktion gestartet"
      
      # 1. Verschiebe nur diesen einen Kommentar
      original_issue = Issue.find_by(id: original_issue_id)
      Rails.logger.info "[JOURNAL-MOVE] Original Issue gefunden: #{original_issue&.subject || 'Issue nicht gefunden'}"
      
      Rails.logger.info "[JOURNAL-MOVE] Aktualisiere Journal #{journal.id}: journalized_id von #{original_issue_id} zu #{target_issue.id}"
      journal.update!(journalized_id: target_issue.id)
      Rails.logger.info "[JOURNAL-MOVE] Journal erfolgreich verschoben"
      
      # 2. Journal Details werden automatisch mitbewegt (foreign key journal_id bleibt gleich)
      journal_details_count = journal.details.count
      Rails.logger.info "[JOURNAL-MOVE] Journal Details automatisch mitverschoben: #{journal_details_count} Details"
      
      # 3. Finde Attachments die direkt zu diesem Journal gehören
       # Attachments sind über container_type='Journal' und container_id=journal.id verknüpft
       Rails.logger.info "[JOURNAL-MOVE] Suche nach Journal-Attachments für Journal #{journal.id}"
       journal_attachments = Attachment.where(
         container_id: journal.id,
         container_type: 'Journal'
       )
       
       Rails.logger.info "[JOURNAL-MOVE] Gefundene Journal-Attachments: #{journal_attachments.count}"
       
       moved_attachments_count = 0
       
       journal_attachments.each do |attachment|
         Rails.logger.info "[JOURNAL-MOVE] Verarbeite Attachment: #{attachment.filename} (ID: #{attachment.id}) für Journal #{journal.id}"
         
         begin
           # Erstelle eine Kopie des Attachments für das Ziel-Issue
           new_attachment = attachment.dup
           new_attachment.container_id = target_issue.id
           new_attachment.container_type = 'Issue'
           
           Rails.logger.info "[JOURNAL-MOVE] Erstelle neues Attachment für Issue #{target_issue.id}"
           
           if new_attachment.save
             Rails.logger.info "[JOURNAL-MOVE] Neues Attachment gespeichert (ID: #{new_attachment.id})"
             
             # Kopiere die physische Datei
             if File.exist?(attachment.diskfile)
               Rails.logger.info "[JOURNAL-MOVE] Kopiere Datei: #{attachment.diskfile} -> #{new_attachment.diskfile}"
               FileUtils.cp(attachment.diskfile, new_attachment.diskfile)
               Rails.logger.info "[JOURNAL-MOVE] Datei erfolgreich kopiert"
             else
               Rails.logger.warn "[JOURNAL-MOVE] Originaldatei nicht gefunden: #{attachment.diskfile}"
             end
             
             # Entferne das ursprüngliche Attachment
             Rails.logger.info "[JOURNAL-MOVE] Lösche ursprüngliches Attachment #{attachment.id}"
             attachment.destroy
             moved_attachments_count += 1
             Rails.logger.info "[JOURNAL-MOVE] Attachment erfolgreich verschoben: #{attachment.filename}"
           else
             Rails.logger.error "[JOURNAL-MOVE] Fehler beim Speichern des neuen Attachments: #{new_attachment.errors.full_messages.join(', ')}"
             raise "Attachment-Migration fehlgeschlagen: #{new_attachment.errors.full_messages.join(', ')}"
           end
         rescue => attachment_error
           Rails.logger.error "[JOURNAL-MOVE] Fehler bei Attachment #{attachment.filename}: #{attachment_error.message}"
           raise attachment_error
         end
       end
       
       Rails.logger.info "[JOURNAL-MOVE] Attachment-Migration abgeschlossen: #{moved_attachments_count} Attachments verschoben"
        
        Rails.logger.info "[JOURNAL-MOVE] Journal-Move erfolgreich: Journal #{journal.id} mit #{journal_details_count} Details und #{moved_attachments_count} Attachments"
        Rails.logger.info "[JOURNAL-MOVE] Transaktion wird committet"
    end
    
    Rails.logger.info "[JOURNAL-MOVE] perform_single_journal_move erfolgreich abgeschlossen"
    { success: true, moved_attachments: moved_attachments_count }
    
  rescue => e
    Rails.logger.error "[JOURNAL-MOVE] perform_single_journal_move fehlgeschlagen: #{e.message}"
    Rails.logger.error "[JOURNAL-MOVE] Fehler-Details: #{e.class.name}"
    Rails.logger.error "[JOURNAL-MOVE] Backtrace: #{e.backtrace.join("\n")}"
    { success: false, error: e.message }
  end

  def perform_copy_journal_move(journal, target_issue)
    Rails.logger.info "[JOURNAL-MOVE] perform_copy_journal_move gestartet für Journal #{journal&.id} zu Issue #{target_issue&.id}"
    
    return { success: false, error: 'Journal oder Target Issue fehlt' } unless journal && target_issue
    
    # MailHandlerLog für Start der Kopierung
    delete_original = Setting.plugin_redmine_mail_handler['journal_copy_delete_original'] == '1'
    action_text = delete_original ? "kopiert und Original gelöscht" : "kopiert"
    MailHandlerLog.create!(
      level: 'info',
      message: "Journal-Kopierung gestartet: Journal #{journal.id} wird zu Issue #{target_issue.id} #{action_text}",
      details: {
        journal_id: journal.id,
        source_issue_id: journal.journalized_id,
        target_issue_id: target_issue.id,
        delete_original: delete_original,
        action: 'copy_start'
      }.to_json
    )
    
    original_issue_id = journal.journalized_id
    Rails.logger.info "[JOURNAL-MOVE] Original Issue ID: #{original_issue_id}, Ziel Issue ID: #{target_issue.id}"
    
    copied_attachments_count = 0
    
    ActiveRecord::Base.transaction do
      Rails.logger.info "[JOURNAL-MOVE] Transaktion gestartet für Kopierung"
      
      # 1. Erstelle eine Kopie des Journals
      original_issue = Issue.find_by(id: original_issue_id)
      Rails.logger.info "[JOURNAL-MOVE] Original Issue gefunden: #{original_issue&.subject || 'Issue nicht gefunden'}"
      
      Rails.logger.info "[JOURNAL-MOVE] Erstelle Journal-Kopie für Issue #{target_issue.id}"
      new_journal = Journal.new(
        journalized_id: target_issue.id,
        journalized_type: 'Issue',
        user_id: journal.user_id,
        notes: journal.notes,
        created_on: Time.current
      )
      
      new_journal.save!
      Rails.logger.info "[JOURNAL-MOVE] Journal-Kopie erstellt mit ID #{new_journal.id}"
      
      # 2. Kopiere Journal Details
      journal.details.each do |detail|
        new_detail = JournalDetail.new(
          journal_id: new_journal.id,
          property: detail.property,
          prop_key: detail.prop_key,
          old_value: detail.old_value,
          value: detail.value
        )
        new_detail.save!
        Rails.logger.info "[JOURNAL-MOVE] Journal Detail kopiert: #{detail.property}"
      end
      
      journal_details_count = journal.details.count
      Rails.logger.info "[JOURNAL-MOVE] Journal Details kopiert: #{journal_details_count} Details"
      
      # 3. Kopiere Attachments die direkt zu diesem Journal gehören
      Rails.logger.info "[JOURNAL-MOVE] Suche nach Journal-Attachments für Journal #{journal.id}"
      journal_attachments = Attachment.where(
        container_id: journal.id,
        container_type: 'Journal'
      )
      
      Rails.logger.info "[JOURNAL-MOVE] Gefundene Journal-Attachments: #{journal_attachments.count}"
      
      journal_attachments.each do |attachment|
        Rails.logger.info "[JOURNAL-MOVE] Kopiere Attachment: #{attachment.filename} (ID: #{attachment.id}) für neues Journal #{new_journal.id}"
        
        begin
          # Erstelle eine Kopie des Attachments für das neue Journal
          new_attachment = attachment.dup
          new_attachment.container_id = new_journal.id
          new_attachment.container_type = 'Journal'
          
          Rails.logger.info "[JOURNAL-MOVE] Erstelle neues Attachment für Journal #{new_journal.id}"
          
          if new_attachment.save
            Rails.logger.info "[JOURNAL-MOVE] Neues Attachment gespeichert (ID: #{new_attachment.id})"
            
            # Kopiere die physische Datei
            if File.exist?(attachment.diskfile)
              Rails.logger.info "[JOURNAL-MOVE] Kopiere Datei: #{attachment.diskfile} -> #{new_attachment.diskfile}"
              FileUtils.cp(attachment.diskfile, new_attachment.diskfile)
              Rails.logger.info "[JOURNAL-MOVE] Datei erfolgreich kopiert"
            else
              Rails.logger.warn "[JOURNAL-MOVE] Originaldatei nicht gefunden: #{attachment.diskfile}"
            end
            
            copied_attachments_count += 1
            Rails.logger.info "[JOURNAL-MOVE] Attachment erfolgreich kopiert: #{attachment.filename}"
          else
            Rails.logger.error "[JOURNAL-MOVE] Fehler beim Speichern des neuen Attachments: #{new_attachment.errors.full_messages.join(', ')}"
            raise "Attachment-Kopierung fehlgeschlagen: #{new_attachment.errors.full_messages.join(', ')}"
          end
        rescue => attachment_error
          Rails.logger.error "[JOURNAL-MOVE] Fehler bei Attachment #{attachment.filename}: #{attachment_error.message}"
          raise attachment_error
        end
      end
      
      Rails.logger.info "[JOURNAL-MOVE] Attachment-Kopierung abgeschlossen: #{copied_attachments_count} Attachments kopiert"
      
      Rails.logger.info "[JOURNAL-MOVE] Journal-Kopierung erfolgreich: Journal #{journal.id} kopiert zu Journal #{new_journal.id} mit #{journal_details_count} Details und #{copied_attachments_count} Attachments"
    
    # Prüfe ob Original-Journal gelöscht werden soll
    delete_original = Setting.plugin_redmine_mail_handler['journal_copy_delete_original'] == '1'
    Rails.logger.info "[JOURNAL-MOVE] Original-Journal löschen: #{delete_original}"
    
    if delete_original
      Rails.logger.info "[JOURNAL-MOVE] Lösche Original-Journal #{journal.id} und zugehörige Attachments"
      
      # Lösche Journal-Attachments
      journal_attachments.each do |attachment|
        Rails.logger.info "[JOURNAL-MOVE] Lösche Original-Attachment: #{attachment.filename} (ID: #{attachment.id})"
        
        # Lösche physische Datei
        if File.exist?(attachment.diskfile)
          File.delete(attachment.diskfile)
          Rails.logger.info "[JOURNAL-MOVE] Physische Datei gelöscht: #{attachment.diskfile}"
        end
        
        # Lösche Attachment-Eintrag
        attachment.destroy
        Rails.logger.info "[JOURNAL-MOVE] Attachment-Eintrag gelöscht: #{attachment.filename}"
      end
      
      # Lösche Journal Details
      journal.details.destroy_all
      Rails.logger.info "[JOURNAL-MOVE] Journal Details gelöscht: #{journal_details_count} Details"
      
      # Lösche Journal
      journal.destroy
      Rails.logger.info "[JOURNAL-MOVE] Original-Journal gelöscht: #{journal.id}"
    end
    
    Rails.logger.info "[JOURNAL-MOVE] Transaktion wird committet"
    end
    
    Rails.logger.info "[JOURNAL-MOVE] perform_copy_journal_move erfolgreich abgeschlossen"
    
    # MailHandlerLog für erfolgreiche Kopierung
    delete_original = Setting.plugin_redmine_mail_handler['journal_copy_delete_original'] == '1'
    action_text = delete_original ? "kopiert und Original gelöscht" : "kopiert"
    attachment_info = copied_attachments_count > 0 ? " (#{copied_attachments_count} Attachments #{action_text})" : " (keine Attachments)"
    MailHandlerLog.create!(
      level: 'info',
      message: "Journal erfolgreich #{action_text}: Journal #{journal.id} zu Issue #{target_issue.id}#{attachment_info}",
      details: {
        journal_id: journal.id,
        source_issue_id: journal.journalized_id,
        target_issue_id: target_issue.id,
        copied_attachments: copied_attachments_count,
        delete_original: delete_original,
        action: 'copy_success'
      }.to_json
    )
    
    { success: true, moved_attachments: copied_attachments_count }
    
  rescue => e
    Rails.logger.error "[JOURNAL-MOVE] perform_copy_journal_move fehlgeschlagen: #{e.message}"
    Rails.logger.error "[JOURNAL-MOVE] Fehler-Details: #{e.class.name}"
    Rails.logger.error "[JOURNAL-MOVE] Backtrace: #{e.backtrace.join("\n")}"
    
    # MailHandlerLog für Fehler bei Kopierung
    MailHandlerLog.create!(
      level: 'error',
      message: "Journal-Kopierung fehlgeschlagen: #{e.message}",
      details: {
        journal_id: journal&.id,
        source_issue_id: journal&.journalized_id,
        target_issue_id: target_issue&.id,
        error_class: e.class.name,
        error_message: e.message,
        action: 'copy_error'
      }.to_json
    )
    
    { success: false, error: e.message }
  end

  def perform_manual_journal_move(journal, target_issue)
    return false unless journal && target_issue
    
    original_issue_id = journal.journalized_id
    moved_journals = 0
    moved_attachments = 0
    
    ActiveRecord::Base.transaction do
      # 1. Verschiebe alle Journals (Kommentare) des ursprünglichen Issues
      journals = Journal.where(journalized_id: original_issue_id, journalized_type: 'Issue')
      
      journals.find_each do |j|
        # Update journalized_id zum neuen Issue
        j.update!(journalized_id: target_issue.id)
        moved_journals += 1
        
        # Journal Details werden automatisch mitbewegt (foreign key journal_id bleibt gleich)
        Rails.logger.info "Moved journal #{j.id} from issue #{original_issue_id} to #{target_issue.id}"
      end
      
      # 2. Verschiebe alle direkten Issue-Anhänge
      issue_attachments = Attachment.where(container_id: original_issue_id, container_type: 'Issue')
      
      issue_attachments.find_each do |attachment|
        attachment.update!(container_id: target_issue.id)
        moved_attachments += 1
        Rails.logger.info "Moved issue attachment #{attachment.filename} from issue #{original_issue_id} to #{target_issue.id}"
      end
      
      # 3. Anhänge die an Journals hängen werden automatisch mitbewegt,
      # da sie über container_type='Journal' und container_id=journal.id verknüpft sind
      journal_attachments = Attachment.joins(
        "INNER JOIN journals ON attachments.container_id = journals.id AND attachments.container_type = 'Journal'"
      ).where(
        journals: { journalized_id: target_issue.id, journalized_type: 'Issue' }
      )
      
      Rails.logger.info "Journal attachments automatically moved: #{journal_attachments.count}"
    end
    
    Rails.logger.info "Successfully moved #{moved_journals} journals and #{moved_attachments} attachments from issue #{original_issue_id} to #{target_issue.id}"
    true
    
  rescue => e
    Rails.logger.error "Manual journal move failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    false
  end



  def valid_per_page_options
    [10, 20, 50, 100, 200]
  end

  def generate_csv(logs)
    require 'csv'
    
    CSV.generate(headers: true) do |csv|
      csv << ['Zeitstempel', 'Level', 'Nachricht']
      
      logs.each do |log|
        csv << [log.formatted_time, log.level, log.message]
      end
    end
  end
end
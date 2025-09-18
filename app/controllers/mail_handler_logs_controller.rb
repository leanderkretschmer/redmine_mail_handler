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
      by_level: MailHandlerLog.group(:level).count
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
      render json: { success: false, message: 'Journal ID und Target Issue ID sind erforderlich' }
      return
    end
    
    journal = Journal.find_by(id: journal_id)
    target_issue = Issue.find_by(id: target_issue_id)
    
    if journal.nil?
      Rails.logger.error "[JOURNAL-MOVE] Journal nicht gefunden: ID #{journal_id}"
      render json: { success: false, message: 'Journal nicht gefunden' }
      return
    end
    
    if target_issue.nil?
      Rails.logger.error "[JOURNAL-MOVE] Ziel-Issue nicht gefunden: ID #{target_issue_id}"
      render json: { success: false, message: 'Ziel-Issue nicht gefunden' }
      return
    end
    
    # Prüfe ob Journal Kommentar-Text hat
    if journal.notes.blank?
      Rails.logger.warn "[JOURNAL-MOVE] Journal #{journal_id} hat keinen Kommentar-Text - Verschiebung abgelehnt"
      render json: { success: false, message: 'Nur Journals mit Kommentar-Text können verschoben werden' }
      return
    end
    
    Rails.logger.info "[JOURNAL-MOVE] Validierung erfolgreich - starte Verschiebung von Journal #{journal_id} (Issue #{journal.journalized_id}) zu Issue #{target_issue_id}"
    
    result = perform_single_journal_move(journal, target_issue)
    
    if result[:success]
      Rails.logger.info "[JOURNAL-MOVE] Erfolgreich abgeschlossen: Journal #{journal_id} verschoben"
      render json: { success: true, message: 'Journal und Dateien erfolgreich verschoben' }
    else
      Rails.logger.error "[JOURNAL-MOVE] Fehlgeschlagen: #{result[:error]}"
      render json: { success: false, message: result[:error] }
    end
  rescue => e
    Rails.logger.error "[JOURNAL-MOVE] Unerwarteter Fehler: #{e.message}"
    Rails.logger.error "[JOURNAL-MOVE] Backtrace: #{e.backtrace.join("\n")}"
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
    { success: true }
    
  rescue => e
    Rails.logger.error "[JOURNAL-MOVE] perform_single_journal_move fehlgeschlagen: #{e.message}"
    Rails.logger.error "[JOURNAL-MOVE] Fehler-Details: #{e.class.name}"
    Rails.logger.error "[JOURNAL-MOVE] Backtrace: #{e.backtrace.join("\n")}"
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
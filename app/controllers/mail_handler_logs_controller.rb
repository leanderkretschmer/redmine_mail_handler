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
    @logs = MailHandlerLog.by_level(params[:level]).recent.limit(1000)
    
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
    
    if journal_id.blank? || target_issue_id.blank?
      render json: { success: false, message: 'Journal ID und Target Issue ID sind erforderlich' }
      return
    end
    
    journal = Journal.find_by(id: journal_id)
    target_issue = Issue.find_by(id: target_issue_id)
    
    if journal.nil?
      render json: { success: false, message: 'Journal nicht gefunden' }
      return
    end
    
    if target_issue.nil?
      render json: { success: false, message: 'Ziel-Issue nicht gefunden' }
      return
    end
    
    # Prüfe ob Journal Kommentar-Text hat
    if journal.notes.blank?
      render json: { success: false, message: 'Nur Journals mit Kommentar-Text können verschoben werden' }
      return
    end
    
    result = perform_single_journal_move(journal, target_issue)
    
    if result[:success]
      render json: { success: true, message: 'Journal und Dateien erfolgreich verschoben' }
    else
      render json: { success: false, message: result[:error] }
    end
  rescue => e
    Rails.logger.error "Fehler beim Journal-Move: #{e.message}\n#{e.backtrace.join("\n")}"
    render json: { success: false, message: "Fehler beim Verschieben: #{e.message}" }
  end

  private

  def perform_single_journal_move(journal, target_issue)
    return { success: false, error: 'Journal oder Target Issue fehlt' } unless journal && target_issue
    
    ActiveRecord::Base.transaction do
      # 1. Verschiebe nur diesen einen Kommentar
      original_issue_id = journal.journalized_id
      original_issue = Issue.find_by(id: original_issue_id)
      journal.update!(journalized_id: target_issue.id)
      
      Rails.logger.info "Moved single journal #{journal.id} from issue #{original_issue_id} to #{target_issue.id}"
      
      # 2. Journal Details werden automatisch mitbewegt (foreign key journal_id bleibt gleich)
      journal_details_count = journal.details.count
      Rails.logger.info "Journal details automatically moved: #{journal_details_count}"
      
      # 3. Finde spezifische Attachments die zu diesem Journal gehören
      # Über journal_details.prop_key -> attachments.id Verknüpfung
      journal_specific_attachments = []
      
      # Durchsuche journal_details nach attachment-bezogenen Einträgen
      journal.details.each do |detail|
        if detail.prop_key == 'attachment' && detail.value.present?
          # prop_key 'attachment' und value enthält die attachment_id
          attachment_id = detail.value.to_i
          attachment = Attachment.find_by(id: attachment_id)
          if attachment
            journal_specific_attachments << attachment
            Rails.logger.info "Found journal-specific attachment: #{attachment.filename} (ID: #{attachment_id})"
          end
        end
      end
      
      # 4. Verschiebe nur die spezifisch zu diesem Journal gehörenden Attachments
      moved_attachments_count = 0
      
      journal_specific_attachments.each do |attachment|
        # Erstelle eine Kopie des Attachments für das Ziel-Issue
        new_attachment = attachment.dup
        new_attachment.container_id = target_issue.id
        new_attachment.container_type = 'Issue'
        
        if new_attachment.save
          # Kopiere die physische Datei
          if File.exist?(attachment.diskfile)
            FileUtils.cp(attachment.diskfile, new_attachment.diskfile)
            Rails.logger.info "Copied attachment file: #{attachment.filename} to issue #{target_issue.id}"
          end
          
          # Entferne das ursprüngliche Attachment
          attachment.destroy
          moved_attachments_count += 1
          Rails.logger.info "Moved journal-specific attachment: #{attachment.filename} from issue #{original_issue_id} to #{target_issue.id}"
        else
          Rails.logger.error "Failed to move attachment: #{attachment.filename} - #{new_attachment.errors.full_messages.join(', ')}"
          raise "Attachment-Migration fehlgeschlagen: #{new_attachment.errors.full_messages.join(', ')}"
        end
      end
      
      Rails.logger.info "Successfully moved #{moved_attachments_count} journal-specific attachments from issue #{original_issue_id} to #{target_issue.id}"
       
       Rails.logger.info "Successfully moved journal #{journal.id} with #{journal_details_count} details and #{moved_attachments_count} journal-specific attachments"
    end
    
    { success: true }
    
  rescue => e
    Rails.logger.error "Single journal move failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
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
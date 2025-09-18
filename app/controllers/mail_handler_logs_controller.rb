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
    
    if journal_id.present? && target_issue_id.present?
      journal = Journal.find_by(id: journal_id)
      target_issue = Issue.find_by(id: target_issue_id)
      
      if journal && target_issue
        # Finde den Log-Eintrag für dieses Journal
        log_entry = find_log_entry_for_journal(journal)
        
        if log_entry && log_entry.mail_message_id.present?
          # Versuche Mail aus Archiv zu re-importieren
          success = reimport_mail_from_archive(log_entry.mail_message_id, target_issue_id)
          
          if success
            # Lösche das alte Journal nach erfolgreichem Re-Import
            journal.destroy
            render json: { success: true, message: 'Mail erfolgreich aus Archiv re-importiert und Journal verschoben' }
          else
            # Fallback: Normale Journal-Verschiebung
            perform_manual_journal_move(journal, target_issue)
            render json: { success: true, message: 'Journal verschoben (Archiv-Import fehlgeschlagen, manuelle Verschiebung durchgeführt)' }
          end
        else
          # Fallback: Normale Journal-Verschiebung
          perform_manual_journal_move(journal, target_issue)
          render json: { success: true, message: 'Journal und Dateien erfolgreich verschoben' }
        end
      else
        render json: { success: false, message: 'Journal oder Ziel-Issue nicht gefunden' }
      end
    else
      render json: { success: false, message: 'Fehlende Parameter' }
    end
  end

  private

  def find_log_entry_for_journal(journal)
    # Suche Log-Eintrag basierend auf Zeitstempel und Ticket-ID
    # Journal created_on ist normalerweise sehr nah am Log-Zeitstempel
    time_range = (journal.created_on - 5.minutes)..(journal.created_on + 5.minutes)
    
    MailHandlerLog.where(
      ticket_id: journal.journalized_id,
      created_at: time_range
    ).where.not(mail_message_id: nil).first
  end
  
  def reimport_mail_from_archive(message_id, target_issue_id)
    begin
      service = MailHandlerService.new
      
      # Verbinde zu IMAP und suche Mail im Archiv
      imap = service.send(:connect_to_imap)
      return false unless imap
      
      settings = Setting.plugin_redmine_mail_handler
      archive_folder = settings['archive_folder']
      return false unless archive_folder.present?
      
      # Wähle Archiv-Ordner
      begin
        imap.select(archive_folder)
      rescue Net::IMAP::NoResponseError
        imap.disconnect
        return false
      end
      
      # Suche Mail anhand Message-ID
      message_ids = imap.search(['HEADER', 'Message-ID', message_id])
      
      if message_ids.empty?
        imap.disconnect
        return false
      end
      
      # Hole Mail-Daten
      msg_id = message_ids.first
      msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
      mail = Mail.read_from_string(msg_data)
      
      imap.disconnect
      
      # Finde Benutzer
      from_address = mail.from&.first
      return false unless from_address
      
      user = service.send(:find_existing_user, from_address)
      return false unless user
      
      # Re-importiere Mail zum neuen Ticket
      service.send(:add_mail_to_ticket, mail, target_issue_id, user)
      
      return true
      
    rescue => e
      Rails.logger.error "Failed to reimport mail from archive: #{e.message}"
      return false
    end
  end
  
  def perform_manual_journal_move(journal, target_issue)
    # Ursprüngliche Issue-ID speichern für Attachment-Verschiebung
    original_issue_id = journal.journalized_id
    original_issue = Issue.find_by(id: original_issue_id)
    
    # Journal verschieben
    journal.update(journalized_id: target_issue.id)
    
    # Attachments verschieben
    if original_issue
      original_issue.attachments.each do |attachment|
        attachment.update(container: target_issue)
      end
    end
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
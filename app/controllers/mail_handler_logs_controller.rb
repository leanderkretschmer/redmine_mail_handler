class MailHandlerLogsController < ApplicationController
  before_action :require_admin
  before_action :check_comment_move_enabled, only: [:search_tickets, :search_author_tickets, :move_comment]
  
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

  # API für Live-Suche nach Tickets
  def search_tickets
    query = params[:query].to_s.strip
    
    if query.blank?
      render json: { tickets: [] }
      return
    end
    
    # Suche nach Ticket-Titel
    tickets = Issue.visible
                   .where("subject LIKE ?", "%#{query}%")
                   .limit(5)
                   .select(:id, :subject, :status_id)
                   .includes(:status)
    
    results = tickets.map do |ticket|
      {
        id: ticket.id,
        subject: ticket.subject,
        status: ticket.status.name
      }
    end
    
    render json: { tickets: results }
  end
  
  # API für Autorenvorschläge
  def search_author_tickets
    journal_id = params[:journal_id].to_i
    
    journal = Journal.find_by(id: journal_id)
    unless journal
      render json: { tickets: [] }
      return
    end
    
    author = journal.user
    
    # Finde Tickets, in denen der Autor kommentiert hat (außer dem aktuellen)
    tickets = Issue.joins(:journals)
                   .where(journals: { user_id: author.id })
                   .where.not(id: journal.journalized_id)
                   .distinct
                   .limit(5)
                   .select(:id, :subject, :status_id)
                   .includes(:status)
    
    results = tickets.map do |ticket|
      {
        id: ticket.id,
        subject: ticket.subject,
        status: ticket.status.name
      }
    end
    
    render json: { tickets: results }
  end
  
  # API für Kommentar-Verschiebung
  def move_comment
    journal_id = params[:journal_id].to_i
    target_issue_id = params[:target_issue_id].to_i
    
    journal = Journal.find_by(id: journal_id)
    target_issue = Issue.find_by(id: target_issue_id)
    
    unless journal && target_issue
      render json: { 
        success: false, 
        error: 'Journal oder Ziel-Ticket nicht gefunden' 
      }
      return
    end
    
    # Prüfe ob Journal einen Kommentar hat
    if journal.notes.blank?
      render json: { 
        success: false, 
        error: 'Journal hat keinen Kommentar zum Verschieben' 
      }
      return
    end
    
    begin
      ActiveRecord::Base.transaction do
        # Erstelle neues Journal im Ziel-Ticket
        new_journal = Journal.create!(
          journalized: target_issue,
          user: journal.user,
          notes: journal.notes,
          created_on: journal.created_on
        )
        
        # Verschiebe Anhänge
        journal.details.where(property: 'attachment').each do |detail|
          attachment = Attachment.find_by(id: detail.value)
          if attachment
            attachment.update!(container: target_issue)
            
            # Erstelle Detail-Eintrag für neues Journal
            JournalDetail.create!(
              journal: new_journal,
              property: 'attachment',
              prop_key: detail.prop_key,
              old_value: detail.old_value,
              value: detail.value
            )
          end
        end
        
        # Lösche altes Journal
        journal.destroy!
        
        # Log erstellen
        MailHandlerLog.create!(
          level: 'info',
          message: "[COMMENT-MOVE] Kommentar erfolgreich von Ticket ##{journal.journalized_id} zu Ticket ##{target_issue_id} verschoben",
          details: {
            journal_id: journal_id,
            target_issue_id: target_issue_id,
            user_id: journal.user_id,
            moved_by: User.current.id
          }.to_json
        )
      end
      
      render json: { 
        success: true, 
        message: 'Kommentar erfolgreich verschoben' 
      }
      
    rescue => e
      MailHandlerLog.create!(
        level: 'error',
        message: "[COMMENT-MOVE] Fehler beim Verschieben: #{e.message}",
        details: {
          journal_id: journal_id,
          target_issue_id: target_issue_id,
          error: e.message
        }.to_json
      )
      
      render json: { 
        success: false, 
        error: "Fehler beim Verschieben: #{e.message}" 
      }
    end
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

  private

  def check_comment_move_enabled
    unless Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
      render json: { success: false, error: 'Kommentar-Verschiebung ist nicht aktiviert' }
      return false
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
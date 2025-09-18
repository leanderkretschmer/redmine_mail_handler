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
        # Ursprüngliche Issue-ID speichern
        original_issue_id = journal.journalized_id
        
        # Journal verschieben
        journal.update(journalized_id: target_issue_id)
        
        # Attachments des ursprünglichen Issues finden und verschieben
        original_issue = Issue.find_by(id: original_issue_id)
        if original_issue
          # Alle Attachments des ursprünglichen Issues zum Ziel-Issue verschieben
          original_issue.attachments.each do |attachment|
            attachment.update(container: target_issue)
          end
        end
        
        render json: { success: true, message: 'Journal und Attachments erfolgreich verschoben' }
      else
        render json: { success: false, message: 'Journal oder Ziel-Issue nicht gefunden' }
      end
    else
      render json: { success: false, message: 'Fehlende Parameter' }
    end
  end

  private

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
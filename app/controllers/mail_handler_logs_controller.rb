class MailHandlerLogsController < ApplicationController
  before_action :require_admin
  
  def index
    # Paginierung Parameter
    @per_page = params[:per_page].to_i
    @per_page = 50 if @per_page <= 0 || !valid_per_page_options.include?(@per_page)
    @page = [params[:page].to_i, 1].max
    
    # Basis Query (geordnet, ggf. gefiltert)
    logs_query = MailHandlerLog.by_level(params[:level]).recent
    
    # Gruppiere aufeinanderfolgende identische Logs (Level + Message)
    grouped = group_consecutive_logs(logs_query)

    # Gesamtanzahl nach Gruppierung
    @total_count = grouped.length
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [@page, @total_pages].min if @total_pages > 0

    # Paginierung über Gruppen
    offset = (@page - 1) * @per_page
    @logs = grouped.slice(offset, @per_page) || []
    
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
  # Baut gruppierte Log-Objekte (aufeinanderfolgende identische Einträge)
  def group_consecutive_logs(relation)
    require 'ostruct'

    raw_logs = relation.to_a # bereits sortiert: neueste zuerst
    groups = []
    current = nil

    raw_logs.each do |log|
      if current && log.level == current[:level] && log.message == current[:message]
        current[:count] += 1
        current[:min_time] = log.created_at if log.created_at < current[:min_time]
        current[:max_time] = log.created_at if log.created_at > current[:max_time]
        current[:last_id] = log.id
      else
        groups << current if current
        current = {
          level: log.level,
          message: log.message,
          count: 1,
          min_time: log.created_at,
          max_time: log.created_at,
          first_id: log.id,
          last_id: log.id
        }
      end
    end
    groups << current if current

    # Mappe zu View-Objekten mit benötigten Methoden
    groups.map do |g|
      OpenStruct.new(
        id: g[:first_id],
        level: g[:level],
        level_icon: level_icon_for(g[:level]),
        level_color: level_color_for(g[:level]),
        message: g[:count] > 1 ? "#{g[:message]} (x#{g[:count]})" : g[:message],
        has_mail_details?: false,
        formatted_time: formatted_time_range(g[:min_time], g[:max_time], g[:count])
      )
    end
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
class LogsController < ApplicationController
  before_action :require_admin
  
  def index
    @log_files = get_log_files
    @selected_file = params[:file] || 'all'
    @logs = read_logs(@selected_file)
  end

  def settings
    @settings = Setting.plugin_redmine_mail_handler
  end

  def update_settings
    settings = params[:settings] || {}
    current_settings = Setting.plugin_redmine_mail_handler
    updated_settings = current_settings.merge(settings)
    
    Setting.plugin_redmine_mail_handler = updated_settings
    
    flash[:notice] = 'Log-Einstellungen wurden erfolgreich gespeichert.'
    redirect_to action: 'settings'
  end

  def clear
    clear_all_logs
    flash[:notice] = 'Alle Log-Dateien wurden gelöscht.'
    redirect_to action: 'index'
  end

  def cleanup
    cleanup_old_logs
    flash[:notice] = 'Alte Log-Einträge wurden bereinigt.'
    redirect_to action: 'index'
  end

  def export
    format = params[:format] || 'csv'
    file = params[:file] || 'all'
    
    if format == 'csv'
      send_data generate_csv_data(file), 
                filename: "mail_handler_logs_#{Date.current}.csv",
                type: 'text/csv'
    else
      send_data generate_txt_data(file),
                filename: "mail_handler_logs_#{Date.current}.txt", 
                type: 'text/plain'
    end
  end

  private

  def get_log_files
    log_dir = Rails.root.join('log')
    files = Dir.glob(log_dir.join('redmine_mail_handler*.log')).map do |file|
      {
        name: File.basename(file, '.log').gsub('redmine_mail_handler_', '').gsub('redmine_mail_handler', 'general'),
        path: file,
        size: File.size(file),
        modified: File.mtime(file)
      }
    end
    files.sort_by { |f| f[:modified] }.reverse
  end

  def read_logs(file_filter)
    logs = []
    log_files = get_log_files
    
    if file_filter == 'all'
      log_files.each do |file_info|
        logs.concat(read_single_log_file(file_info[:path], file_info[:name]))
      end
    else
      file_info = log_files.find { |f| f[:name] == file_filter }
      if file_info
        logs = read_single_log_file(file_info[:path], file_info[:name])
      end
    end
    
    logs.sort_by { |log| log[:timestamp] }.reverse.first(1000)
  end

  def read_single_log_file(file_path, file_type)
    return [] unless File.exist?(file_path)
    
    logs = []
    File.readlines(file_path).each do |line|
      next if line.strip.empty?
      
      # Parse log line format: [TIMESTAMP] LEVEL: MESSAGE
      if match = line.match(/\[([^\]]+)\]\s+(\w+):\s+(.+)/)
        logs << {
          timestamp: Time.parse(match[1]) rescue Time.current,
          level: match[2],
          message: match[3].strip,
          file: file_type
        }
      end
    end
    
    logs
  rescue => e
    Rails.logger.error "Error reading log file #{file_path}: #{e.message}"
    []
  end

  def clear_all_logs
    log_dir = Rails.root.join('log')
    Dir.glob(log_dir.join('redmine_mail_handler*.log')).each do |file|
      File.delete(file) if File.exist?(file)
    end
  end

  def cleanup_old_logs
    settings = Setting.plugin_redmine_mail_handler
    return unless settings['log_cleanup_enabled'] == '1'
    
    method = settings['log_cleanup_method'] || 'count'
    
    if method == 'days'
      cleanup_by_age(settings['log_retention_days'].to_i)
    else
      cleanup_by_count(settings['log_max_entries'].to_i)
    end
  end

  def cleanup_by_age(days)
    cutoff_date = days.days.ago
    log_files = get_log_files
    
    log_files.each do |file_info|
      next unless File.exist?(file_info[:path])
      
      lines = File.readlines(file_info[:path])
      filtered_lines = lines.select do |line|
        if match = line.match(/\[([^\]]+)\]/)
          timestamp = Time.parse(match[1]) rescue Time.current
          timestamp > cutoff_date
        else
          true # Keep lines that don't match the expected format
        end
      end
      
      File.write(file_info[:path], filtered_lines.join)
    end
  end

  def cleanup_by_count(max_entries)
    log_files = get_log_files
    
    log_files.each do |file_info|
      next unless File.exist?(file_info[:path])
      
      lines = File.readlines(file_info[:path])
      if lines.length > max_entries
        File.write(file_info[:path], lines.last(max_entries).join)
      end
    end
  end

  def generate_csv_data(file_filter)
    require 'csv'
    
    logs = read_logs(file_filter)
    
    CSV.generate do |csv|
      csv << ['Timestamp', 'Level', 'File', 'Message']
      logs.each do |log|
        csv << [log[:timestamp], log[:level], log[:file], log[:message]]
      end
    end
  end

  def generate_txt_data(file_filter)
    logs = read_logs(file_filter)
    
    logs.map do |log|
      "[#{log[:timestamp]}] #{log[:level]} (#{log[:file]}): #{log[:message]}"
    end.join("\n")
  end
end
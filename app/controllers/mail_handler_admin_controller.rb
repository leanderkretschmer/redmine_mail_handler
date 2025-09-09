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

  private

  def init_service
    @service = MailHandlerService.new
  end
end
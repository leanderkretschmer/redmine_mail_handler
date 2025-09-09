class DeferredScheduler
  def self.schedule_deferred_processing
    return unless Setting.plugin_redmine_mail_handler['deferred_recheck_time'].present?

    recheck_time = Setting.plugin_redmine_mail_handler['deferred_recheck_time']
    
    # Parse Zeit (Format: "HH:MM")
    begin
      hour, minute = recheck_time.split(':').map(&:to_i)
      
      # Berechne nächste Ausführungszeit
      now = Time.current
      next_run = now.beginning_of_day + hour.hours + minute.minutes
      
      # Wenn die Zeit heute schon vorbei ist, plane für morgen
      next_run += 1.day if next_run <= now
      
      Rails.logger.info("Scheduling deferred processing for #{next_run}")
      
      # Verwende delayed_job oder sidekiq falls verfügbar
      if defined?(Delayed::Job)
        DeferredProcessingJob.set(wait_until: next_run).perform_later
      else
        # Fallback: Verwende at-Kommando (Unix/Linux)
        schedule_with_at(next_run)
      end
      
    rescue => e
      Rails.logger.error("Failed to schedule deferred processing: #{e.message}")
    end
  end
  
  def self.process_deferred_now
    Rails.logger.info("Starting scheduled deferred processing")
    
    begin
      service = MailHandlerService.new
      service.process_deferred_mails
      
      # Plane nächste Ausführung
      schedule_deferred_processing
      
    rescue => e
      Rails.logger.error("Scheduled deferred processing failed: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
    end
  end
  
  private
  
  def self.schedule_with_at(next_run)
    # Erstelle temporäres Script für at-Kommando
    script_content = <<~SCRIPT
      #!/bin/bash
      cd #{Rails.root}
      #{RbConfig.ruby} -e "require_relative 'config/environment'; DeferredScheduler.process_deferred_now"
    SCRIPT
    
    script_path = Rails.root.join('tmp', 'deferred_job.sh')
    File.write(script_path, script_content)
    File.chmod(0755, script_path)
    
    # Plane mit at-Kommando
    at_time = next_run.strftime('%H:%M %Y-%m-%d')
    system("echo '#{script_path}' | at #{at_time}")
    
    Rails.logger.info("Scheduled deferred processing with at command for #{at_time}")
  end
end
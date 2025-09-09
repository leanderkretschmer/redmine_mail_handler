class DeferredProcessingJob < ApplicationJob
  queue_as :default
  
  def perform
    Rails.logger.info("Starting deferred processing job")
    
    begin
      service = MailHandlerService.new
      service.process_deferred_mails
      
      # Plane nächste Ausführung
      DeferredScheduler.schedule_deferred_processing
      
    rescue => e
      Rails.logger.error("Deferred processing job failed: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise e
    end
  end
end
class QuarantineProcessingJob < ApplicationJob
  queue_as :default
  
  def perform
    Rails.logger.info("Starting quarantine processing job")
    
    begin
      service = MailHandlerService.new
      service.process_quarantine_mails
      
      # Plane nächste Ausführung
      QuarantineScheduler.schedule_quarantine_processing
      
    rescue => e
      Rails.logger.error("Quarantine processing job failed: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      raise e
    end
  end
end
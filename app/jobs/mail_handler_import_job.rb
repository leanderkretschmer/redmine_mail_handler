class MailHandlerImportJob < ActiveJob::Base
  queue_as :mail_handler

  def perform(limit: nil)
    logger.info "Starting mail import job..."
    service = MailHandlerService.new
    service.import_mails(limit)
    logger.info "Mail import job finished."
  end

  private

  def logger
    @logger ||= MailHandlerLogger.new
  end
end

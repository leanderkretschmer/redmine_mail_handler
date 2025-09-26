class MailImportJob
  include Sidekiq::Job

  # Use default queue unless you configured a dedicated one
  sidekiq_options queue: :default, retry: 3

  def perform(limit = nil)
    settings = Setting.plugin_redmine_mail_handler
    receiving = ENV['WITH_EMAIL_RECEIVING'].to_s.strip.downcase
    receiving_enabled = (receiving == '1' || receiving == 'true' || receiving == 'yes')
    unless receiving_enabled
      Rails.logger.info "[MailHandler] MailImportJob: skipped (WITH_EMAIL_RECEIVING is not enabled)"
      return
    end
    unless settings['auto_import_enabled'] == '1'
      Rails.logger.info "[MailHandler] MailImportJob: skipped (auto_import_enabled != '1')"
      return
    end

    logger = MailHandlerLogger.new
    logger.info("Sidekiq MailImportJob started#{limit ? " (limit: #{limit})" : ''}")

    service = MailHandlerService.new
    service.import_mails(limit)

    logger.info("Sidekiq MailImportJob finished")
  rescue => e
    Rails.logger.error "[MailHandler] MailImportJob failed: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise e
  end
end

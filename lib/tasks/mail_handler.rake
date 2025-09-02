namespace :redmine do
  namespace :mail_handler do
    desc 'Install Mail Handler Plugin'
    task :install => :environment do
      puts "Installing Redmine Mail Handler Plugin..."
      
      # Führe Migrationen aus
      Rake::Task['redmine:plugins:migrate'].invoke
      
      # Erstelle Standard-Einstellungen falls nicht vorhanden
      plugin_settings = Setting.plugin_redmine_mail_handler
      if plugin_settings.blank?
        Setting.plugin_redmine_mail_handler = {
          'imap_host' => '',
          'imap_port' => '993',
          'imap_ssl' => '1',
          'imap_username' => '',
          'imap_password' => '',
          'inbox_folder' => 'INBOX',
          'archive_folder' => 'Archive',
          'inbox_ticket_id' => '',
          'reminder_time' => '09:00',
          'reminder_enabled' => '1',
          'auto_import_enabled' => '1',
          'import_interval' => '5',
          'log_level' => 'info'
        }
        puts "Default settings created."
      end
      
      puts "Mail Handler Plugin installed successfully!"
      puts "Please configure the plugin settings in Administration > Plugins > Redmine Mail Handler > Configure"
    end
    
    desc 'Uninstall Mail Handler Plugin'
    task :uninstall => :environment do
      puts "Uninstalling Redmine Mail Handler Plugin..."
      
      # Stoppe Scheduler
      MailHandlerScheduler.stop if defined?(MailHandlerScheduler)
      
      # Lösche Plugin-Einstellungen
      Setting.where(name: 'plugin_redmine_mail_handler').delete_all
      
      puts "Plugin settings removed."
      puts "To complete uninstallation, run: bundle exec rake redmine:plugins:migrate NAME=redmine_mail_handler VERSION=0"
    end
    
    desc 'Import mails manually'
    task :import, [:limit] => :environment do |task, args|
      limit = args[:limit].to_i if args[:limit].present?
      
      puts "Starting manual mail import#{limit ? " (limit: #{limit})" : ''}..."
      
      service = MailHandlerService.new
      if service.import_mails(limit)
        puts "Mail import completed successfully."
      else
        puts "Mail import failed. Check logs for details."
        exit 1
      end
    end
    
    desc 'Test IMAP connection'
    task :test_connection => :environment do
      puts "Testing IMAP connection..."
      
      service = MailHandlerService.new
      result = service.test_connection
      
      if result[:success]
        puts "IMAP connection successful!"
        puts "Available folders: #{result[:folders].join(', ')}"
      else
        puts "IMAP connection failed: #{result[:error]}"
        exit 1
      end
    end
    
    desc 'Send test reminder'
    task :test_reminder, [:email] => :environment do |task, args|
      email = args[:email]
      
      if email.blank?
        puts "Usage: rake redmine:mail_handler:test_reminder[email@example.com]"
        exit 1
      end
      
      puts "Sending test reminder to #{email}..."
      
      if MailHandlerScheduler.send_test_reminder(email)
        puts "Test reminder sent successfully."
      else
        puts "Failed to send test reminder."
        exit 1
      end
    end
    
    desc 'Start scheduler'
    task :start_scheduler => :environment do
      puts "Starting Mail Handler Scheduler..."
      MailHandlerScheduler.start
      puts "✅ Scheduler started."
    end
    
    desc 'Stop scheduler'
    task :stop_scheduler => :environment do
      puts "Stopping Mail Handler Scheduler..."
      MailHandlerScheduler.stop
      puts "✅ Scheduler stopped."
    end
    
    desc 'Show scheduler status'
    task :scheduler_status => :environment do
      if MailHandlerScheduler.running?
        puts "✅ Scheduler is running."
      else
        puts "❌ Scheduler is stopped."
      end
    end
    
    desc 'Cleanup old logs (older than 30 days)'
    task :cleanup_logs => :environment do
      puts "Cleaning up old logs..."
      
      count = MailHandlerLog.where('created_at < ?', 30.days.ago).count
      MailHandlerLogger.cleanup_old_logs
      
      puts "✅ Cleaned up #{count} old log entries."
    end
    
    desc 'Show recent logs'
    task :show_logs, [:limit] => :environment do |task, args|
      limit = args[:limit]&.to_i || 20
      
      puts "Recent #{limit} log entries:"
      puts "-" * 80
      
      MailHandlerLog.recent.limit(limit).each do |log|
        puts "[#{log.formatted_time}] #{log.level.upcase}: #{log.message}"
      end
    end
    
    desc 'Show plugin status'
    task :status => :environment do
      settings = Setting.plugin_redmine_mail_handler
      
      puts "Redmine Mail Handler Plugin Status"
      puts "=" * 40
      puts "Scheduler: #{MailHandlerScheduler.running? ? '✅ Running' : '❌ Stopped'}"
      puts "Auto Import: #{settings['auto_import_enabled'] == '1' ? '✅ Enabled' : '❌ Disabled'}"
      puts "Import Interval: #{settings['import_interval']} minutes"
      puts "Reminders: #{settings['reminder_enabled'] == '1' ? "✅ Enabled (#{settings['reminder_time']})" : '❌ Disabled'}"
      puts "IMAP Host: #{settings['imap_host'].present? ? settings['imap_host'] : '❌ Not configured'}"
      puts "Log Level: #{settings['log_level']}"
      puts "Total Logs: #{MailHandlerLog.count}"
      puts "Logs Today: #{MailHandlerLog.today.count}"
    end
  end
end

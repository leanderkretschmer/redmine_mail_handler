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
          'reminder_type' => 'redmine',
          'auto_import_enabled' => '1',
          'import_interval' => '15',
          'import_interval_unit' => 'minutes',
          'log_level' => 'info',
          'user_firstname_type' => 'mail_account',
          'user_lastname_custom' => 'Auto-generated',
          'ignore_email_addresses' => ''
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

    
    desc 'Start scheduler (foreground)'
    task :start_scheduler => :environment do
      puts "Starting Mail Handler Scheduler (foreground)..."
      MailHandlerScheduler.start
      puts "Scheduler started. Press CTRL+C to stop."
      trap('INT') { MailHandlerScheduler.stop; puts "\nScheduler stopped."; exit }
      trap('TERM') { MailHandlerScheduler.stop; puts "\nScheduler stopped."; exit }
      sleep 1 while MailHandlerScheduler.running?
    end
    
    desc 'Stop scheduler'
    task :stop_scheduler => :environment do
      puts "Stopping Mail Handler Scheduler..."
      MailHandlerScheduler.stop
      puts "Scheduler stopped."
    end
    
    desc 'Show scheduler status'
    task :scheduler_status => :environment do
      if MailHandlerScheduler.running?
        puts "Scheduler is running."
      else
        puts "Scheduler is stopped."
      end
    end
    
    # DB-Log Cleanup entfernt (Logging erfolgt über Rails-Logdatei)
    
    # DB-Log Anzeige entfernt
    
    desc 'List available IMAP folders'
    task :list_folders => :environment do
      puts "Listing available IMAP folders..."
      
      service = MailHandlerService.new
      folders = service.list_imap_folders
      
      if folders.any?
        puts "\nAvailable folders:"
        folders.each { |folder| puts "  - #{folder}" }
        
        settings = Setting.plugin_redmine_mail_handler
        archive_folder = settings['archive_folder']
        
        puts "\nConfigured archive folder: '#{archive_folder}'"
        
        if archive_folder.present?
          if folders.include?(archive_folder)
            puts "Archive folder exists"
          else
            puts "Archive folder does not exist - it will be created automatically"
          end
        else
          puts "No archive folder configured - emails will not be archived"
        end
      else
        puts "Could not retrieve folder list. Check IMAP connection."
      end
    end
    
    desc 'Show plugin status'
    task :status => :environment do
      settings = Setting.plugin_redmine_mail_handler
      
      puts "Redmine Mail Handler Plugin Status"
      puts "=" * 40
      puts "Scheduler: #{MailHandlerScheduler.running? ? 'Running' : 'Stopped'}"
      puts "Auto Import: #{settings['auto_import_enabled'] == '1' ? 'Enabled' : 'Disabled'}"
      interval_unit = settings['import_interval_unit'] == 'seconds' ? 'Sekunden' : 'Minuten'
      puts "Import Interval: #{settings['import_interval']} #{interval_unit}"
      puts "Reminders: #{settings['reminder_enabled'] == '1' ? "Enabled (#{settings['reminder_time']})" : 'Disabled'}"
      puts "IMAP Host: #{settings['imap_host'].present? ? settings['imap_host'] : 'Not configured'}"
      puts "Log Level: #{settings['log_level']}"
      # Logs sind im Rails-Log einsehbar
    end
  end
end

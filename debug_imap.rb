#!/usr/bin/env ruby

# Debug-Script für IMAP-Verbindung und deferred Ordner
require 'net/imap'
require 'mail'
require 'json'

# IMAP-Konfiguration (bitte anpassen)
IMAP_HOST = 'imap.gmail.com'  # Beispiel - bitte anpassen
IMAP_PORT = 993
IMAP_SSL = true
IMAP_USERNAME = 'your-email@gmail.com'  # Bitte anpassen
IMAP_PASSWORD = 'your-password'  # Bitte anpassen
DEFERRED_FOLDER = 'Deferred'

puts "=== IMAP Debug Script ==="
puts "Host: #{IMAP_HOST}:#{IMAP_PORT} (SSL: #{IMAP_SSL})"
puts "Username: #{IMAP_USERNAME}"
puts "Deferred Folder: #{DEFERRED_FOLDER}"
puts

begin
  # IMAP-Verbindung herstellen
  puts "1. Connecting to IMAP server..."
  imap = Net::IMAP.new(IMAP_HOST, IMAP_PORT, IMAP_SSL)
  puts "   ✓ Connected successfully"
  
  # Anmelden
  puts "2. Authenticating..."
  imap.login(IMAP_USERNAME, IMAP_PASSWORD)
  puts "   ✓ Authentication successful"
  
  # Alle Ordner auflisten
  puts "3. Listing all folders..."
  folders = imap.list('', '*')
  puts "   Available folders:"
  folders.each { |folder| puts "     - #{folder.name}" }
  puts
  
  # Prüfen ob deferred Ordner existiert
  puts "4. Checking deferred folder '#{DEFERRED_FOLDER}'..."
  deferred_exists = folders.any? { |folder| folder.name == DEFERRED_FOLDER }
  
  if deferred_exists
    puts "   ✓ Deferred folder exists"
    
    # Deferred Ordner auswählen
    puts "5. Selecting deferred folder..."
    imap.select(DEFERRED_FOLDER)
    puts "   ✓ Folder selected successfully"
    
    # Nachrichten zählen
    puts "6. Counting messages..."
    msg_ids = imap.search(['ALL'])
    puts "   Found #{msg_ids.length} messages in deferred folder"
    
    if msg_ids.any?
      puts "7. Analyzing first few messages..."
      msg_ids.first(3).each_with_index do |msg_id, index|
        begin
          puts "   Message #{index + 1} (ID: #{msg_id}):"
          
          # Hole Mail-Daten
          msg_data = imap.fetch(msg_id, 'RFC822')[0].attr['RFC822']
          if msg_data.blank?
            puts "     ✗ No message data"
            next
          end
          
          mail = Mail.read_from_string(msg_data)
          if mail.nil?
            puts "     ✗ Could not parse mail"
            next
          end
          
          puts "     From: #{mail.from&.first}"
          puts "     Subject: #{mail.subject}"
          puts "     Date: #{mail.date}"
          puts "     Message-ID: #{mail.message_id}"
          
          # Prüfe X-Redmine-Deferred Header
          deferred_header = mail.header['X-Redmine-Deferred']
          if deferred_header
            puts "     X-Redmine-Deferred: #{deferred_header.value}"
            begin
              deferred_info = JSON.parse(deferred_header.value)
              puts "     Deferred At: #{deferred_info['deferred_at']}"
              puts "     Expires At: #{deferred_info['expires_at']}"
              puts "     Reason: #{deferred_info['reason']}"
            rescue JSON::ParserError
              puts "     ✗ Could not parse deferred header JSON"
            end
          else
            puts "     ✗ No X-Redmine-Deferred header found"
          end
          
          puts
        rescue => e
          puts "     ✗ Error processing message: #{e.message}"
        end
      end
    else
      puts "   ✗ No messages found in deferred folder"
    end
    
  else
    puts "   ✗ Deferred folder '#{DEFERRED_FOLDER}' does not exist"
    puts "   Available folders that might be deferred:"
    folders.each do |folder|
      if folder.name.downcase.include?('defer') || 
         folder.name.downcase.include?('zurück') ||
         folder.name.downcase.include?('pending')
        puts "     - #{folder.name}"
      end
    end
  end
  
rescue Net::IMAP::NoResponseError => e
  puts "✗ IMAP Error: #{e.message}"
rescue => e
  puts "✗ General Error: #{e.class.name} - #{e.message}"
  puts "Backtrace:"
  puts e.backtrace.first(5).join("\n")
ensure
  imap&.disconnect
  puts "\n=== Debug completed ==="
end
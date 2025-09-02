#!/usr/bin/env ruby

# Test-Skript für SMTP-Konfiguration
# Dieses Skript kann verwendet werden, um die SMTP-Einstellungen zu testen

require 'mail'

# Beispiel-SMTP-Konfiguration (IMAP zu SMTP konvertiert)
def test_smtp_from_imap_settings
  imap_host = 'imap.gmail.com'
  imap_ssl = true
  imap_username = 'test@gmail.com'
  imap_password = 'password'
  
  # Konvertiere IMAP zu SMTP
  smtp_host = imap_host.gsub(/^imap\./, 'smtp.')
  smtp_port = imap_ssl ? 465 : 587
  
  puts "IMAP Host: #{imap_host}"
  puts "SMTP Host: #{smtp_host}"
  puts "SMTP Port: #{smtp_port}"
  puts "SSL: #{imap_ssl}"
  
  smtp_config = {
    address: smtp_host,
    port: smtp_port,
    domain: smtp_host.split('.')[1..-1].join('.'),
    user_name: imap_username,
    password: imap_password,
    authentication: :plain,
    enable_starttls_auto: !imap_ssl,
    ssl: imap_ssl
  }
  
  puts "\nSMTP Configuration:"
  smtp_config.each do |key, value|
    puts "  #{key}: #{value}"
  end
  
  return smtp_config
end

# Test verschiedene E-Mail-Provider
def test_common_providers
  providers = [
    { name: 'Gmail', imap: 'imap.gmail.com', expected_smtp: 'smtp.gmail.com' },
    { name: 'Outlook', imap: 'outlook.office365.com', expected_smtp: 'smtp.office365.com' },
    { name: 'Yahoo', imap: 'imap.mail.yahoo.com', expected_smtp: 'smtp.mail.yahoo.com' },
    { name: 'Custom', imap: 'imap.example.com', expected_smtp: 'smtp.example.com' }
  ]
  
  puts "\n=== Testing Common E-Mail Providers ==="
  
  providers.each do |provider|
    puts "\n#{provider[:name]}:"
    puts "  IMAP: #{provider[:imap]}"
    
    smtp_host = provider[:imap].gsub(/^imap\./, 'smtp.')
    puts "  SMTP: #{smtp_host}"
    puts "  Expected: #{provider[:expected_smtp]}"
    puts "  Match: #{smtp_host == provider[:expected_smtp] ? '✓' : '✗'}"
  end
end

if __FILE__ == $0
  puts "=== SMTP Configuration Test ==="
  test_smtp_from_imap_settings
  test_common_providers
  
  puts "\n=== Test completed ==="
end
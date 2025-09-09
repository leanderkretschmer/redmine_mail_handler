#!/usr/bin/env ruby

# Test-Skript um die Behebung des ConnectionTimeoutError Problems zu überprüfen

require_relative 'config/environment'
require_relative 'lib/mail_handler_logger'

puts "Testing MailHandlerLogger connection handling..."

# Initialisiere Logger
logger = MailHandlerLogger.new

# Teste mehrere gleichzeitige Log-Einträge
threads = []

10.times do |i|
  threads << Thread.new do
    5.times do |j|
      logger.info("Test message #{i}-#{j} from thread #{Thread.current.object_id}")
      sleep(0.1)
    end
  end
end

# Warte auf alle Threads
threads.each(&:join)

puts "Test completed successfully - no ConnectionTimeoutError occurred!"
puts "Recent log entries:"

# Zeige die letzten Log-Einträge
begin
  recent_logs = MailHandlerLog.recent.limit(10)
  recent_logs.each do |log|
    puts "[#{log.level.upcase}] #{log.formatted_time}: #{log.message}"
  end
rescue => e
  puts "Error reading logs: #{e.message}"
end
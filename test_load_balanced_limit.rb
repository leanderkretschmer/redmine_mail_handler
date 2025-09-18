#!/usr/bin/env ruby
# Test-Script für Load-Balanced Import Limit-Prüfung

puts "=== Load-Balanced Import Limit Test ==="
puts

# Simuliere das neue Verhalten des MailHandlerScheduler
class TestScheduler
  def self.get_current_hour_mail_count
    # Simuliere verschiedene Szenarien
    29 # Über dem Limit von 28
  end
  
  def self.test_limit_check
    mails_per_hour = 28
    current_hour_count = get_current_hour_mail_count
    
    puts "Konfiguration:"
    puts "- Mails pro Stunde: #{mails_per_hour}"
    puts "- Aktueller Counter: #{current_hour_count}"
    puts
    
    if current_hour_count >= mails_per_hour
      current_time = Time.now
      next_hour = current_time.hour + 1
      next_hour = 0 if next_hour >= 24
      puts "❌ LIMIT ERREICHT!"
      puts "   Scheduler wird pausiert bis zum Reset um #{next_hour.to_s.rjust(2, '0')}:00"
      puts "   Status: #{current_hour_count}/#{mails_per_hour} (Überschreitung um #{current_hour_count - mails_per_hour})"
      return false
    else
      puts "✅ Import erlaubt"
      puts "   Status: #{current_hour_count}/#{mails_per_hour} (#{mails_per_hour - current_hour_count} verbleibend)"
      return true
    end
  end
end

# Test verschiedener Szenarien
puts "Szenario 1: Limit überschritten (29/28)"
TestScheduler.test_limit_check
puts

# Simuliere Szenario unter dem Limit
class TestScheduler
  def self.get_current_hour_mail_count
    25 # Unter dem Limit
  end
end

puts "Szenario 2: Unter dem Limit (25/28)"
TestScheduler.test_limit_check
puts

# Simuliere Szenario genau am Limit
class TestScheduler
  def self.get_current_hour_mail_count
    28 # Genau am Limit
  end
end

puts "Szenario 3: Genau am Limit (28/28)"
TestScheduler.test_limit_check
puts

puts "=== Implementierung Details ==="
puts
puts "Die neue Implementierung in MailHandlerScheduler:"
puts "1. Prüft vor jedem Import den aktuellen Stunden-Counter"
puts "2. Überspringt den Import wenn das Limit erreicht ist"
puts "3. Loggt eine Warnung mit der nächsten Reset-Zeit"
puts "4. Setzt automatisch fort nach dem stündlichen Reset"
puts
puts "Vorteile:"
puts "- Verhindert Überschreitung des konfigurierten Limits"
puts "- Automatische Wiederaufnahme nach Reset"
puts "- Transparente Logging-Nachrichten"
puts "- Keine manuelle Intervention erforderlich"
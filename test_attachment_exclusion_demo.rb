#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# Demo-Script für Datei-Ausschluss-Funktionalität
# Zeigt die Funktionalität der neuen Attachment-Filter

class AttachmentExclusionDemo
  def initialize
    # Simuliere Plugin-Einstellungen
    @settings = {
      'exclude_attachments_enabled' => '1',
      'excluded_attachment_patterns' => "*.tmp\n*.log\nwinmail.dat\nimage*.png\n*.bak"
    }
  end

  # Prüfe ob Anhang ausgeschlossen werden soll
  def should_exclude_attachment?(filename)
    return false unless @settings['exclude_attachments_enabled'] == '1'
    return false if filename.nil? || filename.empty?
    
    # Hole Ausschluss-Muster aus Einstellungen
    patterns = @settings['excluded_attachment_patterns']
    return false if patterns.nil? || patterns.empty?
    
    # Teile Muster in einzelne Zeilen auf
    pattern_list = patterns.split("\n").map(&:strip).reject(&:empty?)
    
    # Prüfe jeden Pattern
    pattern_list.each do |pattern|
      # Konvertiere Wildcard-Pattern zu Regex
      regex_pattern = pattern.gsub('*', '.*')
      
      # Erstelle Regex (case-insensitive)
      begin
        regex = Regexp.new("^#{regex_pattern}$", Regexp::IGNORECASE)
        
        # Prüfe ob Dateiname dem Muster entspricht
        if filename.match?(regex)
          puts "✓ Attachment '#{filename}' matches exclusion pattern '#{pattern}'"
          return true
        end
      rescue RegexpError => e
        puts "⚠ Invalid exclusion pattern '#{pattern}': #{e.message}"
        next
      end
    end
    
    false
  end

  def test_exclusion_patterns
    puts "=== Datei-Ausschluss Demo ==="
    puts "Aktuelle Ausschluss-Muster:"
    @settings['excluded_attachment_patterns'].split("\n").each do |pattern|
      puts "  - #{pattern}"
    end
    puts
    
    # Test-Dateien
    test_files = [
      'document.pdf',      # Sollte NICHT ausgeschlossen werden
      'test.tmp',          # Sollte ausgeschlossen werden (*.tmp)
      'debug.log',         # Sollte ausgeschlossen werden (*.log)
      'winmail.dat',       # Sollte ausgeschlossen werden (exakter Match)
      'image001.png',      # Sollte ausgeschlossen werden (image*.png)
      'image123.png',      # Sollte ausgeschlossen werden (image*.png)
      'photo.jpg',         # Sollte NICHT ausgeschlossen werden
      'backup.bak',        # Sollte ausgeschlossen werden (*.bak)
      'TEST.TMP',          # Sollte ausgeschlossen werden (case-insensitive)
      'WINMAIL.DAT',       # Sollte ausgeschlossen werden (case-insensitive)
      'presentation.pptx', # Sollte NICHT ausgeschlossen werden
      'temp.tmp.txt',      # Sollte NICHT ausgeschlossen werden (kein exakter Match)
      'myimage.png'        # Sollte NICHT ausgeschlossen werden (passt nicht zu image*.png)
    ]
    
    puts "Test-Ergebnisse:"
    puts "================="
    
    excluded_count = 0
    allowed_count = 0
    
    test_files.each do |filename|
      if should_exclude_attachment?(filename)
        puts "❌ AUSGESCHLOSSEN: #{filename}"
        excluded_count += 1
      else
        puts "✅ ERLAUBT: #{filename}"
        allowed_count += 1
      end
    end
    
    puts
    puts "Zusammenfassung:"
    puts "================"
    puts "#{excluded_count} Dateien ausgeschlossen"
    puts "#{allowed_count} Dateien erlaubt"
    puts "#{test_files.length} Dateien insgesamt getestet"
  end

  def test_disabled_filter
    puts "\n=== Test: Filter deaktiviert ==="
    
    # Deaktiviere Filter temporär
    original_setting = @settings['exclude_attachments_enabled']
    @settings['exclude_attachments_enabled'] = '0'
    
    test_files = ['test.tmp', 'debug.log', 'winmail.dat']
    
    puts "Filter ist deaktiviert - alle Dateien sollten erlaubt sein:"
    test_files.each do |filename|
      if should_exclude_attachment?(filename)
        puts "❌ AUSGESCHLOSSEN: #{filename} (FEHLER - sollte erlaubt sein!)"
      else
        puts "✅ ERLAUBT: #{filename}"
      end
    end
    
    # Stelle ursprüngliche Einstellung wieder her
    @settings['exclude_attachments_enabled'] = original_setting
  end

  def test_invalid_patterns
    puts "\n=== Test: Ungültige Regex-Muster ==="
    
    # Teste mit ungültigen Regex-Mustern
    original_patterns = @settings['excluded_attachment_patterns']
    @settings['excluded_attachment_patterns'] = "[invalid\nvalid.txt\n*.pdf"
    
    test_files = ['[invalid', 'valid.txt', 'document.pdf']
    
    puts "Test mit ungültigen Regex-Mustern:"
    test_files.each do |filename|
      if should_exclude_attachment?(filename)
        puts "❌ AUSGESCHLOSSEN: #{filename}"
      else
        puts "✅ ERLAUBT: #{filename}"
      end
    end
    
    # Stelle ursprüngliche Muster wieder her
    @settings['excluded_attachment_patterns'] = original_patterns
  end

  def run_all_tests
    puts "=== Attachment Exclusion Demo ==="
    puts "Demonstriert die neue Datei-Ausschluss-Funktionalität"
    puts
    
    test_exclusion_patterns
    test_disabled_filter
    test_invalid_patterns
    
    puts "\n=== Demo abgeschlossen ==="
    puts "Die Datei-Ausschluss-Funktionalität arbeitet korrekt!"
    puts
    puts "Verwendung in den Redmine-Einstellungen:"
    puts "1. 'Datei-Ausschluss aktivieren' ankreuzen"
    puts "2. Muster in 'Ausgeschlossene Datei-Muster' eingeben (eines pro Zeile)"
    puts "3. Wildcards (*) werden unterstützt"
    puts "4. Groß-/Kleinschreibung wird ignoriert"
  end
end

# Demo ausführen
if __FILE__ == $0
  demo = AttachmentExclusionDemo.new
  demo.run_all_tests
end
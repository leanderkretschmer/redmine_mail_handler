#!/usr/bin/env ruby

# Demo-Script für die neuen Mail-Filter-Funktionen
# Führe aus mit: ruby test_filters_demo.rb

require 'nokogiri'
require 'cgi'

# Simuliere die Filter-Methoden
class MailFilterDemo
  def initialize
    @settings = {
      'html_structure_filter_enabled' => '1',
      'regex_filter_enabled' => '1',
      'regex_separators' => "Am .* schrieb .*:\nVon:\nGesendet:\nAn:\nBetreff:\n-----Original Message-----\n-------- Ursprüngliche Nachricht --------"
    }
  end

  # HTML-Struktur-Filter: Entferne störende HTML-Elemente
  def apply_html_structure_filter(doc)
    # Entferne Blockquote-Elemente (Zitate)
    doc.css('blockquote').remove
    
    # Entferne Gmail-spezifische Elemente
    doc.css('.gmail_quote, .gmail_attr').remove
    doc.css('[class*="gmail_quote"], [class*="gmail_attr"]').remove
    
    # Entferne Apple Mail-spezifische Elemente
    doc.css('.apple-msg-attachment, .Apple-converted-space').remove
    doc.css('[class*="apple-msg-attachment"], [class*="Apple-converted-space"]').remove
    
    # Entferne Outlook-spezifische Elemente
    doc.css('.WordSection1, .OutlookMessageHeader, .x_QuotedText').remove
    doc.css('[class*="WordSection"], [class*="OutlookMessageHeader"], [class*="QuotedText"]').remove
    
    # Entferne Yahoo-spezifische Elemente
    doc.css('.yahoo_quoted, .yahoo_quote').remove
    doc.css('[class*="yahoo_quoted"], [class*="yahoo_quote"]').remove
    
    # Entferne Android Mail-spezifische Elemente
    doc.css('.mail_android_quote').remove
    doc.css('[class*="mail_android_quote"]').remove
    
    puts "HTML-Struktur-Filter angewendet"
  end

  # Regex-Filter: Entferne Text ab typischen E-Mail-Trennern
  def apply_regex_filter(text)
    return text if text.nil? || text.empty?
    
    # Hole Regex-Trenner aus Einstellungen
    separators = @settings['regex_separators']
    
    # Teile Trenner in einzelne Zeilen auf
    separator_patterns = separators.split("\n").map(&:strip).reject(&:empty?)
    
    # Durchsuche Text nach Trennern
    separator_patterns.each do |pattern|
      begin
        # Erstelle Regex-Pattern (case-insensitive und multiline)
        regex = Regexp.new(pattern, Regexp::IGNORECASE | Regexp::MULTILINE)
        
        # Finde erste Übereinstimmung
        match = text.match(regex)
        if match
          # Schneide Text ab der ersten Übereinstimmung ab
          text = text[0, match.begin(0)].strip
          puts "Regex-Filter angewendet: Text ab '#{pattern}' entfernt"
          break  # Stoppe nach dem ersten gefundenen Trenner
        end
      rescue RegexpError => e
        puts "Ungültiges Regex-Pattern '#{pattern}': #{e.message}"
        next
      end
    end
    
    text
  end

  def test_html_filter
    puts "\n=== HTML-Struktur-Filter Test ==="
    
    html = <<~HTML
      <div>
        <p>Das ist eine wichtige neue Nachricht.</p>
        <p>Hier steht noch mehr wichtiger Inhalt.</p>
        
        <blockquote>
          <p>Das ist ein Zitat aus der ursprünglichen E-Mail.</p>
        </blockquote>
        
        <div class="gmail_quote">
          <p>Gmail-spezifisches Zitat</p>
        </div>
        
        <div class="apple-msg-attachment">
          <p>Apple Mail Anhang</p>
        </div>
        
        <p>Noch mehr wichtiger Inhalt am Ende.</p>
      </div>
    HTML
    
    puts "Vor dem Filter:"
    puts html
    
    # HTML-Struktur-Filter anwenden
    if @settings['html_structure_filter_enabled'] == '1'
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      apply_html_structure_filter(doc)
      filtered_html = doc.to_html
    else
      filtered_html = html
    end
    
    # Zu Text konvertieren
    doc = Nokogiri::HTML::DocumentFragment.parse(filtered_html)
    text = doc.inner_text
    text = CGI.unescapeHTML(text)
    text = text.gsub(/\s+/, ' ').strip
    
    puts "\nNach dem Filter:"
    puts text
  end

  def test_regex_filter
    puts "\n=== Regex-Filter Test ==="
    
    text = <<~TEXT
      Das ist eine neue Antwort auf die E-Mail.
      
      Hier steht noch mehr wichtiger Inhalt.
      Und noch eine Zeile.
      
      Am 15.01.2024 um 14:30 schrieb test@example.com:
      > Das ist die ursprüngliche Nachricht
      > die entfernt werden soll.
      > Noch mehr ursprünglicher Inhalt.
    TEXT
    
    puts "Vor dem Filter:"
    puts text
    
    # Regex-Filter anwenden
    if @settings['regex_filter_enabled'] == '1'
      filtered_text = apply_regex_filter(text)
    else
      filtered_text = text
    end
    
    puts "\nNach dem Filter:"
    puts filtered_text
  end

  def test_outlook_original_message
    puts "\n=== Outlook Original Message Test ==="
    
    text = <<~TEXT
      Hallo,
      
      das ist meine Antwort auf Ihre E-Mail.
      
      Mit freundlichen Grüßen
      Max Mustermann
      
      -----Original Message-----
      From: sender@example.com
      Sent: Monday, January 15, 2024 2:30 PM
      To: recipient@example.com
      Subject: Test Subject
      
      Das ist die ursprüngliche Nachricht die entfernt werden soll.
    TEXT
    
    puts "Vor dem Filter:"
    puts text
    
    # Regex-Filter anwenden
    if @settings['regex_filter_enabled'] == '1'
      filtered_text = apply_regex_filter(text)
    else
      filtered_text = text
    end
    
    puts "\nNach dem Filter:"
    puts filtered_text
  end

  def run_all_tests
    puts "Mail Filter Demo"
    puts "================="
    
    test_html_filter
    test_regex_filter
    test_outlook_original_message
    
    puts "\n=== Demo abgeschlossen ==="
  end
end

# Demo ausführen
if __FILE__ == $0
  demo = MailFilterDemo.new
  demo.run_all_tests
end
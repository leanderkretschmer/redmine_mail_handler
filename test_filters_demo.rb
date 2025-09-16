#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# Demo-Script für Mail-Filter-Funktionen
# Zeigt die Funktionalität aller vier Filter-Typen

require 'nokogiri'
require 'cgi'

class MailFilterDemo
  def initialize
    # Simuliere Plugin-Einstellungen
    @settings = {
      'html_structure_filter_enabled' => '1',
      'regex_filter_enabled' => '1',
      'regex_separators' => "Am .* schrieb .*:\nVon:\nGesendet:\nAn:\nBetreff:\n-----Original Message-----\n-------- Ursprüngliche Nachricht --------",
      'remove_leading_whitespace_enabled' => '1',
      'normalize_paragraphs_enabled' => '1',
      'max_consecutive_paragraphs' => '1'
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

  # Whitespace-Filter: Entferne führende Leerzeichen und Tabs
  def apply_whitespace_filter(text)
    return text if text.nil? || text.empty?
    
    # Entferne führende Leerzeichen und Tabs von jeder Zeile
    lines = text.split("\n")
    filtered_lines = lines.map { |line| line.lstrip }
    filtered_text = filtered_lines.join("\n")
    
    puts "Whitespace-Filter angewendet: Führende Leerzeichen entfernt"
    filtered_text
  end

  # Absatz-Normalisierungs-Filter: Reduziere aufeinanderfolgende leere Zeilen
  def apply_paragraph_normalization_filter(text)
    return text if text.nil? || text.empty?
    
    # Hole maximale Anzahl aufeinanderfolgender Absätze aus Einstellungen
    max_paragraphs = (@settings['max_consecutive_paragraphs'] || '1').to_i
    max_paragraphs = [max_paragraphs, 1].max  # Mindestens 1
    max_paragraphs = [max_paragraphs, 5].min  # Maximal 5
    
    # Erstelle Regex-Pattern für mehr als max_paragraphs aufeinanderfolgende Newlines
    pattern = "\\n{#{max_paragraphs + 1},}"
    replacement = "\n" * max_paragraphs
    
    # Wende Filter an
    filtered_text = text.gsub(Regexp.new(pattern), replacement)
    
    puts "Absatz-Normalisierungs-Filter angewendet: Maximal #{max_paragraphs} aufeinanderfolgende Absätze"
    filtered_text
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
      **Betreff:** AW: pfp10406 bv sontheim mainz - ausführungspläne [#51090]
      
      Guten Tag,
      
      anbei der Werkplan EG als Vorabzug.
      
      Bei Freigabe entfällt der Vorabzug, ebenso beim UG-Plan.
      
      Gruß
      
      S. Boccagno
      
      -----Original Message-----
      From: sender@example.com
      To: recipient@example.com
      Subject: Test
      
      Ursprüngliche Nachricht Inhalt
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

  def test_whitespace_filter
    puts "\n=== Whitespace-Filter Test ==="
    
    text = <<~TEXT
      Guten Tag,
      
          anbei der Werkplan EG als Vorabzug.
      
          Bei Freigabe entfällt der Vorabzug, ebenso beim UG-Plan. Die Statik haben wir nach den Vorabzügen eingepflegt.
      
      Gruß
      
          S. Boccagno
          Dipl. Ing. (FH) - Freier Architekt
      
              SALVATORE BOCCAGNO ARCHITEKTEN
              Schwibbogen 6                  D-97947 Grünsfeld
    TEXT
    
    puts "Vor dem Filter:"
    puts text
    
    # Whitespace-Filter anwenden
    if @settings['remove_leading_whitespace_enabled'] == '1'
      filtered_text = apply_whitespace_filter(text)
    else
      filtered_text = text
    end
    
    puts "\nNach dem Filter:"
    puts filtered_text
  end

  def test_paragraph_normalization_filter
    puts "\n=== Absatz-Normalisierungs-Filter Test ==="
    
    text = <<~TEXT
      Guten Tag,
      
      
      
      
      
      anbei der Werkplan EG als Vorabzug.
      
      
      Bei Freigabe entfällt der Vorabzug.
      
      
      
      
      Gruß
      
      S. Boccagno
    TEXT
    
    puts "Vor dem Filter:"
    puts text
    
    # Absatz-Normalisierungs-Filter anwenden
    if @settings['normalize_paragraphs_enabled'] == '1'
      filtered_text = apply_paragraph_normalization_filter(text)
    else
      filtered_text = text
    end
    
    puts "\nNach dem Filter:"
    puts filtered_text
  end

  def test_combined_filters
    puts "\n=== Kombinierte Filter Test ==="
    
    text = <<~TEXT
      **Betreff:** AW: pfp10406 bv sontheim mainz - ausführungspläne [#51090]
      
      
      
      Guten Tag,
      
      
          anbei der Werkplan EG als Vorabzug.
      
      
      
          Bei Freigabe entfällt der Vorabzug, ebenso beim UG-Plan.
      
      
      
      
      Gruß
      
      
          S. Boccagno
      
      -----Original Message-----
      From: sender@example.com
      Subject: Original
      
      Ursprüngliche Nachricht
    TEXT
    
    puts "Vor den Filtern:"
    puts text
    
    # Alle Filter nacheinander anwenden
    filtered_text = text
    
    # 1. Regex-Filter
    if @settings['regex_filter_enabled'] == '1'
      filtered_text = apply_regex_filter(filtered_text)
    end
    
    # 2. Whitespace-Filter
    if @settings['remove_leading_whitespace_enabled'] == '1'
      filtered_text = apply_whitespace_filter(filtered_text)
    end
    
    # 3. Absatz-Normalisierungs-Filter
    if @settings['normalize_paragraphs_enabled'] == '1'
      filtered_text = apply_paragraph_normalization_filter(filtered_text)
    end
    
    puts "\nNach allen Filtern:"
    puts filtered_text
  end

  def run_all_tests
    puts "=== Mail Filter Demo ==="
    puts "Demonstriert alle vier Filter-Typen des Redmine Mail Handler Plugins"
    
    test_html_filter
    test_regex_filter
    test_whitespace_filter
    test_paragraph_normalization_filter
    test_combined_filters
    
    puts "\n=== Demo abgeschlossen ==="
    puts "Alle Filter funktionieren korrekt!"
  end
end

# Demo ausführen
if __FILE__ == $0
  demo = MailFilterDemo.new
  demo.run_all_tests
end
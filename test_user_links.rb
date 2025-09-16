#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# Test für die spezifischen Links aus der Benutzeranfrage

def apply_markdown_link_filter(text)
  return text if text.nil? || text.empty?
  
  converted_text = text.dup
  total_conversions = 0
  
  # Regex für URLs in Backticks ohne Alt-Text: ( `url` )
  backtick_url_pattern = /\(\s*`([^`]+)`\s*\)/
  backtick_conversions = converted_text.scan(backtick_url_pattern).count
  converted_text = converted_text.gsub(backtick_url_pattern) do |match|
    link_url = $1
    link_url
  end
  total_conversions += backtick_conversions
  
  # Regex für mehrzeilige URLs in Backticks: ( \n `url` \n )
  multiline_backtick_pattern = /\(\s*\n\s*`([^`]+)`\s*\n\s*\)/m
  multiline_conversions = converted_text.scan(multiline_backtick_pattern).count
  converted_text = converted_text.gsub(multiline_backtick_pattern) do |match|
    link_url = $1.strip
    link_url
  end
  total_conversions += multiline_conversions
  
  # Regex für URLs in Backticks ohne Klammern: \n `url`
  standalone_backtick_pattern = /\n\s*`([^`]+)`/
  standalone_conversions = converted_text.scan(standalone_backtick_pattern).count
  converted_text = converted_text.gsub(standalone_backtick_pattern) do |match|
    link_url = $1.strip
    "\n#{link_url}"
  end
  total_conversions += standalone_conversions
  
  # Regex für Mailto-Links: <mailto:email>
  mailto_pattern = /<mailto:([^>]+)>/
  mailto_conversions = converted_text.scan(mailto_pattern).count
  converted_text = converted_text.gsub(mailto_pattern) do |match|
    email = $1
    email
  end
  total_conversions += mailto_conversions
  
  puts "Konvertierungen: #{total_conversions} (#{backtick_conversions} Backtick, #{multiline_conversions} Multiline, #{standalone_conversions} Standalone, #{mailto_conversions} Mailto)" if total_conversions > 0
  
  converted_text
end

# Test mit den Beispielen vom Benutzer
test_text = <<~TEXT
Impressum ( 
 `https://mail.weka.de/d?p00be0sy00ez4600d0000q0q000000000e7i7morudc5sd0dpdyn3qoi0000bc000000nlk0rku&chorid=1114910_3140669539&salesgroup=323&em_src=nl&em_cmp=bi/e/1828/2025/37/1114910&ecmId=11841/10193&ecmUid=78799` 
 ) | AGB ( 
 `https://mail.weka.de/d?p00be0t000ez4600d0000q0q000000000e7i7morudc5sd0dpdyn3qoi0000bc000000nnyl45y&chorid=1114910_3140669539&salesgroup=323&em_src=nl&em_cmp=bi/e/1828/2025/37/1114910&ecmId=11841/10193&ecmUid=78799` 
 ) | Datenschutz ( 
 `https://mail.weka.de/d?p00be0ti00ez4600d0000q0q000000000e7i7morudc5sd0dpdyn3qoi0000bc000000bs73ley&chorid=1114910_3140669539&salesgroup=323&em_src=nl&em_cmp=bi/e/1828/2025/37/1114910&ecmId=11841/10193&ecmUid=78799` 
 ) | Abmelden 
 `https://mail.weka.de/d?p00be0tq00ez4600d0000q0q000000000e7i7morudc5sd0dpdyn3qoi0000bc000000jflcvh4&email=office@planfabrik.com&emailId=11841&profile=110300`
TEXT

puts "=== Test: Benutzer-Links ==="
puts "\nVorher:"
puts test_text

result = apply_markdown_link_filter(test_text)

puts "\nNachher:"
puts result

# Test für mailto-Links
mailto_text = "E-mail: georg.richter@lohr-soehne.de<mailto:georg.richter@lohr-soehne.de>"

puts "\n=== Test: Mailto-Links ==="
puts "\nVorher:"
puts mailto_text

mailto_result = apply_markdown_link_filter(mailto_text)

puts "\nNachher:"
puts mailto_result

puts "\n=== Test abgeschlossen ==="
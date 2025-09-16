#!/usr/bin/env ruby

# Einfacher Test für die Markdown-Link-Filter-Funktionalität
# Simuliert die apply_markdown_link_filter Methode

def apply_markdown_link_filter(text)
  return text if text.nil? || text.empty?
  
  # Regex für Markdown-Links: [alt-text](link)
  markdown_link_pattern = /\[([^\]]+)\]\(([^\)]+)\)/
  
  # Ersetze alle Markdown-Links
  converted_text = text.gsub(markdown_link_pattern) do |match|
    alt_text = $1
    link_url = $2
    
    # Konvertiere zu "alt-text":link Format
    "\"#{alt_text}\":#{link_url}"
  end
  
  # Log nur wenn Änderungen vorgenommen wurden
  if converted_text != text
    puts "Markdown-Link-Filter angewendet: #{text.scan(markdown_link_pattern).count} Links konvertiert"
  end
  
  converted_text
end

# Test-Fälle
test_cases = [
  {
    input: 'Hier ist ein [Link](https://example.com) im Text.',
    expected: 'Hier ist ein "Link":https://example.com im Text.'
  },
  {
    input: 'Erste [Link](https://example.com) und zweite [Seite](http://test.org) Links.',
    expected: 'Erste "Link":https://example.com und zweite "Seite":http://test.org Links.'
  },
  {
    input: 'Normaler Text ohne Links.',
    expected: 'Normaler Text ohne Links.'
  },
  {
    input: 'Link mit [komplexem Alt-Text mit Leerzeichen](https://example.com/path?param=value) hier.',
    expected: 'Link mit "komplexem Alt-Text mit Leerzeichen":https://example.com/path?param=value hier.'
  },
  {
    input: '',
    expected: ''
  }
]

puts "=== Markdown-Link-Filter Tests ==="
puts

test_cases.each_with_index do |test_case, index|
  puts "Test #{index + 1}:"
  puts "Input:    #{test_case[:input].inspect}"
  
  result = apply_markdown_link_filter(test_case[:input])
  
  puts "Output:   #{result.inspect}"
  puts "Expected: #{test_case[:expected].inspect}"
  
  if result == test_case[:expected]
    puts "✅ PASS"
  else
    puts "❌ FAIL"
  end
  
  puts
end

puts "=== Test abgeschlossen ==="
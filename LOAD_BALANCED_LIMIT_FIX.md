# Load-Balanced Import Limit Fix

## Problem
Beim Load-Balanced Import wurden mehr E-Mails importiert als konfiguriert (29 statt 28). Der Scheduler hat das Stunden-Limit nicht beachtet und weiter importiert.

## Lösung
Der `MailHandlerScheduler` wurde erweitert um eine automatische Limit-Prüfung:

### Geänderte Dateien
- `lib/mail_handler_scheduler.rb`

### Neue Funktionalität
1. **Limit-Prüfung vor jedem Import**: Der Scheduler prüft vor jedem geplanten Import den aktuellen Stunden-Counter
2. **Automatische Pausierung**: Wenn das Limit erreicht ist, wird der Import übersprungen
3. **Transparente Logs**: Klare Meldungen über Limit-Erreichen und nächste Reset-Zeit
4. **Automatische Wiederaufnahme**: Nach dem stündlichen Reset läuft der Import automatisch weiter

### Code-Änderungen

#### Neue Hilfsmethode
```ruby
def self.get_current_hour_mail_count
  current_hour_start = Time.current.beginning_of_hour
  MailHandlerLog.where(
    created_at: current_hour_start..Time.current
  ).where("message LIKE ?", "%[LOAD-BALANCED]%").count
end
```

#### Erweiterte Import-Logik
```ruby
# Prüfe ob das Stunden-Limit bereits erreicht ist
current_hour_count = get_current_hour_mail_count

if current_hour_count >= mails_per_hour
  next_reset = Time.current.beginning_of_hour + 1.hour
  @@logger.info_load_balanced("Hourly limit reached (#{current_hour_count}/#{mails_per_hour}). Skipping import until reset at #{next_reset.strftime('%H:%M')}")
  next
end
```

## Verhalten

### Vor der Änderung
- Import lief kontinuierlich ohne Limit-Beachtung
- Überschreitung des konfigurierten Limits möglich
- Manuelle Intervention erforderlich

### Nach der Änderung
- Automatische Limit-Prüfung vor jedem Import
- Import wird pausiert wenn Limit erreicht
- Automatische Wiederaufnahme nach stündlichem Reset
- Transparente Logging-Nachrichten

## Test-Szenarien

| Szenario | Counter | Limit | Verhalten |
|----------|---------|-------|----------|
| Unter Limit | 25/28 | 28 | ✅ Import erlaubt |
| Am Limit | 28/28 | 28 | ❌ Import pausiert |
| Über Limit | 29/28 | 28 | ❌ Import pausiert |

## Vorteile

1. **Zuverlässige Limit-Einhaltung**: Verhindert Überschreitung des konfigurierten Limits
2. **Automatische Verwaltung**: Keine manuelle Intervention erforderlich
3. **Transparenz**: Klare Log-Nachrichten über Status und nächste Reset-Zeit
4. **Robustheit**: Automatische Wiederaufnahme nach Reset
5. **Performance**: Minimaler Overhead durch effiziente Datenbankabfrage

## Konfiguration
Keine zusätzliche Konfiguration erforderlich. Die Funktion nutzt die bestehenden Einstellungen:
- `mails_per_hour`: Maximale Anzahl E-Mails pro Stunde
- `load_balanced_enabled`: Aktivierung des Load-Balanced Imports

Die Limit-Prüfung ist automatisch aktiv wenn Load-Balanced Import aktiviert ist.
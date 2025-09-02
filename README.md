# Redmine Mail Handler Plugin

Ein umfassendes Plugin für Redmine 6, das erweiterte Mail-Verarbeitung mit IMAP-Support, automatischer Ticket-Zuweisung und Reminder-Funktionen bietet.

## Features

- **IMAP Mail-Import**: Automatischer Import von E-Mails über IMAP
- **Intelligente Ticket-Zuweisung**: 
  - Bekannte Absender + Ticket-ID im Betreff → Mail wird an Ticket angehängt
  - Bekannte Absender ohne Ticket-ID → Mail wird an konfigurierbares Posteingang-Ticket angehängt
  - Unbekannte Absender + Ticket-ID → Automatische Benutzer-Erstellung (deaktiviert) + Mail an Ticket
  - Unbekannte Absender ohne Ticket-ID → Mail wird ignoriert
- **Mail-Archivierung**: Automatische Archivierung verarbeiteter Mails
- **Tägliche Reminder**: Konfigurierbare Reminder-E-Mails
- **MIME-Decoding**: Vollständige Unterstützung für verschiedene Mail-Formate
- **Logging**: Umfassendes Logging mit Web-Interface
- **Test-Funktionen**: Manuelle Import-Tests und Test-E-Mails
- **Entwickler-Modus**: Manueller Import für Entwicklung und Tests

## Installation

1. Plugin in das Redmine plugins-Verzeichnis kopieren:
   ```bash
   cd /path/to/redmine/plugins
   git clone https://github.com/your-repo/redmine_mail_handler.git
   ```

2. Abhängigkeiten installieren:
   ```bash
   cd redmine_mail_handler
   bundle install
   ```

3. Datenbank migrieren:
   ```bash
   cd /path/to/redmine
   bundle exec rake redmine:plugins:migrate RAILS_ENV=production
   ```

4. Redmine neu starten

## Konfiguration

1. Als Administrator in Redmine anmelden
2. Zu "Administration" → "Plugins" → "Redmine Mail Handler" → "Konfiguration" navigieren
3. IMAP-Einstellungen konfigurieren:
   - IMAP-Server und Port
   - Benutzername und Passwort
   - SSL-Einstellungen
   - Posteingang- und Archiv-Ordner
4. Posteingang-Ticket-ID festlegen
5. Reminder-Zeit konfigurieren
6. Import-Intervall einstellen

## Verwendung

### Automatischer Mail-Import
Das Plugin importiert automatisch E-Mails basierend auf dem konfigurierten Intervall.

### Manueller Import (Entwickler-Modus)
1. Automatischen Import deaktivieren
2. Zu "Administration" → "Mail Handler" navigieren
3. Anzahl der zu importierenden Mails festlegen
4. "Manuellen Import starten" klicken

### Test-Funktionen
- **Test-E-Mail senden**: E-Mail an angegebene Adresse senden
- **Reminder-Test**: Test-Reminder-E-Mail senden
- **IMAP-Verbindung testen**: Verbindung zu IMAP-Server testen

### Logs anzeigen
Zu "Administration" → "Mail Handler" → "Logs" navigieren, um alle Mail-Verarbeitungs-Logs anzuzeigen.

## Systemanforderungen

- Redmine 6.0.0 oder höher
- Ruby 3.0 oder höher
- IMAP-fähiger E-Mail-Server

## Lizenz

MIT License

## Support

Bei Problemen oder Fragen erstellen Sie bitte ein Issue im GitHub-Repository.
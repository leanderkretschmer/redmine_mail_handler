# Installation und Konfiguration - Redmine Mail Handler Plugin

## Systemanforderungen

- Redmine 6.0.0 oder höher
- Ruby 3.0 oder höher
- IMAP-fähiger E-Mail-Server
- Zugriff auf Redmine-Datenbank für Migrationen

## Installation

### 1. Plugin herunterladen

```bash
cd /path/to/redmine/plugins
git clone https://github.com/your-repo/redmine_mail_handler.git
```

### 2. Abhängigkeiten installieren

```bash
cd redmine_mail_handler
bundle install
```

### 3. Datenbank migrieren

```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

### 4. Plugin installieren (optional)

```bash
bundle exec rake redmine:mail_handler:install RAILS_ENV=production
```

### 5. Redmine neu starten

```bash
# Für Passenger
touch tmp/restart.txt

# Für andere Server
sudo systemctl restart redmine
# oder
sudo service redmine restart
```

## Konfiguration

### 1. Plugin-Einstellungen

1. Als Administrator in Redmine anmelden
2. Navigieren zu: **Administration** → **Plugins** → **Redmine Mail Handler** → **Konfiguration**
3. Folgende Einstellungen konfigurieren:

#### IMAP-Einstellungen
- **IMAP-Server**: Hostname Ihres IMAP-Servers (z.B. `imap.gmail.com`)
- **Port**: IMAP-Port (Standard: 993 für SSL, 143 für unverschlüsselt)
- **SSL verwenden**: Aktivieren für verschlüsselte Verbindungen
- **Benutzername**: E-Mail-Adresse oder Benutzername
- **Passwort**: Passwort für den E-Mail-Account
- **Posteingang-Ordner**: Ordner für eingehende E-Mails (Standard: `INBOX`)
- **Archiv-Ordner**: Ordner für verarbeitete E-Mails (z.B. `Archive`)

#### Ticket-Einstellungen
- **Posteingang-Ticket-ID**: ID eines existierenden Tickets für E-Mails ohne Ticket-Referenz

#### Reminder-Einstellungen
- **Tägliche Reminder aktiviert**: Aktiviert automatische Reminder-E-Mails
- **Reminder-Zeit**: Uhrzeit für tägliche Reminder (Format: HH:MM)

#### Import-Einstellungen
- **Automatischer Import aktiviert**: Aktiviert automatischen E-Mail-Import
- **Import-Intervall**: Intervall in Minuten für automatischen Import

#### Logging-Einstellungen
- **Log-Level**: Detailgrad der Logs (Debug, Info, Warning, Error)

### 2. E-Mail-Server Konfiguration

#### Gmail
```
IMAP-Server: imap.gmail.com
Port: 993
SSL: Ja
Benutzername: ihre-email@gmail.com
Passwort: App-spezifisches Passwort (nicht das normale Gmail-Passwort)
```

**Hinweis**: Für Gmail müssen Sie ein App-spezifisches Passwort erstellen:
1. Google-Konto → Sicherheit → 2-Faktor-Authentifizierung
2. App-Passwörter → Mail → Passwort generieren

#### Microsoft 365/Outlook
```
IMAP-Server: outlook.office365.com
Port: 993
SSL: Ja
Benutzername: ihre-email@domain.com
Passwort: Ihr Passwort
```

#### Andere E-Mail-Provider
Konsultieren Sie die Dokumentation Ihres E-Mail-Providers für IMAP-Einstellungen.

### 3. Posteingang-Ticket erstellen

1. Erstellen Sie ein neues Ticket in Redmine
2. Notieren Sie sich die Ticket-ID (z.B. #123)
3. Tragen Sie diese ID in den Plugin-Einstellungen unter "Posteingang-Ticket-ID" ein

## Erste Schritte

### 1. Verbindung testen

1. Navigieren zu: **Administration** → **Mail Handler**
2. Klicken Sie auf "IMAP-Verbindung testen"
3. Überprüfen Sie die Erfolgsmeldung

### 2. Test-E-Mail senden

1. Geben Sie eine Test-E-Mail-Adresse ein
2. Klicken Sie auf "Test-E-Mail senden"
3. Überprüfen Sie den Empfang der E-Mail

### 3. Manuellen Import testen

1. Senden Sie eine Test-E-Mail an Ihren konfigurierten E-Mail-Account
2. Verwenden Sie das Format: `Betreff: Test [#TICKET_ID]`
3. Führen Sie einen manuellen Import durch
4. Überprüfen Sie, ob die E-Mail dem Ticket hinzugefügt wurde

## Verwendung

### E-Mail-Formate

Das Plugin verarbeitet E-Mails basierend auf folgenden Regeln:

1. **Bekannter Absender + Ticket-ID im Betreff** `[#123]`
   - E-Mail wird an Ticket #123 angehängt
   
2. **Bekannter Absender ohne Ticket-ID**
   - E-Mail wird an das konfigurierte Posteingang-Ticket angehängt
   
3. **Unbekannter Absender + Ticket-ID im Betreff** `[#123]`
   - Neuer Benutzer wird erstellt (deaktiviert)
   - E-Mail wird an Ticket #123 angehängt
   
4. **Unbekannter Absender ohne Ticket-ID**
   - E-Mail wird ignoriert und archiviert

### Kommandozeilen-Tools

```bash
# Status anzeigen
bundle exec rake redmine:mail_handler:status

# Manueller Import
bundle exec rake redmine:mail_handler:import[10]

# Verbindung testen
bundle exec rake redmine:mail_handler:test_connection

# Scheduler starten/stoppen
bundle exec rake redmine:mail_handler:start_scheduler
bundle exec rake redmine:mail_handler:stop_scheduler

# Logs anzeigen
bundle exec rake redmine:mail_handler:show_logs[20]

# Alte Logs löschen
bundle exec rake redmine:mail_handler:cleanup_logs
```

## Fehlerbehebung

### Häufige Probleme

1. **IMAP-Verbindung fehlgeschlagen**
   - Überprüfen Sie Server, Port und SSL-Einstellungen
   - Testen Sie die Anmeldedaten in einem E-Mail-Client
   - Prüfen Sie Firewall-Einstellungen

2. **E-Mails werden nicht importiert**
   - Überprüfen Sie die Logs unter Administration → Mail Handler → Logs
   - Stellen Sie sicher, dass der Scheduler läuft
   - Prüfen Sie die Ordner-Namen (INBOX, Archive)

3. **Scheduler startet nicht**
   - Überprüfen Sie die Redmine-Logs
   - Stellen Sie sicher, dass alle Abhängigkeiten installiert sind
   - Starten Sie Redmine neu

4. **Benutzer werden nicht erstellt**
   - Überprüfen Sie die Berechtigungen für Benutzer-Erstellung
   - Prüfen Sie die Logs auf Fehlermeldungen

### Log-Dateien

- **Plugin-Logs**: Administration → Mail Handler → Logs
- **Redmine-Logs**: `log/production.log` (oder entsprechende Umgebung)
- **System-Logs**: `/var/log/redmine/` (je nach Installation)

### Debug-Modus

1. Setzen Sie Log-Level auf "Debug"
2. Führen Sie einen manuellen Import durch
3. Überprüfen Sie die detaillierten Logs

## Deinstallation

```bash
# Plugin deinstallieren
bundle exec rake redmine:mail_handler:uninstall RAILS_ENV=production

# Datenbank-Migrationen rückgängig machen
bundle exec rake redmine:plugins:migrate NAME=redmine_mail_handler VERSION=0 RAILS_ENV=production

# Plugin-Verzeichnis löschen
rm -rf plugins/redmine_mail_handler

# Redmine neu starten
touch tmp/restart.txt
```

## Support

Bei Problemen:
1. Überprüfen Sie die Logs
2. Konsultieren Sie diese Dokumentation
3. Erstellen Sie ein Issue im GitHub-Repository
4. Geben Sie Redmine-Version, Plugin-Version und Fehlermeldungen an
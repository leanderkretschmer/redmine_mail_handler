# Changelog

Alle wichtigen Änderungen an diesem Projekt werden in dieser Datei dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.0.0/),
und dieses Projekt folgt [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Geplant
- Unterstützung für POP3-Server
- E-Mail-Templates für Reminder
- Erweiterte Filterregeln für E-Mails
- Integration mit Redmine-Projekten
- Automatische Ticket-Erstellung basierend auf E-Mail-Inhalten

## [1.0.0] - 2024-01-XX

### Hinzugefügt
- **Grundlegende Mail-Handler-Funktionalität**
  - IMAP-Verbindung und E-Mail-Import
  - Intelligente Ticket-Zuweisung basierend auf Betreff und Absender
  - Automatische Benutzer-Erstellung für unbekannte Absender
  - MIME-Decoding für E-Mail-Inhalte
  
- **Scheduler-System**
  - Automatischer E-Mail-Import in konfigurierbaren Intervallen
  - Tägliche Reminder-E-Mails für überfällige Tickets
  - Scheduler-Kontrolle über Web-Interface
  
- **Logging-System**
  - Umfassendes Logging aller Mail-Handler-Aktivitäten
  - Web-Interface zur Log-Anzeige mit Filterung und Pagination
  - Log-Export als CSV
  - Automatische Log-Bereinigung
  
- **Administration-Interface**
  - Konfigurationsseite für alle Plugin-Einstellungen
  - IMAP-Verbindungstest
  - Test-E-Mail-Funktionen
  - Manueller E-Mail-Import
  - System-Status-Anzeige
  
- **Test-Funktionen**
  - IMAP-Verbindungstest
  - Test-E-Mail-Versand
  - Test-Reminder-Versand
  - Manueller Import mit Limit-Option
  
- **Entwickler-Features**
  - Rake-Tasks für alle wichtigen Funktionen
  - Umfassende Test-Suite
  - Mock-IMAP für Tests
  - Plugin-Hooks für Erweiterungen
  
- **Internationalisierung**
  - Deutsche Übersetzung (vollständig)
  - Englische Übersetzung (vollständig)
  - Erweiterbare Lokalisierung
  
- **E-Mail-Verarbeitungsregeln**
  - Bekannter Absender + Ticket-ID → An Ticket anhängen
  - Bekannter Absender ohne Ticket-ID → An Posteingang-Ticket anhängen
  - Unbekannter Absender + Ticket-ID → Benutzer erstellen + An Ticket anhängen
  - Unbekannter Absender ohne Ticket-ID → E-Mail ignorieren
  - Automatische Archivierung verarbeiteter E-Mails
  
- **Konfigurierbare Einstellungen**
  - IMAP-Server-Konfiguration (Host, Port, SSL, Anmeldedaten)
  - Posteingang- und Archiv-Ordner
  - Posteingang-Ticket-ID für E-Mails ohne Referenz
  - Reminder-Zeit und -Aktivierung
  - Auto-Import-Intervall und -Aktivierung
  - Log-Level-Konfiguration
  
- **Sicherheitsfeatures**
  - Automatische Deaktivierung auto-erstellter Benutzer
  - Sichere Passwort-Speicherung
  - Validierung aller Eingaben
  - Fehlerbehandlung für alle kritischen Operationen

### Technische Details
- **Kompatibilität**: Redmine 6.0.0+, Ruby 3.0+
- **Abhängigkeiten**: 
  - net-imap (>= 0.3.0)
  - mail (~> 2.8.0)
  - rufus-scheduler (~> 3.8.0)
  - mime-types (~> 3.4.0)
  - nokogiri (~> 1.15.0)
  - charlock_holmes (~> 0.7.7)
- **Datenbank**: Neue Tabelle `mail_handler_logs`
- **Dateien**: 25+ neue Dateien für vollständige Funktionalität

### Dokumentation
- Vollständige README mit Feature-Übersicht
- Detaillierte Installationsanleitung (INSTALL.md)
- Rake-Task-Dokumentation
- Code-Kommentare und Inline-Dokumentation
- Test-Dokumentation

### Tests
- Unit-Tests für alle Hauptklassen
- Mock-IMAP für isolierte Tests
- Test-Helper für Plugin-spezifische Tests
- Fixture-Unterstützung

## [0.1.0] - 2024-01-XX (Entwicklungsversion)

### Hinzugefügt
- Initiale Projektstruktur
- Grundlegende Plugin-Registrierung
- Erste IMAP-Verbindungsversuche

---

## Versionshinweise

### Upgrade von 0.x auf 1.0.0
1. Stoppen Sie den Redmine-Server
2. Führen Sie die Datenbank-Migration aus: `rake redmine:plugins:migrate`
3. Aktualisieren Sie die Plugin-Konfiguration
4. Starten Sie den Redmine-Server neu

### Breaking Changes
- Keine (erste stabile Version)

### Bekannte Probleme
- Gmail erfordert App-spezifische Passwörter bei aktivierter 2FA
- Sehr große E-Mail-Anhänge können zu Timeouts führen
- IMAP-Verbindungen können bei instabilen Netzwerken abbrechen

### Geplante Verbesserungen für 1.1.0
- Performance-Optimierungen für große Mailboxen
- Erweiterte E-Mail-Filter
- Unterstützung für E-Mail-Templates
- Verbesserte Fehlerbehandlung
- Dashboard-Widget für Mail-Handler-Status
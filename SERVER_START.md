# Server-Start Anleitung für Redmine Mail Handler Plugin

## Notwendige Rake-Befehle beim ersten Start

### 1. Plugin-Migration ausführen
```bash
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

### 2. Plugin installieren (optional, aber empfohlen)
```bash
bundle exec rake redmine:mail_handler:install RAILS_ENV=production
```

### 3. Redmine-Server starten
```bash
# Für Passenger (Apache/Nginx)
touch tmp/restart.txt

# Für systemd
sudo systemctl restart redmine

# Für direkte Rails-Server
bundle exec rails server -e production -p 3000
```

## Plugin-Status überprüfen
```bash
bundle exec rake redmine:mail_handler:status RAILS_ENV=production
```

## Wichtige Hinweise

1. **Erste Installation**: Führen Sie die Migration und Installation aus
2. **Updates**: Bei Plugin-Updates nur Migration ausführen
3. **Konfiguration**: Plugin-Einstellungen über Redmine-Admin-Interface konfigurieren
4. **Logs**: Plugin-Logs über das Web-Interface einsehen

## Fehlerbehebung

Falls Probleme auftreten:

1. Logs überprüfen: `tail -f log/production.log`
2. Plugin-Status prüfen: `rake redmine:mail_handler:status`
3. Plugin neu installieren: `rake redmine:mail_handler:uninstall && rake redmine:mail_handler:install`

## Entwicklungsmodus

Für Entwicklung und Tests:
```bash
# Migration für Entwicklung
bundle exec rake redmine:plugins:migrate RAILS_ENV=development

# Server für Entwicklung
bundle exec rails server -e development -p 3000
```
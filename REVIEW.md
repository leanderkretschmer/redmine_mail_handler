# Code Review 2025-09-24

Logs nicht über Datenbank-Tabelle, sondern über normales Logging-Interface handeln ggf?
- Durch seperates plugin Lösen

~~Test Reminder Button in Admin-Seite und Funktion die aufgerufen wird ist toter Code~~ ✓ ERLEDIGT
- Test-Reminder Funktionen wurden entfernt
- Bulk-Reminder Funktionen wurden als deprecated markiert und werden in einer zukünftigen Version entfernt

Fraglich ob das defered entry model notwendig ist, die Mails liegen ja eh im IMAP und wir können das vermutlich einfach darüber tracken. 
- Wird ersetzt durch imap flags die angeben wann die mail nach Defered Geschoben wurde 

Generell würde ich in Frage stellen ob wir eigene Datenbankmodelle für dieses Plugin pflegen sollten oder ob wir hier nicht einfach auf Datenbanktablellen. Wenn wir die Modelle entfernen, sollten wir eine Migration zum Löschen der Tabellen einfügen.
- Wenn Defered und logging umgesetzt ist braucht das plugin keine DB mehr

~~assets/javascripts/block_user.js ist nicht funktional, Block-User-Funktion komplett entfernen -> eigenes Plugin~~ ✓ ERLEDIGT
- Block-User JavaScript und CSS entfernt
- Block-User Controller-Aktion entfernt
- Block-User Route entfernt
- Block-User Einstellungen aus Plugin-Konfiguration entfernt
- Block-User Hooks entfernt

~~Versionierung als 0.x.y~~
- Auf version 0.3.1 geändert, Kein Major Release, 3. Grössere änderung, Minor Release

Changelog schreiben
- Comming soon ™

~~Test-Dateien entfernt~~ ✓ ERLEDIGT
- test/ Verzeichnis komplett entfernt
- mail_handler_service_test.rb entfernt
- test_helper.rb entfernt
- Tests sind für Plugin-Funktionalität nicht erforderlich

~~Möglicherweise toter Code in lib/~~ ✓ ERLEDIGT

- `deferred_scheduler.rb` - Verwendet in deferred_processing_job.rb
- `mail_handler_hooks.rb` - Redmine Hook-System (bereits bereinigt)
- `mail_handler_logger.rb` - Verwendet in Controller, Service, Scheduler, Hooks
- `mail_handler_scheduler.rb` - Verwendet in Controller, Initializer, init.rb, Rake-Tasks
- `mail_handler_service.rb` - Bereits analysiert, aktiv verwendet
- `tasks/mail_handler.rake` - Rake-Tasks für Plugin-Verwaltung

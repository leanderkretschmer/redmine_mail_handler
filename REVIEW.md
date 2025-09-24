# Code Review 2025-09-24

Logs nicht über Datenbank-Tabelle, sondern über normales Logging-Interface handeln ggf?

Test Reminder Button in Admin-Seite und Funktion die aufgerufen wird ist toter Code

Fraglich ob das defered entry model notwendig ist, die Mails liegen ja eh im IMAP und wir können das vermutlich einfach darüber tracken. 

Generell würde ich in Frage stellen ob wir eigene Datenbankmodelle für dieses Plugin pflegen sollten oder ob wir hier nicht einfach auf Datenbanktablellen. Wenn wir die Modelle entfernen, sollten wir eine Migration zum Löschen der Tabellen einfügen.

assets/javascripts/block_user.js ist nicht funktional, Block-User-Funktion komplett entfernen -> eigenes Plugin

Versionierung als 0.x.y

Changelog schreiben

Möglicherweise toter Code in lib/

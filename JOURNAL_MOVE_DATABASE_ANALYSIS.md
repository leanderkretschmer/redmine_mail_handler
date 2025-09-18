# Redmine Journal Move - Datenbankanalyse

## Datenbankstruktur für Kommentare und Anhänge

Basierend auf dem Redmine-Schema (`redmine-schema.sql`) sind die relevanten Tabellen:

### 1. Journals Tabelle
```sql
CREATE TABLE `journals` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `journalized_id` int(11) NOT NULL DEFAULT 0,     -- Issue ID
  `journalized_type` varchar(30) NOT NULL DEFAULT '', -- 'Issue'
  `user_id` int(11) NOT NULL DEFAULT 0,
  `notes` longtext DEFAULT NULL,                   -- Kommentartext
  `created_on` datetime NOT NULL,
  `updated_on` datetime DEFAULT NULL,
  `updated_by_id` int(11) DEFAULT NULL,
  `private_notes` tinyint(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  KEY `journals_journalized_id` (`journalized_id`,`journalized_type`)
)
```

### 2. Journal Details Tabelle
```sql
CREATE TABLE `journal_details` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `journal_id` int(11) NOT NULL DEFAULT 0,         -- Foreign Key zu journals.id
  `property` varchar(30) NOT NULL DEFAULT '',      -- z.B. 'attr', 'cf'
  `prop_key` varchar(30) NOT NULL DEFAULT '',      -- z.B. 'status_id', 'subject'
  `old_value` longtext DEFAULT NULL,               -- Alter Wert
  `value` longtext DEFAULT NULL,                   -- Neuer Wert
  PRIMARY KEY (`id`),
  KEY `journal_details_journal_id` (`journal_id`)
)
```

### 3. Attachments Tabelle
```sql
CREATE TABLE `attachments` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `container_id` int(11) DEFAULT NULL,             -- Issue ID oder Journal ID
  `container_type` varchar(30) DEFAULT NULL,       -- 'Issue' oder 'Journal'
  `filename` varchar(255) NOT NULL DEFAULT '',
  `disk_filename` varchar(255) NOT NULL DEFAULT '',
  `filesize` bigint(20) NOT NULL DEFAULT 0,
  `content_type` varchar(255) DEFAULT '',
  `digest` varchar(64) NOT NULL DEFAULT '',
  `downloads` int(11) NOT NULL DEFAULT 0,
  `author_id` int(11) NOT NULL DEFAULT 0,
  `created_on` datetime DEFAULT NULL,
  `description` varchar(255) DEFAULT NULL,
  `disk_directory` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `index_attachments_on_container_id_and_container_type` (`container_id`,`container_type`)
)
```

## Korrekte Verschiebung von Kommentaren und Anhängen

### Schritt 1: Journals verschieben
```ruby
# Alle Journals des ursprünglichen Issues finden
journals = Journal.where(journalized_id: source_issue_id, journalized_type: 'Issue')

# journalized_id auf neue Issue ID setzen
journals.update_all(journalized_id: target_issue_id)
```

### Schritt 2: Journal Details automatisch mitverschoben
- Journal Details sind über `journal_id` mit Journals verknüpft
- Beim Verschieben der Journals bleiben die Details automatisch korrekt zugeordnet
- **Keine separate Aktion erforderlich**

### Schritt 3: Issue-Anhänge verschieben
```ruby
# Direkte Issue-Anhänge verschieben
Attachment.where(
  container_id: source_issue_id, 
  container_type: 'Issue'
).update_all(container_id: target_issue_id)
```

### Schritt 4: Journal-Anhänge automatisch mitverschoben
- Journal-Anhänge sind über `container_type='Journal'` und `container_id=journal.id` verknüpft
- Da die Journal IDs unverändert bleiben, sind die Anhänge automatisch korrekt zugeordnet
- **Keine separate Aktion erforderlich**

## Implementierung in MailHandlerLogsController

### Korrekte move_journal Methode
```ruby
def move_journal
  journal_id = params[:journal_id]
  target_issue_id = params[:target_issue_id]
  
  journal = Journal.find(journal_id)
  target_issue = Issue.find(target_issue_id)
  original_issue_id = journal.journalized_id
  
  ActiveRecord::Base.transaction do
    # 1. Alle Journals des ursprünglichen Issues verschieben
    journals = Journal.where(journalized_id: original_issue_id, journalized_type: 'Issue')
    journals.update_all(journalized_id: target_issue.id)
    
    # 2. Direkte Issue-Anhänge verschieben
    Attachment.where(
      container_id: original_issue_id, 
      container_type: 'Issue'
    ).update_all(container_id: target_issue.id)
    
    # Journal Details und Journal-Anhänge werden automatisch mitverschoben
  end
end
```

## Vorteile dieser Implementierung

1. **Vollständige Datenintegrität**: Alle Kommentare, Änderungsdetails und Anhänge bleiben korrekt zugeordnet
2. **Effiziente Datenbankoperationen**: Verwendung von `update_all` für bessere Performance
3. **Transaktionale Sicherheit**: Alle Änderungen in einer Transaktion
4. **Automatische Verknüpfungen**: Journal Details und Journal-Anhänge werden automatisch mitverschoben
5. **Keine Datenverluste**: Alle Metadaten (Zeitstempel, Autoren, etc.) bleiben erhalten

## Unterschied zu Re-Import

### Re-Import (problematisch):
- Neue Journal IDs
- Neue Zeitstempel
- Möglicher Verlust von Formatierung
- Komplexe Anhang-Behandlung

### Direkte Datenbankverschiebung (korrekt):
- Originale Journal IDs bleiben erhalten
- Originale Zeitstempel bleiben erhalten
- Alle Formatierungen bleiben erhalten
- Anhänge bleiben automatisch korrekt zugeordnet
- Alle Relationen bleiben intakt
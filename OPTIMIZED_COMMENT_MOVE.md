# Optimierte Kommentar-Verschiebung

## Überblick

Die optimierte Kommentar-Verschiebung ersetzt die alte Journal Move Funktionalität durch eine moderne, benutzerfreundliche Lösung mit integriertem Suchfeld, Live-Suche und visuellem Feedback-System.

## Features

### 1. Plugin-Einstellung für Feature-Aktivierung
- **Einstellung**: `optimized_comment_move_enabled`
- **Standard**: Deaktiviert (`'0'`)
- **Aktivierung**: Über Admin → Plugin-Einstellungen → "Optimierte Kommentar-Verschiebung aktivieren"

### 2. Integriertes Suchfeld mit drei Suchfunktionen

#### a) Live-Suche nach Titel
- **Funktion**: Automatische Suche während der Eingabe
- **Verzögerung**: 300ms nach letzter Eingabe
- **Mindestlänge**: 2 Zeichen
- **API-Endpoint**: `POST /admin/mail_handler_logs/search_tickets`

#### b) Suche nach Ticket-ID
- **Funktion**: Direkte Suche nach numerischer Ticket-ID
- **Validierung**: Nur numerische Eingaben
- **API-Endpoint**: `POST /admin/mail_handler_logs/search_tickets`

#### c) Autorenvorschläge
- **Funktion**: Zeigt Tickets an, in denen der Kommentar-Autor bereits kommentiert hat
- **Ausschluss**: Aktuelles Ticket wird ausgeschlossen
- **API-Endpoint**: `POST /admin/mail_handler_logs/search_author_tickets`

### 3. Visuelles Feedback-System

#### Status-Indikatoren
- **Laden**: Blauer Hintergrund mit "Suche nach Tickets..." / "Verschiebe Kommentar..."
- **Erfolg**: Grüner Hintergrund mit "Kommentar erfolgreich verschoben!"
- **Fehler**: Roter Hintergrund mit spezifischer Fehlermeldung

#### Interaktive Elemente
- **Ticket-Auswahl**: Hover-Effekt und Auswahl-Highlighting
- **Button-Status**: Deaktivierung bis Ticket ausgewählt
- **Responsive Design**: Anpassung an verschiedene Bildschirmgrößen

## Technische Implementierung

### Backend-API

#### 1. Controller-Methoden (`MailHandlerLogsController`)

```ruby
# Live-Suche nach Tickets
def search_tickets
  query = params[:query].to_s.strip
  tickets = Issue.visible.where("subject LIKE ?", "%#{query}%").limit(5)
  render json: { tickets: tickets.map { |t| { id: t.id, subject: t.subject, status: t.status.name } } }
end

# Autorenvorschläge
def search_author_tickets
  journal = Journal.find_by(id: params[:journal_id])
  tickets = Issue.joins(:journals)
                 .where(journals: { user_id: journal.user_id })
                 .where.not(id: journal.journalized_id)
                 .distinct.limit(5)
  render json: { tickets: tickets.map { |t| { id: t.id, subject: t.subject, status: t.status.name } } }
end

# Kommentar verschieben
def move_comment
  journal = Journal.find_by(id: params[:journal_id])
  target_issue = Issue.find_by(id: params[:target_issue_id])
  
  ActiveRecord::Base.transaction do
    # Neues Journal erstellen
    new_journal = Journal.create!(
      journalized: target_issue,
      user: journal.user,
      notes: journal.notes,
      created_on: journal.created_on
    )
    
    # Anhänge verschieben
    journal.details.where(property: 'attachment').each do |detail|
      attachment = Attachment.find_by(id: detail.value)
      attachment&.update!(container: target_issue)
    end
    
    # Altes Journal löschen
    journal.destroy!
    
    # Logging
    MailHandlerLog.create!(
      level: 'info',
      message: "[COMMENT-MOVE] Kommentar erfolgreich verschoben",
      details: { journal_id: params[:journal_id], target_issue_id: params[:target_issue_id] }.to_json
    )
  end
  
  render json: { success: true, message: 'Kommentar erfolgreich verschoben' }
end
```

#### 2. Routen (`config/routes.rb`)

```ruby
resources :mail_handler_logs, :only => [:index, :show] do
  collection do
    get :export
    post :search_tickets
    post :search_author_tickets
    post :move_comment
  end
end
```

#### 3. Berechtigungsprüfung

```ruby
before_action :check_comment_move_enabled, only: [:search_tickets, :search_author_tickets, :move_comment]

private

def check_comment_move_enabled
  unless Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
    render json: { success: false, error: 'Kommentar-Verschiebung ist nicht aktiviert' }
    return false
  end
end
```

### Frontend-Integration

#### 1. Redmine Hooks (`lib/mail_handler_hooks.rb`)

```ruby
# Hook für Issue-Ansicht - Dialog einbinden
def view_issues_show_description_bottom(context = {})
  controller = context[:controller]
  if controller && Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
    controller.render_to_string(partial: 'issues/optimized_comment_move', locals: {})
  else
    ''
  end
end

# Hook für Journal-Kommentare - Verschieben-Link hinzufügen
def view_journals_notes_form_after(context = {})
  journal = context[:journal]
  if journal && journal.notes.present? && 
     Setting.plugin_redmine_mail_handler['optimized_comment_move_enabled'] == '1'
    
    link_html = %{
      <div class="journal-move-link" style="margin-top: 10px;">
        <a href="#" class="optimized-move-comment" data-journal-id="#{journal.id}">
          <span class="icon icon-move"></span> Kommentar verschieben
        </a>
      </div>
    }
    link_html.html_safe
  else
    ''
  end
end
```

#### 2. View-Template (`app/views/issues/_optimized_comment_move.html.erb`)

Das Template enthält:
- **HTML-Struktur**: Suchfeld, Ergebnisliste, Status-Indikator, Action-Buttons
- **CSS-Styling**: Responsive Design mit Redmine-kompatiblen Farben
- **JavaScript-Logik**: Event-Handler, AJAX-Requests, DOM-Manipulation

## Benutzerführung

### 1. Aktivierung
1. Admin → Plugin-Einstellungen → Redmine Mail Handler
2. "Optimierte Kommentar-Verschiebung aktivieren" ankreuzen
3. Einstellungen speichern

### 2. Verwendung
1. Issue-Seite öffnen
2. Bei Kommentar auf "Kommentar verschieben" klicken
3. Suchfeld erscheint mit drei Optionen:
   - **Eingabe + Live-Suche**: Titel eingeben für automatische Suche
   - **"Nach Titel suchen"**: Manuelle Titel-Suche
   - **"Nach ID suchen"**: Direkte ID-Eingabe (nur Zahlen)
   - **"Autor-Tickets"**: Tickets des Kommentar-Autors anzeigen
4. Ticket aus Ergebnisliste auswählen
5. "Verschieben" klicken
6. Erfolgs-/Fehlermeldung abwarten
7. Seite wird automatisch neu geladen

## Sicherheit

### 1. CSRF-Schutz
- Alle AJAX-Requests verwenden CSRF-Token
- Token wird aus Meta-Tag extrahiert: `document.querySelector('meta[name="csrf-token"]')`

### 2. Berechtigungsprüfung
- `before_action :require_admin` für alle Controller-Aktionen
- Feature-spezifische Prüfung mit `check_comment_move_enabled`

### 3. Input-Validierung
- Parameter-Sanitization durch Rails
- Numerische Validierung für Ticket-IDs
- SQL-Injection-Schutz durch ActiveRecord

## Logging

### 1. Erfolgreiche Verschiebungen
```
Level: info
Message: "[COMMENT-MOVE] Kommentar erfolgreich von Ticket #123 zu Ticket #456 verschoben"
Details: {
  "journal_id": 789,
  "target_issue_id": 456,
  "user_id": 12,
  "moved_by": 1
}
```

### 2. Fehler
```
Level: error
Message: "[COMMENT-MOVE] Fehler beim Verschieben: Journal nicht gefunden"
Details: {
  "journal_id": 789,
  "target_issue_id": 456,
  "error": "Journal nicht gefunden"
}
```

## Migration von alter Journal Move Funktionalität

### Entfernte Komponenten
- ✅ `move_journal` Controller-Methode
- ✅ `perform_single_journal_move` Hilfsmethode
- ✅ `perform_copy_journal_move` Hilfsmethode
- ✅ `perform_manual_journal_move` Hilfsmethode
- ✅ Journal Move Routen (`POST /admin/mail_handler_logs/move_journal`)
- ✅ `app/views/issues/_journal_move_edit_form.html.erb`
- ✅ Plugin-Einstellungen: `journal_move_copy_mode`, `journal_copy_delete_original`, `enable_attachment_move`
- ✅ JavaScript: `simple_journal_move.js`, `simple_journal_move.css`

### Neue Komponenten
- ✅ Plugin-Einstellung: `optimized_comment_move_enabled`
- ✅ Controller-Methoden: `search_tickets`, `search_author_tickets`, `move_comment`
- ✅ View-Template: `_optimized_comment_move.html.erb`
- ✅ Redmine Hooks: `view_issues_show_description_bottom`, `view_journals_notes_form_after`
- ✅ API-Routen für AJAX-Requests

## Vorteile der neuen Lösung

### 1. Benutzerfreundlichkeit
- **Integrierte UI**: Kein separates Popup-Fenster
- **Live-Suche**: Sofortige Ergebnisse während der Eingabe
- **Visuelles Feedback**: Klare Status-Indikatoren
- **Mehrere Suchoptionen**: Flexibilität bei der Ticket-Suche

### 2. Performance
- **Begrenzte Ergebnisse**: Maximal 5 Tickets pro Suche
- **Debounced Search**: 300ms Verzögerung verhindert excessive API-Calls
- **Effiziente Queries**: Optimierte Datenbankabfragen mit Includes

### 3. Wartbarkeit
- **Modularer Aufbau**: Getrennte Verantwortlichkeiten
- **Standard-Patterns**: Verwendung von Rails-Konventionen
- **Umfassendes Logging**: Detaillierte Protokollierung für Debugging

### 4. Sicherheit
- **CSRF-Schutz**: Schutz vor Cross-Site Request Forgery
- **Admin-Berechtigung**: Nur Administratoren können Kommentare verschieben
- **Input-Validierung**: Schutz vor ungültigen Eingaben

## Troubleshooting

### 1. Feature nicht sichtbar
- **Prüfung**: Plugin-Einstellung `optimized_comment_move_enabled` aktiviert?
- **Lösung**: Admin → Plugin-Einstellungen → Checkbox aktivieren

### 2. Suche funktioniert nicht
- **Prüfung**: JavaScript-Konsole auf Fehler prüfen
- **Häufige Ursachen**: CSRF-Token fehlt, Netzwerkfehler
- **Lösung**: Seite neu laden, Netzwerkverbindung prüfen

### 3. Kommentar wird nicht verschoben
- **Prüfung**: Mail Handler Logs auf Fehlermeldungen prüfen
- **Häufige Ursachen**: Journal oder Ziel-Ticket nicht gefunden
- **Lösung**: Ticket-ID validieren, Berechtigungen prüfen

### 4. Performance-Probleme
- **Prüfung**: Anzahl der Suchergebnisse
- **Lösung**: Suchbegriff spezifischer machen, Datenbankindizes prüfen

## Zukünftige Erweiterungen

### 1. Erweiterte Suchfilter
- Suche nach Projekt
- Suche nach Status
- Suche nach Autor

### 2. Batch-Operationen
- Mehrere Kommentare gleichzeitig verschieben
- Alle Kommentare eines Issues verschieben

### 3. Undo-Funktionalität
- Rückgängigmachen von Verschiebungen
- Verschiebungshistorie

### 4. Benachrichtigungen
- E-Mail-Benachrichtigungen bei Verschiebungen
- In-App-Notifications

## Fazit

Die optimierte Kommentar-Verschiebung bietet eine moderne, benutzerfreundliche Alternative zur alten Journal Move Funktionalität. Durch die Integration in Redmine's Hook-System, umfassendes visuelles Feedback und eine intuitive Benutzeroberfläche wird die Produktivität der Administratoren erheblich gesteigert.

Die Lösung folgt bewährten Praktiken für Sicherheit, Performance und Wartbarkeit und bietet eine solide Grundlage für zukünftige Erweiterungen.
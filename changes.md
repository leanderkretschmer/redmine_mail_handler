# Mail Handler Plugin - Änderungsübersicht

## Version 2.3.0: Multithreading für den Mail-Import

Diese Version führt eine signifikante Leistungsverbesserung für den E-Mail-Importprozess durch die Implementierung von Multithreading ein. Anstatt E-Mails nacheinander zu verarbeiten, kann das Plugin nun mehrere E-Mails parallel abrufen und verarbeiten, was die Importzeit drastisch reduziert.

### Neue Funktionen und Änderungen

- **Parallele E-Mail-Verarbeitung:** Der Kern des Importprozesses wurde neugestaltet, um einen Thread-Pool zu nutzen. Dies ermöglicht die gleichzeitige Verarbeitung mehrerer E-Mails.
- **Drei-Phasen-Import:** Der Importprozess ist nun in drei Phasen unterteilt, um die Effizienz zu maximieren und Konflikte zu minimieren:
  1.  **Massenabruf:** Alle ungelesenen E-Mails werden in einem einzigen Schritt abgerufen.
  2.  **Parallele Verarbeitung:** Der Inhalt jeder E-Mail wird in einem separaten Thread verarbeitet.
  3.  **Massenarchivierung:** Alle erfolgreich verarbeiteten E-Mails werden in einem Stapel archiviert.
- **Neue Konfigurationseinstellungen:** Es wurden neue Einstellungen hinzugefügt, um die Multithreading-Funktion zu steuern:
  - **Multithreading aktivieren:** Aktiviert oder deaktiviert die parallele Verarbeitung.
  - **Anzahl der Threads:** Definiert die Anzahl der Threads, die für den Import verwendet werden sollen.

### Änderungen für Systemadministratoren

#### Redmine-Konfiguration

1.  **Plugin-Einstellungen aktualisieren:**
    - Navigieren Sie zu `Administration -> Plugins -> Redmine Mail Handler -> Konfigurieren`.
    - Im neuen Abschnitt **Performance-Einstellungen** können Sie die folgenden Optionen konfigurieren:
      - **Multithreading aktivieren:** Setzen Sie dieses Häkchen, um die neue Funktion zu nutzen.
      - **Anzahl der Threads:** Passen Sie die Anzahl der zu verwendenden Threads an.

2.  **Empfehlungen zur Thread-Anzahl:**
    - **Standard:** Der Standardwert ist `4` Threads, was für die meisten Setups ein guter Ausgangspunkt ist.
    - **Empfehlung:** Für eine optimale Leistung wird empfohlen, die Anzahl der Threads auf die **Anzahl der CPU-Kerne** des Servers einzustellen, auf dem Redmine läuft. Wenn Ihr Server beispielsweise 8 CPU-Kerne hat, setzen Sie diesen Wert auf `8`.
    - **Vorsicht:** Eine zu hohe Anzahl an Threads kann zu einer übermäßigen CPU- und Datenbankauslastung führen. Überwachen Sie die Systemleistung nach der Änderung dieser Einstellung.

#### Neustart erforderlich

- **WICHTIG:** Nachdem Sie die Multithreading-Einstellungen aktiviert oder geändert haben, ist ein **Neustart des Redmine-Anwendungsservers** (z.B. Puma, Unicorn, Passenger) erforderlich, damit die Änderungen wirksam werden. Ein einfacher Neustart über die Redmine-Oberfläche ist nicht ausreichend.

#### Überwachung

- Überwachen Sie nach der Aktivierung des Multithreadings die CPU- und Speicherauslastung Ihres Redmine-Servers während des E-Mail-Imports, um sicherzustellen, dass das System stabil bleibt.
- Überprüfen Sie die Plugin-Logs unter `Administration -> Mail Handler -> Logs`, um den Importprozess zu verfolgen und eventuelle Fehler zu identifizieren.

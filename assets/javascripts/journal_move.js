/* Journal Move Funktionalität - JavaScript */

(function() {
  'use strict';
  
  // Warte bis DOM geladen ist
  document.addEventListener('DOMContentLoaded', function() {
    console.log('Journal Move: DOM loaded, checking for feature activation');
    
    // Prüfe ob Feature aktiviert ist
    if (typeof window.mailHandlerJournalMoveEnabled === 'undefined' || !window.mailHandlerJournalMoveEnabled) {
      console.log('Journal Move: Feature nicht aktiviert');
      return;
    }
    
    console.log('Journal Move: Feature aktiviert, initialisiere Funktionalität');
    initJournalMoveFeature();
  });
  
  function initJournalMoveFeature() {
    // Finde alle bestehenden Journal-Einträge und füge Move-Funktionalität hinzu
    addMoveButtonsToExistingJournals();
    
    // Finde das Journal-Edit-Formular für neue Kommentare
    const journalForm = document.querySelector('form#issue-form');
    if (journalForm) {
      console.log('Journal Move: Journal-Formular gefunden, füge Event-Listener hinzu');
      
      // Füge Submit-Event-Listener hinzu
      journalForm.addEventListener('submit', function(event) {
        const targetTicketInput = document.getElementById('target_ticket_id');
        if (!targetTicketInput) {
          console.log('Journal Move: Target-Ticket-Input nicht gefunden');
          return; // Normaler Submit
        }
        
        const targetTicketId = targetTicketInput.value.trim();
        if (!targetTicketId) {
          console.log('Journal Move: Keine Ziel-Ticket-ID angegeben, normaler Submit');
          return; // Normaler Submit
        }
        
        // Verhindere normalen Submit
        event.preventDefault();
        console.log('Journal Move: Ziel-Ticket-ID angegeben:', targetTicketId);
        
        // Validiere Ticket-ID
        if (!/^\d+$/.test(targetTicketId)) {
          alert('Bitte geben Sie eine gültige Ticket-ID (nur Zahlen) ein.');
          return;
        }
        
        // Hole Journal-Text
        const notesTextarea = document.getElementById('issue_notes');
        if (!notesTextarea || !notesTextarea.value.trim()) {
          alert('Bitte geben Sie einen Kommentar ein, bevor Sie ihn verschieben.');
          return;
        }
        
        const journalText = notesTextarea.value.trim();
        
        // Bestätigungsdialog
        if (!confirm(`Sind Sie sicher, dass Sie diesen Kommentar zu Ticket #${targetTicketId} verschieben möchten?\n\nDer Kommentar und alle Anhänge des aktuellen Tickets werden verschoben.\n\nDiese Aktion kann nicht rückgängig gemacht werden!`)) {
          return;
        }
        
        // Führe Move-Operation aus
        moveJournalToTicket(targetTicketId, journalText, journalForm);
      });
    }
  }
  
  function addMoveButtonsToExistingJournals() {
    // Finde alle Journal-Einträge auf der Seite
    const journals = document.querySelectorAll('.journal');
    
    journals.forEach(function(journal) {
      // Prüfe ob Journal Notizen hat
      const notesDiv = journal.querySelector('.journal-notes');
      if (!notesDiv || !notesDiv.textContent.trim()) {
        return; // Kein Kommentar-Text
      }
      
      // Extrahiere Journal-ID aus dem Journal-Element
      const journalId = journal.id ? journal.id.replace('change-', '') : null;
      if (!journalId) {
        return; // Keine Journal-ID gefunden
      }
      
      // Prüfe ob bereits ein Move-Button existiert
      if (journal.querySelector('.journal-move-button')) {
        return; // Button bereits vorhanden
      }
      
      // Erstelle Move-Button
      const moveButton = document.createElement('a');
      moveButton.href = '#';
      moveButton.className = 'journal-move-button';
      moveButton.textContent = 'Verschieben';
      moveButton.style.marginLeft = '10px';
      moveButton.style.fontSize = '11px';
      
      // Füge Click-Event hinzu
      moveButton.addEventListener('click', function(event) {
        event.preventDefault();
        showMoveDialog(journalId, notesDiv.textContent.trim());
      });
      
      // Füge Button zu Journal-Actions hinzu
      const journalActions = journal.querySelector('.journal-actions');
      if (journalActions) {
        journalActions.appendChild(moveButton);
      }
    });
  }
  
  function showMoveDialog(journalId, journalText) {
    const targetTicketId = prompt('Geben Sie die Ziel-Ticket-ID ein:');
    
    if (!targetTicketId) {
      return; // Abgebrochen
    }
    
    // Validiere Ticket-ID
    if (!/^\d+$/.test(targetTicketId.trim())) {
      alert('Bitte geben Sie eine gültige Ticket-ID (nur Zahlen) ein.');
      return;
    }
    
    // Bestätigungsdialog
    if (!confirm(`Sind Sie sicher, dass Sie diesen Kommentar zu Ticket #${targetTicketId} verschieben möchten?\n\nDer Kommentar und alle Anhänge werden verschoben.\n\nDiese Aktion kann nicht rückgängig gemacht werden!`)) {
      return;
    }
    
    // Führe direkte Move-Operation aus
    moveExistingJournal(journalId, targetTicketId.trim());
  }
  
  function moveExistingJournal(journalId, targetTicketId) {
    console.log('Journal Move: Verschiebe bestehendes Journal', journalId, 'zu Ticket', targetTicketId);
    
    // Direkte Move-Operation ohne temporäres Journal
    moveJournalWithAttachments(journalId, targetTicketId)
      .then(function(result) {
        console.log('Journal Move: Move-Operation erfolgreich:', result);
        alert('Kommentar wurde erfolgreich verschoben!');
        // Leite zur Ziel-Ticket-Seite weiter
        window.location.href = `/issues/${targetTicketId}`;
      })
      .catch(function(error) {
        console.error('Journal Move: Fehler bei Move-Operation:', error);
        alert('Fehler beim Verschieben des Kommentars: ' + error.message);
      });
  }
  
  function moveJournalToTicket(targetTicketId, journalText, originalForm) {
    console.log('Journal Move: Starte Move-Operation zu Ticket', targetTicketId);
    
    // Zeige Loading-Indikator
    const submitButton = originalForm.querySelector('input[type="submit"]');
    const originalButtonText = submitButton ? submitButton.value : '';
    if (submitButton) {
      submitButton.value = 'Verschiebe...';
      submitButton.disabled = true;
    }
    
    // Hole aktuelle Issue-ID aus der URL
    const currentIssueId = getCurrentIssueId();
    if (!currentIssueId) {
      alert('Fehler: Aktuelle Ticket-ID konnte nicht ermittelt werden.');
      resetSubmitButton(submitButton, originalButtonText);
      return;
    }
    
    // Erstelle temporäres Journal im aktuellen Ticket
    createTemporaryJournal(currentIssueId, journalText)
      .then(function(journalId) {
        console.log('Journal Move: Temporäres Journal erstellt:', journalId);
        // Verschiebe das Journal
        return moveJournalWithAttachments(journalId, targetTicketId);
      })
      .then(function(result) {
        console.log('Journal Move: Move-Operation erfolgreich:', result);
        alert('Kommentar wurde erfolgreich verschoben!');
        // Leite zur Ziel-Ticket-Seite weiter
        window.location.href = `/issues/${targetTicketId}`;
      })
      .catch(function(error) {
        console.error('Journal Move: Fehler bei Move-Operation:', error);
        alert('Fehler beim Verschieben des Kommentars: ' + error.message);
        resetSubmitButton(submitButton, originalButtonText);
      });
  }
  
  function getCurrentIssueId() {
    // Extrahiere Issue-ID aus der URL
    const match = window.location.pathname.match(/\/issues\/(\d+)/);
    return match ? match[1] : null;
  }
  
  function createTemporaryJournal(issueId, notes) {
    return new Promise(function(resolve, reject) {
      const xhr = new XMLHttpRequest();
      xhr.open('PUT', `/issues/${issueId}.json`, true);
      xhr.setRequestHeader('Content-Type', 'application/json');
      xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
      
      // CSRF-Token hinzufügen
      const csrfToken = document.querySelector('meta[name="csrf-token"]');
      if (csrfToken) {
        xhr.setRequestHeader('X-CSRF-Token', csrfToken.getAttribute('content'));
      }
      
      xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
          if (xhr.status === 200 || xhr.status === 204) {
            // Hole das neueste Journal des Tickets
            getLatestJournalId(issueId)
              .then(resolve)
              .catch(reject);
          } else {
            reject(new Error('Fehler beim Erstellen des temporären Journals'));
          }
        }
      };
      
      const data = {
        issue: {
          notes: notes
        }
      };
      
      xhr.send(JSON.stringify(data));
    });
  }
  
  function getLatestJournalId(issueId) {
    return new Promise(function(resolve, reject) {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', `/issues/${issueId}.json?include=journals`, true);
      xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
      
      xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
          if (xhr.status === 200) {
            try {
              const response = JSON.parse(xhr.responseText);
              const journals = response.issue.journals;
              if (journals && journals.length > 0) {
                // Finde das neueste Journal mit Notizen
                const latestJournal = journals
                  .filter(function(j) { return j.notes && j.notes.trim(); })
                  .pop();
                if (latestJournal) {
                  resolve(latestJournal.id);
                } else {
                  reject(new Error('Kein Journal mit Notizen gefunden'));
                }
              } else {
                reject(new Error('Keine Journals gefunden'));
              }
            } catch (e) {
              reject(new Error('Fehler beim Parsen der Journal-Daten'));
            }
          } else {
            reject(new Error('Fehler beim Abrufen der Journal-Daten'));
          }
        }
      };
      
      xhr.send();
    });
  }
  
  function moveJournalWithAttachments(journalId, targetTicketId) {
    return new Promise(function(resolve, reject) {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/admin/mail_handler_admin/move_journal_with_attachments', true);
      xhr.setRequestHeader('Content-Type', 'application/json');
      xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
      
      // CSRF-Token hinzufügen
      const csrfToken = document.querySelector('meta[name="csrf-token"]');
      if (csrfToken) {
        xhr.setRequestHeader('X-CSRF-Token', csrfToken.getAttribute('content'));
      }
      
      xhr.onreadystatechange = function() {
        if (xhr.readyState === 4) {
          if (xhr.status === 200) {
            try {
              const response = JSON.parse(xhr.responseText);
              if (response.success) {
                resolve(response);
              } else {
                reject(new Error(response.error || 'Unbekannter Fehler'));
              }
            } catch (e) {
              reject(new Error('Fehler beim Parsen der Server-Antwort'));
            }
          } else {
            reject(new Error('Server-Fehler beim Verschieben des Journals'));
          }
        }
      };
      
      const data = {
        journal_id: journalId,
        target_ticket_id: targetTicketId
      };
      
      xhr.send(JSON.stringify(data));
    });
  }
  
  function resetSubmitButton(button, originalText) {
    if (button) {
      button.value = originalText;
      button.disabled = false;
    }
  }
  
})();
// Einfache Journal-Verschiebung
document.addEventListener('DOMContentLoaded', function() {
  console.log('Journal Move Script geladen');
  
  // Prüfe ob Feature aktiviert ist
  if (typeof window.mailHandlerJournalMoveEnabled === 'undefined') {
    console.log('Journal Move Feature nicht aktiviert');
    return;
  }
  
  console.log('Journal Move Feature aktiviert - füge Buttons hinzu');
  // Füge Move-Buttons zu bestehenden Journals hinzu
  addMoveButtonsToJournals();
});

function addMoveButtonsToJournals() {
  console.log('Suche nach Journal-Elementen...');
  const journals = document.querySelectorAll('.journal');
  console.log('Gefundene Journals:', journals.length);
  
  journals.forEach(function(journal) {
    const journalId = journal.id.replace('change-', '');
    console.log('Verarbeite Journal:', journalId);
    
    // Prüfe ob bereits ein Move-Button existiert
    if (journal.querySelector('.move-journal-btn')) {
      console.log('Move-Button bereits vorhanden für Journal:', journalId);
      return;
    }
    
    // Erstelle Move-Button
    const moveBtn = document.createElement('a');
    moveBtn.href = '#';
    moveBtn.className = 'move-journal-btn';
    moveBtn.textContent = 'Verschieben';
    moveBtn.style.marginLeft = '10px';
    moveBtn.style.fontSize = '11px';
    
    moveBtn.addEventListener('click', function(e) {
      e.preventDefault();
      console.log('Move-Button geklickt für Journal:', journalId);
      showMoveDialog(journalId, journal);
    });
    
    // Füge Button zu Journal-Aktionen hinzu
    const actions = journal.querySelector('.contextual');
    if (actions) {
      actions.appendChild(moveBtn);
      console.log('Move-Button hinzugefügt für Journal:', journalId);
    } else {
      console.log('Keine .contextual Aktionen gefunden für Journal:', journalId);
    }
  });
}

function showMoveDialog(journalId, journalElement) {
  // Entferne eventuell bereits existierende Dialoge
  const existingDialog = document.querySelector('.journal-move-dialog');
  if (existingDialog) {
    existingDialog.remove();
  }
  
  // Erstelle Dialog-Container
  const dialog = document.createElement('div');
  dialog.className = 'journal-move-dialog';
  dialog.innerHTML = `
    <div class="journal-move-form">
      <h4>Kommentar verschieben</h4>
      <p>Ziel-Ticket ID eingeben:</p>
      <input type="number" id="target-ticket-id" placeholder="z.B. 123" min="1" />
      <div class="journal-move-buttons">
        <button id="move-confirm-btn" class="btn-primary">Verschieben</button>
        <button id="move-cancel-btn" class="btn-secondary">Abbrechen</button>
      </div>
    </div>
  `;
  
  // Füge Dialog nach dem Journal-Element hinzu
  journalElement.appendChild(dialog);
  
  // Event-Listener für Buttons
  const confirmBtn = dialog.querySelector('#move-confirm-btn');
  const cancelBtn = dialog.querySelector('#move-cancel-btn');
  const inputField = dialog.querySelector('#target-ticket-id');
  
  // Focus auf Eingabefeld
  inputField.focus();
  
  // Enter-Taste im Eingabefeld
  inputField.addEventListener('keypress', function(e) {
    if (e.key === 'Enter') {
      confirmBtn.click();
    }
  });
  
  // Bestätigen-Button
  confirmBtn.addEventListener('click', function() {
    const targetTicketId = inputField.value.trim();
    if (!targetTicketId) {
      alert('Bitte geben Sie eine gültige Ticket-ID ein.');
      return;
    }
    
    dialog.remove();
    moveJournal(journalId, targetTicketId);
  });
  
  // Abbrechen-Button
  cancelBtn.addEventListener('click', function() {
    dialog.remove();
  });
}

function moveJournal(journalId, targetTicketId) {
  // AJAX-Request zum Verschieben
  fetch('/mail_handler_logs/move_journal', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').getAttribute('content')
    },
    body: JSON.stringify({
      journal_id: journalId,
      target_issue_id: targetTicketId
    })
  })
  .then(response => response.json())
  .then(data => {
    if (data.success) {
      alert('Kommentar erfolgreich verschoben!');
      location.reload();
    } else {
      alert('Fehler: ' + (data.message || data.error));
    }
  })
  .catch(error => {
    console.error('Error:', error);
    alert('Ein Fehler ist aufgetreten.');
  });
}
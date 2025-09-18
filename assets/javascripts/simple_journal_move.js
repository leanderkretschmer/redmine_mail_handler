// Einfache Journal-Verschiebung
document.addEventListener('DOMContentLoaded', function() {
  // Füge Move-Buttons zu bestehenden Journals hinzu
  addMoveButtonsToJournals();
});

function addMoveButtonsToJournals() {
  const journals = document.querySelectorAll('.journal');
  
  journals.forEach(function(journal) {
    const journalId = journal.id.replace('change-', '');
    
    // Prüfe ob bereits ein Move-Button existiert
    if (journal.querySelector('.move-journal-btn')) {
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
      moveJournal(journalId);
    });
    
    // Füge Button zu Journal-Aktionen hinzu
    const actions = journal.querySelector('.contextual');
    if (actions) {
      actions.appendChild(moveBtn);
    }
  });
}

function moveJournal(journalId) {
  const targetTicketId = prompt('Ziel-Ticket ID eingeben:');
  
  if (!targetTicketId || targetTicketId.trim() === '') {
    return;
  }
  
  // AJAX-Request zum Verschieben
  fetch('/admin/mail_handler_admin/move_journal', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').getAttribute('content')
    },
    body: JSON.stringify({
      journal_id: journalId,
      target_ticket_id: targetTicketId
    })
  })
  .then(response => response.json())
  .then(data => {
    if (data.success) {
      alert('Kommentar erfolgreich verschoben!');
      location.reload();
    } else {
      alert('Fehler: ' + data.error);
    }
  })
  .catch(error => {
    console.error('Error:', error);
    alert('Ein Fehler ist aufgetreten.');
  });
}
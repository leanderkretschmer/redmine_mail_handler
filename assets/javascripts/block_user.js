// Block User Funktionalität für Mail Handler Plugin

(function() {
  'use strict';
  
  // Prüfe ob Block User Feature aktiviert ist
  function isBlockUserEnabled() {
    // Diese Information muss vom Server bereitgestellt werden
    return window.mailHandlerBlockUserEnabled === true;
  }
  
  // Füge Block User Buttons zu Kommentaren hinzu
  function addBlockUserButtons() {
    if (!isBlockUserEnabled()) {
      return;
    }
    
    // Finde alle Journal-Einträge (Kommentare)
    const journals = document.querySelectorAll('.journal');
    
    journals.forEach(function(journal) {
      // Prüfe ob bereits ein Block-Button existiert
      if (journal.querySelector('.block-user-btn')) {
        return;
      }
      
      // Finde den Benutzer-Link im Journal-Header
      const userLink = journal.querySelector('.journal-link a[href*="/users/"]');
      if (!userLink) {
        return;
      }
      
      // Extrahiere Benutzer-ID aus dem Link
      const userIdMatch = userLink.href.match(/\/users\/(\d+)/);
      if (!userIdMatch) {
        return;
      }
      
      const userId = userIdMatch[1];
      const userName = userLink.textContent.trim();
      
      // Erstelle Block-Button
      const blockButton = document.createElement('button');
      blockButton.className = 'block-user-btn';
      blockButton.textContent = '🚫 Block';
      blockButton.title = `Benutzer ${userName} blockieren`;
      blockButton.setAttribute('data-user-id', userId);
      blockButton.setAttribute('data-user-name', userName);
      
      // Event-Listener für Block-Button
      blockButton.addEventListener('click', function(e) {
        e.preventDefault();
        blockUser(userId, userName, blockButton);
      });
      
      // Füge Button neben dem Benutzer-Link hinzu
      const journalHeader = journal.querySelector('.journal-link');
      if (journalHeader) {
        journalHeader.appendChild(document.createTextNode(' '));
        journalHeader.appendChild(blockButton);
      }
    });
  }
  
  // Blockiere einen Benutzer
  function blockUser(userId, userName, buttonElement) {
    if (!confirm(`Sind Sie sicher, dass Sie den Benutzer "${userName}" blockieren möchten?\n\nDies wird:\n- Den Benutzer löschen\n- Alle E-Mail-Adressen des Benutzers zur Ignore-Liste hinzufügen`)) {
      return;
    }
    
    // Deaktiviere Button während der Anfrage
    buttonElement.disabled = true;
    buttonElement.textContent = 'Blockiere...';
    
    // AJAX-Anfrage zum Blockieren des Benutzers
    fetch('/admin/mail_handler_admin/block_user', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').getAttribute('content')
      },
      body: JSON.stringify({
        user_id: userId
      })
    })
    .then(response => response.json())
    .then(data => {
      if (data.success) {
        // Erfolgsmeldung anzeigen
        alert(`Benutzer erfolgreich blockiert:\n${data.message}`);
        
        // Entferne den Block-Button und markiere den Kommentar
        buttonElement.remove();
        
        // Markiere das Journal als blockiert
        const journal = buttonElement.closest('.journal');
        if (journal) {
          journal.classList.add('blocked-user');
          const userLink = journal.querySelector('.journal-link a[href*="/users/"]');
          if (userLink) {
            userLink.style.textDecoration = 'line-through';
            userLink.style.color = '#999';
            userLink.title = 'Benutzer wurde blockiert';
          }
        }
        
        // Seite neu laden um Änderungen zu reflektieren
        setTimeout(() => {
          window.location.reload();
        }, 2000);
        
      } else {
        alert(`Fehler beim Blockieren des Benutzers:\n${data.error}`);
        
        // Button wieder aktivieren
        buttonElement.disabled = false;
        buttonElement.textContent = '🚫 Block';
      }
    })
    .catch(error => {
      console.error('Fehler beim Blockieren des Benutzers:', error);
      alert('Ein Fehler ist aufgetreten. Bitte versuchen Sie es erneut.');
      
      // Button wieder aktivieren
      buttonElement.disabled = false;
      buttonElement.textContent = '🚫 Block';
    });
  }
  
  // Initialisiere die Funktionalität
  function init() {
    // Füge Buttons beim Laden der Seite hinzu
    addBlockUserButtons();
    
    // Beobachte DOM-Änderungen für dynamisch geladene Inhalte
    const observer = new MutationObserver(function(mutations) {
      let shouldUpdate = false;
      
      mutations.forEach(function(mutation) {
        if (mutation.type === 'childList') {
          mutation.addedNodes.forEach(function(node) {
            if (node.nodeType === Node.ELEMENT_NODE && 
                (node.classList.contains('journal') || node.querySelector('.journal'))) {
              shouldUpdate = true;
            }
          });
        }
      });
      
      if (shouldUpdate) {
        setTimeout(addBlockUserButtons, 100);
      }
    });
    
    // Starte Beobachtung
    observer.observe(document.body, {
      childList: true,
      subtree: true
    });
  }
  
  // Starte Initialisierung wenn DOM bereit ist
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
  
})();
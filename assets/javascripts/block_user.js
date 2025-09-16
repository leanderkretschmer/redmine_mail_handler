// Block User Funktionalität für Mail Handler Plugin

(function() {
  'use strict';
  
  // Prüfe ob Block User Feature aktiviert ist
  function isBlockUserEnabled() {
    return window.mailHandlerBlockUserEnabled === true;
  }
  
  // Füge Block User Buttons zu Kommentaren hinzu
  function addBlockUserButtons() {
    if (!isBlockUserEnabled()) {
      console.log('Block User Feature ist nicht aktiviert');
      return;
    }
    
    console.log('Suche nach Journal-Einträgen...');
    
    // Erweiterte Selektoren für verschiedene Redmine-Versionen und HTML-Strukturen
    const journalSelectors = [
      '.journal',
      '#history .journal',
      '.journal.has-notes',
      '.journal.has-details',
      'div[id^="change-"]',
      '.changeset'
    ];
    
    let journals = [];
    journalSelectors.forEach(selector => {
      const found = document.querySelectorAll(selector);
      found.forEach(journal => {
        if (!journals.includes(journal)) {
          journals.push(journal);
        }
      });
    });
    
    console.log(`Gefundene Journals: ${journals.length}`);
    
    journals.forEach(function(journal) {
      // Prüfe ob bereits ein Block-Button existiert
      if (journal.querySelector('.block-user-btn')) {
        return;
      }
      
      // Erweiterte Suche nach Benutzer-Links mit verschiedenen Selektoren
      const userLinkSelectors = [
        '.journal-link a[href*="/users/"]',
        'h4 a[href*="/users/"]',
        '.user a[href*="/users/"]',
        'a[href*="/users/"]',
        '.author a[href*="/users/"]',
        '.journal-user a[href*="/users/"]'
      ];
      
      let userLink = null;
      for (const selector of userLinkSelectors) {
        userLink = journal.querySelector(selector);
        if (userLink) {
          console.log(`Benutzer-Link gefunden mit Selektor: ${selector}`);
          break;
        }
      }
      
      if (!userLink) {
        console.log('Kein Benutzer-Link gefunden in Journal:', journal);
        return;
      }
      
      // Extrahiere Benutzer-ID aus dem Link
      const userIdMatch = userLink.href.match(/\/users\/(\d+)/);
      if (!userIdMatch) {
        console.log('Keine Benutzer-ID gefunden in Link:', userLink.href);
        return;
      }
      
      const userId = userIdMatch[1];
      const userName = userLink.textContent.trim();
      
      console.log(`Füge Block-Button für Benutzer hinzu: ${userName} (ID: ${userId})`);
      
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
      
      // Finde den besten Platz für den Button mit erweiterten Selektoren
      const insertionTargets = [
        journal.querySelector('.journal-link'),
        journal.querySelector('h4'),
        journal.querySelector('.user'),
        journal.querySelector('.author'),
        journal.querySelector('.journal-user'),
        userLink.parentNode
      ];
      
      let insertionTarget = null;
      for (const target of insertionTargets) {
        if (target) {
          insertionTarget = target;
          break;
        }
      }
      
      if (insertionTarget) {
        insertionTarget.appendChild(document.createTextNode(' '));
        insertionTarget.appendChild(blockButton);
        console.log('Block-Button erfolgreich hinzugefügt');
      } else {
        console.log('Kein geeigneter Platz für Block-Button gefunden');
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
    console.log('Block User JavaScript wird initialisiert...');
    console.log('mailHandlerBlockUserEnabled:', window.mailHandlerBlockUserEnabled);
    console.log('Current URL:', window.location.href);
    
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
        console.log('DOM-Änderung erkannt, füge Block-Buttons hinzu...');
        setTimeout(addBlockUserButtons, 100);
      }
    });
    
    // Starte Beobachtung
    observer.observe(document.body, {
      childList: true,
      subtree: true
    });
    
    // Zusätzliche Versuche für langsam ladende Inhalte
    setTimeout(() => {
      console.log('Zusätzlicher Versuch nach 1 Sekunde...');
      addBlockUserButtons();
    }, 1000);
    
    setTimeout(() => {
      console.log('Zusätzlicher Versuch nach 3 Sekunden...');
      addBlockUserButtons();
    }, 3000);
    
    // Event-Listener für AJAX-Requests (falls Redmine AJAX verwendet)
    if (typeof jQuery !== 'undefined') {
      jQuery(document).ajaxComplete(function() {
        console.log('AJAX-Request abgeschlossen, füge Block-Buttons hinzu...');
        setTimeout(addBlockUserButtons, 500);
      });
    }
  }
  
  // Starte Initialisierung wenn DOM bereit ist
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
  
})();
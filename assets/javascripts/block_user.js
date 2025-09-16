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
    
    console.log('Block User: Suche nach Kommentaren und Benutzer-Links...');
    
    // Suche nach allen Benutzer-Links auf der Seite
    const userLinks = document.querySelectorAll('a[href*="/users/"]');
    console.log(`Block User: ${userLinks.length} Benutzer-Links gefunden`);
    
    userLinks.forEach(userLink => {
      // Prüfe ob bereits ein Block-Link existiert
      if (userLink.parentNode.querySelector('.block-user-link')) {
        return;
      }
      
      // Extrahiere Benutzer-ID aus dem Link
      const userIdMatch = userLink.href.match(/\/users\/(\d+)/);
      if (userIdMatch) {
        const userId = userIdMatch[1];
        console.log(`Block User: Erstelle Block-Link für Benutzer ${userId}`);
        
        // Erstelle einfachen Text-Link "blockieren"
        const blockLink = document.createElement('a');
        blockLink.href = '#';
        blockLink.className = 'block-user-link';
        blockLink.textContent = 'blockieren';
        blockLink.title = 'Benutzer blockieren und von Import-Liste ausschließen';
        blockLink.style.marginLeft = '10px';
        blockLink.style.color = '#dc3545';
        blockLink.style.fontSize = '11px';
        blockLink.style.textDecoration = 'underline';
        
        // Event-Listener für Block-Aktion
        blockLink.addEventListener('click', function(e) {
          e.preventDefault();
          if (confirm(`Benutzer wirklich blockieren? Dies löscht den Benutzer aus Redmine und setzt ihn auf die Do-Not-Import-Liste.`)) {
            blockUser(userId, userLink.textContent.trim(), blockLink);
          }
        });
        
        // Füge den Link direkt nach dem Benutzer-Link ein
        userLink.parentNode.insertBefore(document.createTextNode(' '), userLink.nextSibling);
        userLink.parentNode.insertBefore(blockLink, userLink.nextSibling.nextSibling);
        
        console.log(`Block User: Block-Link hinzugefügt für Benutzer ${userId}`);
      }
    });
  }
  
  // Blockiere einen Benutzer
  function blockUser(userId, userName, linkElement) {
    console.log(`Blockiere Benutzer: ${userName} (ID: ${userId})`);
    
    // Ändere Link-Text während der Anfrage
    const originalText = linkElement.textContent;
    linkElement.textContent = 'blockiere...';
    linkElement.style.pointerEvents = 'none';
    
    // AJAX-Anfrage an den Server
    fetch('/admin/mail_handler_admin/block_user', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').getAttribute('content')
      },
      body: JSON.stringify({
        user_id: userId,
        user_name: userName
      })
    })
    .then(response => {
      if (response.ok) {
        return response.json();
      } else {
        throw new Error('Fehler beim Blockieren des Benutzers');
      }
    })
    .then(data => {
      console.log('Benutzer erfolgreich blockiert:', data);
      
      // Entferne den Block-Link
      linkElement.remove();
      
      // Markiere den Benutzer als blockiert
      const userLink = linkElement.parentNode.querySelector('a[href*="/users/"]');
      if (userLink) {
        userLink.style.textDecoration = 'line-through';
        userLink.style.color = '#999';
        userLink.title = 'Benutzer wurde blockiert';
        
        // Füge "(Blockiert)" Text hinzu
        const blockedText = document.createElement('span');
        blockedText.textContent = ' (Blockiert)';
        blockedText.style.color = '#dc3545';
        blockedText.style.fontSize = '11px';
        userLink.parentNode.insertBefore(blockedText, userLink.nextSibling);
      }
      
      // Zeige Erfolgsmeldung
      alert(`Benutzer ${userName} wurde erfolgreich blockiert und von der Import-Liste ausgeschlossen.`);
      
      // Lade die Seite nach kurzer Verzögerung neu
      setTimeout(() => {
        window.location.reload();
      }, 2000);
    })
    .catch(error => {
      console.error('Fehler beim Blockieren:', error);
      
      // Stelle ursprünglichen Link-Text wieder her
      linkElement.textContent = originalText;
      linkElement.style.pointerEvents = 'auto';
      
      alert('Fehler beim Blockieren des Benutzers. Bitte versuchen Sie es erneut.');
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
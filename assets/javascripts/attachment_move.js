// Attachment Move JavaScript
(function() {
  'use strict';
  
  // Prüfe ob Feature aktiviert ist
  if (typeof window.mailHandlerAttachmentMoveEnabled === 'undefined' || !window.mailHandlerAttachmentMoveEnabled) {
    console.log('Attachment Move Feature ist nicht aktiviert');
    return;
  }
  
  console.log('Attachment Move Feature wird initialisiert');
  
  // Warte bis DOM geladen ist
  document.addEventListener('DOMContentLoaded', function() {
    initAttachmentMoveFields();
  });
  
  function initAttachmentMoveFields() {
    // Finde alle Attachment-Bereiche - verschiedene Selektoren probieren
    let attachmentElements = [];
    
    // Versuche verschiedene Selektoren für Attachments
    const selectors = [
      '.attachments p',
      '.attachments div',
      '.attachments li',
      '.attachment',
      'p:has(a[href*="/attachments/"])',
      'div:has(a[href*="/attachments/"])'
    ];
    
    for (const selector of selectors) {
      try {
        const elements = document.querySelectorAll(selector);
        if (elements.length > 0) {
          attachmentElements = Array.from(elements).filter(el => 
            el.querySelector('a[href*="/attachments/"]')
          );
          if (attachmentElements.length > 0) {
            console.log(`Gefunden mit Selektor '${selector}': ${attachmentElements.length} Anhänge`);
            break;
          }
        }
      } catch (e) {
        console.log(`Selektor '${selector}' nicht unterstützt:`, e);
      }
    }
    
    if (attachmentElements.length === 0) {
      console.log('Keine Anhänge gefunden - versuche alle Links zu finden');
      const allAttachmentLinks = document.querySelectorAll('a[href*="/attachments/"]');
      console.log(`Gefundene Attachment-Links: ${allAttachmentLinks.length}`);
      
      allAttachmentLinks.forEach(link => {
        const parent = link.closest('p, div, li');
        if (parent && !attachmentElements.includes(parent)) {
          attachmentElements.push(parent);
        }
      });
    }
    
    if (attachmentElements.length === 0) {
      console.log('Keine Anhänge gefunden');
      return;
    }
    
    console.log(`${attachmentElements.length} Anhänge gefunden, füge Move-Felder hinzu`);
    
    attachmentElements.forEach(function(attachmentElement) {
      addMoveFieldToAttachment(attachmentElement);
    });
  }
  
  function addMoveFieldToAttachment(attachmentDiv) {
    // Extrahiere Attachment-ID aus dem Link
    const attachmentLink = attachmentDiv.querySelector('a[href*="/attachments/"]');
    if (!attachmentLink) {
      console.log('Kein Attachment-Link gefunden');
      return;
    }
    
    const attachmentId = extractAttachmentId(attachmentLink.href);
    if (!attachmentId) {
      console.log('Attachment-ID konnte nicht extrahiert werden');
      return;
    }
    
    // Erstelle Move-Feld
    const moveField = createMoveField(attachmentId);
    attachmentDiv.appendChild(moveField);
    
    console.log(`Move-Feld für Attachment ${attachmentId} hinzugefügt`);
  }
  
  function extractAttachmentId(href) {
    const match = href.match(/\/attachments\/(\d+)/);
    return match ? match[1] : null;
  }
  
  function createMoveField(attachmentId) {
    const moveDiv = document.createElement('div');
    moveDiv.className = 'attachment-move-field';
    moveDiv.innerHTML = `
      <label for="move_ticket_${attachmentId}">Verschieben zu Ticket:</label>
      <input type="text" id="move_ticket_${attachmentId}" placeholder="Ticket-ID" />
      <button type="button" onclick="moveAttachment(${attachmentId})">Verschieben</button>
      <span class="move-status" id="move_status_${attachmentId}"></span>
    `;
    
    return moveDiv;
  }
  
  // Globale Funktion für das Verschieben von Anhängen
  window.moveAttachment = function(attachmentId) {
    const ticketInput = document.getElementById(`move_ticket_${attachmentId}`);
    const statusSpan = document.getElementById(`move_status_${attachmentId}`);
    const button = ticketInput.nextElementSibling;
    
    const targetTicketId = ticketInput.value.trim();
    
    if (!targetTicketId || isNaN(targetTicketId)) {
      showStatus(statusSpan, 'Bitte gültige Ticket-ID eingeben', 'error');
      return;
    }
    
    // Button deaktivieren und Status anzeigen
    button.disabled = true;
    showStatus(statusSpan, 'Verschiebe...', 'loading');
    
    // AJAX-Request senden
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/admin/mail_handler_admin/move_attachment', true);
    xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
    
    // CSRF-Token hinzufügen
    const csrfToken = document.querySelector('meta[name="csrf-token"]');
    if (csrfToken) {
      xhr.setRequestHeader('X-CSRF-Token', csrfToken.getAttribute('content'));
    }
    
    xhr.onreadystatechange = function() {
      if (xhr.readyState === 4) {
        button.disabled = false;
        
        if (xhr.status === 200) {
          try {
            const response = JSON.parse(xhr.responseText);
            
            if (response.success) {
              showStatus(statusSpan, 'Erfolgreich verschoben!', 'success');
              ticketInput.value = '';
              
              // Optional: Seite nach kurzer Verzögerung neu laden
              setTimeout(function() {
                location.reload();
              }, 2000);
            } else {
              showStatus(statusSpan, response.error || 'Fehler beim Verschieben', 'error');
            }
          } catch (e) {
            showStatus(statusSpan, 'Fehler beim Verarbeiten der Antwort', 'error');
            console.error('JSON Parse Error:', e);
          }
        } else {
          showStatus(statusSpan, `HTTP-Fehler: ${xhr.status}`, 'error');
          console.error('HTTP Error:', xhr.status, xhr.statusText);
        }
      }
    };
    
    // Request-Daten
    const params = `attachment_id=${encodeURIComponent(attachmentId)}&target_ticket_id=${encodeURIComponent(targetTicketId)}`;
    xhr.send(params);
    
    console.log(`Verschiebe Attachment ${attachmentId} zu Ticket ${targetTicketId}`);
  };
  
  function showStatus(statusElement, message, type) {
    statusElement.textContent = message;
    statusElement.className = `move-status ${type}`;
    
    // Status nach 5 Sekunden ausblenden (außer bei Erfolg)
    if (type !== 'success') {
      setTimeout(function() {
        statusElement.textContent = '';
        statusElement.className = 'move-status';
      }, 5000);
    }
  }
  
  console.log('Attachment Move JavaScript geladen');
})();
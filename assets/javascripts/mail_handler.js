function toggleDebugInfo() {
  var content = document.getElementById('debug-content');
  var toggle = document.getElementById('debug-toggle');
  
  if (content.style.display === 'none') {
    content.style.display = 'block';
    toggle.textContent = '▲';
  } else {
    content.style.display = 'none';
    toggle.textContent = '▼';
  }
}

function toggleAllCheckboxes(masterCheckbox) {
  var checkboxes = document.querySelectorAll('.mail-checkbox');
  checkboxes.forEach(function(checkbox) {
    checkbox.checked = masterCheckbox.checked;
  });
}

function confirmAction(message) {
  return confirm(message);
}

function submitArchive() {
  if (!confirm('Möchten Sie die ausgewählten E-Mails wirklich archivieren?')) {
    return false;
  }
  
  // Prüfe ob mindestens eine E-Mail ausgewählt ist
  var selectedCheckboxes = document.querySelectorAll('.mail-checkbox:checked');
  if (selectedCheckboxes.length === 0) {
    alert('Bitte wählen Sie mindestens eine E-Mail aus.');
    return false;
  }
  
  // Ändere die Form-Action zum Archivieren
  var form = document.getElementById('deferred_mails_form');
  // Note: The action URL needs to be set dynamically in the view
  form.action = form.getAttribute('data-archive-url');
  
  return true;
}

function toggleFieldset(legend) {
  var fieldset = legend.parentNode;
  var div = fieldset.querySelector('div');
  if (div.style.display === 'none') {
    div.style.display = 'block';
    fieldset.classList.remove('collapsed');
  } else {
    div.style.display = 'none';
    fieldset.classList.add('collapsed');
  }
}

// Suchformular beim Laden der Seite einklappen wenn keine Suchkriterien vorhanden
document.addEventListener('DOMContentLoaded', function() {
  // Get search parameters from form data attributes
  var form = document.getElementById('deferred_mails_form');
  if (form) {
    var searchFrom = form.getAttribute('data-search-from') || '';
    var searchSubject = form.getAttribute('data-search-subject') || '';
    var fieldset = document.querySelector('.search-form fieldset');
    
    if (!searchFrom && !searchSubject && fieldset) {
      var div = fieldset.querySelector('div');
      div.style.display = 'none';
      fieldset.classList.add('collapsed');
    }
  }
});
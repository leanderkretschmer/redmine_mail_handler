/* Verteiler-Ansicht (redmine_mail_handler)
 * - passt die Hoehe an (40 % Kommentare / Rest Ziele)
 * - Drag & Drop von Kommentaren auf Ziel-Kaesten
 * - Ticket-Nr.-Eingabe und Vorschlag-Klick pro Kommentar
 * - Tracker-Fokus (nur ein Tracker als Raster)
 */
(function () {
  'use strict';

  function init() {
    var root = document.getElementById('mh-distributor');
    if (!root) return;

    var moveUrl = root.getAttribute('data-move-url');
    var readonly = root.classList.contains('mh-readonly');
    var comments = document.getElementById('mh-comments');
    var targets = document.getElementById('mh-targets');
    var toastEl = document.getElementById('mh-toast');
    var toastTimer = null;

    // ── Layout ────────────────────────────────────────────────────────────
    var main = document.getElementById('main');
    if (main) {
      main.classList.remove('collapsiblesidebar');
      main.classList.add('nosidebar', 'mh-nosidebar');
    }

    function resize() {
      var rect = root.getBoundingClientRect();
      var top = rect.top + window.pageYOffset;
      var h = window.innerHeight - top - 12;
      root.style.height = Math.max(400, h) + 'px';
    }
    resize();
    window.addEventListener('resize', resize);

    // ── Toast ─────────────────────────────────────────────────────────────
    function toast(msg, isError) {
      if (!toastEl) return;
      toastEl.textContent = msg;
      toastEl.classList.toggle('mh-toast-error', !!isError);
      toastEl.hidden = false;
      clearTimeout(toastTimer);
      toastTimer = setTimeout(function () { toastEl.hidden = true; }, isError ? 6000 : 3000);
    }

    function csrfToken() {
      var m = document.querySelector('meta[name="csrf-token"]');
      return m ? m.getAttribute('content') : '';
    }

    // ── Verschieben ───────────────────────────────────────────────────────
    function moveComment(row, targetId, dropBox) {
      if (readonly || !row || row.classList.contains('mh-busy')) return;
      targetId = String(targetId || '').trim().replace(/^#/, '');
      var input = row.querySelector('.mh-c-target');
      if (!/^\d+$/.test(targetId)) {
        if (input) { input.classList.add('mh-invalid'); input.focus(); }
        toast('Bitte eine gültige Ticket-Nummer eingeben.', true);
        return;
      }
      if (input) input.classList.remove('mh-invalid');
      row.classList.add('mh-busy');

      var body = new URLSearchParams();
      body.append('journal_id', row.getAttribute('data-journal-id'));
      body.append('target_issue_id', targetId);

      fetch(moveUrl, {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'X-CSRF-Token': csrfToken(),
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: body.toString()
      }).then(function (res) {
        return res.json().catch(function () { return { ok: false, error: 'Unerwartete Antwort (' + res.status + ')' }; });
      }).then(function (data) {
        if (!data.ok) {
          row.classList.remove('mh-busy');
          if (input) input.classList.add('mh-invalid');
          toast(data.error || 'Verschieben fehlgeschlagen.', true);
          return;
        }
        onMoved(row, data, dropBox);
      }).catch(function (err) {
        row.classList.remove('mh-busy');
        toast('Netzwerkfehler: ' + err, true);
      });
    }

    function onMoved(row, data, dropBox) {
      var t = data.target || {};
      toast('Kommentar #' + data.journal_id + ' nach #' + t.id + ' verschoben' + (t.subject ? ' (' + t.subject + ')' : ''));

      if (dropBox) {
        dropBox.classList.add('mh-drop-done');
        setTimeout(function () { dropBox.classList.remove('mh-drop-done'); }, 900);
      }

      // Zeile ausblenden und entfernen
      row.style.maxHeight = row.offsetHeight + 'px';
      // Reflow erzwingen, damit die Transition greift
      void row.offsetWidth;
      row.classList.add('mh-removing');
      setTimeout(function () {
        if (row.parentNode) row.parentNode.removeChild(row);
        updateCount();
      }, 260);

      // Vorschlaege aller Zeilen desselben Absenders aktualisieren
      var userId = String(data.user_id);
      var rows = comments.querySelectorAll('.mh-comment[data-user-id="' + userId + '"]');
      Array.prototype.forEach.call(rows, function (r) {
        if (r === row) return;
        var wrap = r.querySelector('.mh-c-suggest-wrap');
        if (!wrap) return;
        wrap.innerHTML = '';
        if (data.suggestion) {
          var a = document.createElement('a');
          a.href = '#';
          a.className = 'mh-c-suggest';
          a.setAttribute('data-target-id', data.suggestion.id);
          a.title = 'Vorschlag: bisher mehrfach nach #' + data.suggestion.id + ' verschoben – klicken zum Verschieben';
          var subj = data.suggestion.subject || '';
          if (subj.length > 40) subj = subj.substring(0, 37) + '...';
          a.textContent = '#' + data.suggestion.id + ' ' + subj;
          wrap.appendChild(a);
        }
      });
    }

    function updateCount() {
      var el = root.querySelector('.mh-count');
      if (!el) return;
      var n = comments.querySelectorAll('.mh-comment:not(.mh-removing)').length;
      el.textContent = n + ' Kommentare';
      if (n === 0 && !comments.querySelector('.mh-empty')) {
        var empty = document.createElement('div');
        empty.className = 'mh-empty';
        empty.textContent = 'Keine Kommentare in diesem Verteiler.';
        comments.appendChild(empty);
      }
    }

    // ── Eingabe / Vorschlag (Event-Delegation) ────────────────────────────
    comments.addEventListener('click', function (e) {
      var suggest = e.target.closest('.mh-c-suggest');
      if (suggest) {
        e.preventDefault();
        moveComment(suggest.closest('.mh-comment'), suggest.getAttribute('data-target-id'));
        return;
      }
      var go = e.target.closest('.mh-c-go');
      if (go) {
        var row = go.closest('.mh-comment');
        moveComment(row, row.querySelector('.mh-c-target').value);
      }
    });

    comments.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') return;
      var input = e.target.closest('.mh-c-target');
      if (!input) return;
      e.preventDefault();
      moveComment(input.closest('.mh-comment'), input.value);
    });

    comments.addEventListener('input', function (e) {
      var input = e.target.closest('.mh-c-target');
      if (input) input.classList.remove('mh-invalid');
    });

    // Eingabefeld/Buttons sollen kein Drag starten
    comments.addEventListener('mousedown', function (e) {
      var row = e.target.closest('.mh-comment');
      if (!row) return;
      if (e.target.closest('input, button, a')) {
        row.setAttribute('draggable', 'false');
      } else if (!readonly) {
        row.setAttribute('draggable', 'true');
      }
    });

    // ── Drag & Drop ───────────────────────────────────────────────────────
    var dragRow = null;

    comments.addEventListener('dragstart', function (e) {
      var row = e.target.closest('.mh-comment');
      if (!row || readonly) { e.preventDefault(); return; }
      dragRow = row;
      row.classList.add('mh-dragging');
      e.dataTransfer.effectAllowed = 'move';
      try { e.dataTransfer.setData('text/plain', row.getAttribute('data-journal-id')); } catch (err) { /* IE */ }
    });

    comments.addEventListener('dragend', function () {
      if (dragRow) dragRow.classList.remove('mh-dragging');
      dragRow = null;
      var over = targets.querySelectorAll('.mh-drop-over');
      Array.prototype.forEach.call(over, function (b) { b.classList.remove('mh-drop-over'); });
    });

    targets.addEventListener('dragover', function (e) {
      var box = e.target.closest('.mh-drop');
      if (!box || !dragRow) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      box.classList.add('mh-drop-over');
    });

    targets.addEventListener('dragleave', function (e) {
      var box = e.target.closest('.mh-drop');
      if (!box) return;
      // nur entfernen, wenn wir den Kasten wirklich verlassen
      if (e.relatedTarget && box.contains(e.relatedTarget)) return;
      box.classList.remove('mh-drop-over');
    });

    targets.addEventListener('drop', function (e) {
      var box = e.target.closest('.mh-drop');
      if (!box) return;
      e.preventDefault();
      box.classList.remove('mh-drop-over');
      var row = dragRow;
      if (!row) {
        var jid = e.dataTransfer.getData('text/plain');
        row = jid ? document.getElementById('mh-comment-' + jid) : null;
      }
      if (!row) return;
      moveComment(row, box.getAttribute('data-target-id'), box);
    });

    // ── Tracker-Fokus ─────────────────────────────────────────────────────
    var columns = document.getElementById('mh-tracker-columns');
    if (columns) {
      columns.addEventListener('click', function (e) {
        var head = e.target.closest('.mh-tracker-head');
        if (!head) return;
        var col = head.closest('.mh-tracker-col');
        var wasFocused = col.classList.contains('mh-focus');
        Array.prototype.forEach.call(columns.querySelectorAll('.mh-tracker-col'), function (c) {
          c.classList.remove('mh-focus');
        });
        if (wasFocused) {
          columns.classList.remove('mh-focused');
        } else {
          columns.classList.add('mh-focused');
          col.classList.add('mh-focus');
        }
      });
    }

    var closedToggle = document.getElementById('mh-show-closed');
    if (closedToggle) {
      closedToggle.addEventListener('change', function () {
        targets.classList.toggle('mh-show-closed', closedToggle.checked);
      });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();

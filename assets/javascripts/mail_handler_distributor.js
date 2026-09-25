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
    var kind = root.getAttribute('data-kind');
    var issueId = root.getAttribute('data-issue-id');
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

    // Hoehe so setzen, dass alles unterhalb (Content-Abstand, Footer) noch auf
    // den Bildschirm passt und die Seite nicht scrollen muss.
    function px(el, prop) {
      if (!el) return 0;
      return parseFloat(window.getComputedStyle(el)[prop]) || 0;
    }
    function resize() {
      var rect = root.getBoundingClientRect();
      var top = rect.top + window.pageYOffset;
      var content = document.getElementById('content');
      var footer = document.getElementById('footer');
      var below = px(content, 'paddingBottom') + px(content, 'marginBottom');
      if (footer) {
        below += footer.getBoundingClientRect().height + px(footer, 'marginTop') + px(footer, 'marginBottom');
      }
      var h = window.innerHeight - top - below - 4;
      root.style.height = Math.max(320, Math.floor(h)) + 'px';
      // Zweiter Durchgang: was die Seite jetzt noch ueber-/unterschreitet
      // (Theme-Abstaende, "Nach oben"-Link usw.) wird ausgeglichen.
      var delta = document.documentElement.scrollHeight - window.innerHeight;
      if (delta !== 0) {
        root.style.height = Math.max(320, Math.floor(h - delta)) + 'px';
      }
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

    // ── Mehrfachauswahl (Strg/Cmd + Klick) ───────────────────────────────
    var bulk = document.getElementById('mh-bulk');
    var bulkN = document.getElementById('mh-bulk-n');

    function selectedRows() {
      return Array.prototype.slice.call(comments.querySelectorAll('.mh-comment.mh-selected'));
    }
    function updateBulk() {
      var n = selectedRows().length;
      if (bulkN) bulkN.textContent = n;
      if (bulk) bulk.hidden = n === 0;
      resize();
    }
    function clearSelection() {
      selectedRows().forEach(function (r) { r.classList.remove('mh-selected'); });
      updateBulk();
    }
    function toggleSelected(row) {
      row.classList.toggle('mh-selected');
      updateBulk();
    }

    // Mehrere Zeilen nacheinander verschieben (gleiches Ziel oder je Zeile
    // ein eigenes Ziel per targetFor(row)); Ergebnis als Sammel-Toast.
    function moveMany(rows, targetFor, dropBox) {
      if (readonly || !rows.length) return Promise.resolve();
      var ok = 0, failed = 0;
      var chain = Promise.resolve();
      rows.forEach(function (row) {
        chain = chain.then(function () {
          var target = typeof targetFor === 'function' ? targetFor(row) : targetFor;
          if (!target) { failed += 1; return; }
          return moveComment(row, target, dropBox, true).then(function (res) {
            if (res) ok += 1; else failed += 1;
          });
        });
      });
      return chain.then(function () {
        toast(ok + ' Kommentar(e) verschoben' + (failed ? ', ' + failed + ' fehlgeschlagen' : ''), failed > 0);
        updateBulk();
      });
    }

    // ── Verschieben ───────────────────────────────────────────────────────
    // Liefert ein Promise mit true (verschoben) / false (Fehler).
    function moveComment(row, targetId, dropBox, quiet) {
      if (readonly || !row || row.classList.contains('mh-busy')) return Promise.resolve(false);
      targetId = String(targetId || '').trim().replace(/^#/, '');
      var input = row.querySelector('.mh-c-target');
      if (!/^\d+$/.test(targetId)) {
        if (input) { input.classList.add('mh-invalid'); input.focus(); }
        toast('Bitte eine gültige Ticket-Nummer eingeben.', true);
        return Promise.resolve(false);
      }
      if (input) input.classList.remove('mh-invalid');
      row.classList.add('mh-busy');

      var body = new URLSearchParams();
      body.append('journal_id', row.getAttribute('data-journal-id'));
      body.append('target_issue_id', targetId);

      return fetch(moveUrl, {
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
          if (!quiet) toast(data.error || 'Verschieben fehlgeschlagen.', true);
          return false;
        }
        onMoved(row, data, dropBox, quiet);
        return true;
      }).catch(function (err) {
        row.classList.remove('mh-busy');
        if (!quiet) toast('Netzwerkfehler: ' + err, true);
        return false;
      });
    }

    function onMoved(row, data, dropBox, quiet) {
      var t = data.target || {};
      if (!quiet) toast('Kommentar #' + data.journal_id + ' nach #' + t.id + ' verschoben' + (t.subject ? ' (' + t.subject + ')' : ''));
      row.classList.remove('mh-selected');

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
        updateBulk();
      }, 260);

      // Vorschlaege aller Zeilen desselben Absenders aktualisieren
      // (im Papierkorb gibt es keine Vorschlaege)
      var userId = String(data.user_id);
      var rows = comments.querySelectorAll('.mh-comment[data-user-id="' + userId + '"]');
      Array.prototype.forEach.call(rows, function (r) {
        if (r === row) return;
        var wrap = r.querySelector('.mh-c-suggest-wrap');
        if (!wrap || kind === 'trash') return;
        wrap.innerHTML = '';
        if (data.suggestion) {
          var a = document.createElement('a');
          a.href = '#';
          a.className = 'mh-c-suggest' + (data.suggestion.is_trash ? ' mh-c-suggest-trash' : '');
          a.setAttribute('data-target-id', data.suggestion.id);
          var label = data.suggestion.label || ('#' + data.suggestion.id + ' ' + (data.suggestion.subject || ''));
          a.title = 'Vorschlag: bisher mehrfach hierhin verschoben (' + label + ') – klicken zum Verschieben';
          if (label.length > 48) label = label.substring(0, 47) + '…';
          a.textContent = label;
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

    // ── Overlay (Kommentar im Mail-Stil) ──────────────────────────────────
    var overlay = document.getElementById('mh-overlay');
    var overlayContent = document.getElementById('mh-overlay-content');

    function openOverlay(row) {
      var full = row.querySelector('.mh-c-full');
      if (!full || !overlay) return;
      overlayContent.innerHTML = full.innerHTML;
      var classic = overlay.querySelector('.mh-overlay-classic');
      var idLink = row.querySelector('.mh-c-id a');
      if (classic && idLink) classic.href = idLink.href;
      var title = overlay.querySelector('.mh-overlay-title');
      var user = row.querySelector('.mh-c-user');
      if (title) title.textContent = 'Kommentar #' + row.getAttribute('data-journal-id') + (user ? ' – ' + user.textContent : '');
      overlay.hidden = false;
      var closeBtn = overlay.querySelector('.mh-overlay-close');
      if (closeBtn) closeBtn.focus();
    }

    function closeOverlay() {
      if (!overlay) return;
      overlay.hidden = true;
      overlayContent.innerHTML = '';
    }

    if (overlay) {
      overlay.addEventListener('click', function (e) {
        if (e.target === overlay || e.target.closest('.mh-overlay-close')) closeOverlay();
      });
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && !overlay.hidden) closeOverlay();
      });
    }

    // ── Eingabe / Vorschlag / Zeilenklick (Event-Delegation) ─────────────
    comments.addEventListener('click', function (e) {
      if (e.target.closest('input, button, a')) {
        // Links, Eingaben und Buttons behalten ihr eigenes Verhalten (s.u.)
      } else {
        var clickedRow = e.target.closest('.mh-comment');
        if (clickedRow) {
          if ((e.ctrlKey || e.metaKey) && !readonly) { e.preventDefault(); toggleSelected(clickedRow); }
          else openOverlay(clickedRow);
          return;
        }
      }
      var suggest = e.target.closest('.mh-c-suggest');
      if (suggest) {
        e.preventDefault();
        moveComment(suggest.closest('.mh-comment'), suggest.getAttribute('data-target-id'));
        return;
      }
      var go = e.target.closest('.mh-c-go');
      if (go && go.closest('.mh-comment')) {
        var row = go.closest('.mh-comment');
        var value = row.querySelector('.mh-c-target').value;
        if (row.classList.contains('mh-selected') && selectedRows().length > 1) moveMany(selectedRows(), value);
        else moveComment(row, value);
        return;
      }
      var restore = e.target.closest('.mh-c-restore');
      if (restore) {
        moveComment(restore.closest('.mh-comment'), restore.getAttribute('data-target-id'));
      }
    });

    comments.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter') return;
      var input = e.target.closest('.mh-c-target');
      if (!input || !input.closest('.mh-comment')) return;
      e.preventDefault();
      var inRow = input.closest('.mh-comment');
      if (inRow.classList.contains('mh-selected') && selectedRows().length > 1) moveMany(selectedRows(), input.value);
      else moveComment(inRow, input.value);
    });

    // Sammel-Leiste
    if (bulk) {
      var bulkTarget = document.getElementById('mh-bulk-target');
      var bulkGo = document.getElementById('mh-bulk-go');
      var bulkRestore = document.getElementById('mh-bulk-restore');
      var bulkClear = document.getElementById('mh-bulk-clear');
      function bulkMove() {
        var v = bulkTarget.value.trim().replace(/^#/, '');
        if (!/^\d+$/.test(v)) { bulkTarget.classList.add('mh-invalid'); bulkTarget.focus(); toast('Bitte eine gültige Ticket-Nummer eingeben.', true); return; }
        bulkTarget.classList.remove('mh-invalid');
        moveMany(selectedRows(), v).then(function () { bulkTarget.value = ''; });
      }
      if (bulkGo) bulkGo.addEventListener('click', bulkMove);
      if (bulkTarget) bulkTarget.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); bulkMove(); } });
      if (bulkRestore) bulkRestore.addEventListener('click', function () {
        moveMany(selectedRows(), function (row) {
          var btn = row.querySelector('.mh-c-restore');
          return btn ? btn.getAttribute('data-target-id') : null;
        });
      });
      if (bulkClear) bulkClear.addEventListener('click', clearSelection);
      document.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && overlay && overlay.hidden && selectedRows().length) clearSelection();
      });
    }

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
      if (row.classList.contains('mh-selected')) {
        selectedRows().forEach(function (r) { r.classList.add('mh-dragging'); });
      }
      e.dataTransfer.effectAllowed = 'move';
      try { e.dataTransfer.setData('text/plain', row.getAttribute('data-journal-id')); } catch (err) { /* IE */ }
    });

    comments.addEventListener('dragend', function () {
      Array.prototype.forEach.call(comments.querySelectorAll('.mh-dragging'), function (r) { r.classList.remove('mh-dragging'); });
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
      var targetId = box.getAttribute('data-target-id');
      if (row.classList.contains('mh-selected') && selectedRows().length > 1) moveMany(selectedRows(), targetId, box);
      else moveComment(row, targetId, box);
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

    // ── Suchfeld: blendet nicht passende Ziele aus; bleibt beim Verschieben
    //    erhalten (kein Reload) und wird je Verteiler in sessionStorage gemerkt
    var search = document.getElementById('mh-search');
    if (search) {
      var storeKey = 'mh-search-' + issueId;
      function applySearch() {
        var q = search.value.trim().toLowerCase();
        var terms = q.split(/\s+/).filter(Boolean);
        targets.classList.toggle('mh-search-active', terms.length > 0);
        var tiles = targets.querySelectorAll('.mh-drop:not(.mh-trash-box)');
        Array.prototype.forEach.call(tiles, function (tile) {
          var hay = (tile.getAttribute('data-search') || tile.textContent).toLowerCase();
          var hit = terms.every(function (t) { return hay.indexOf(t) !== -1; });
          tile.classList.toggle('mh-search-hide', !hit);
        });
        // Tracker-Spalten ohne Treffer ausblenden
        Array.prototype.forEach.call(targets.querySelectorAll('.mh-tracker-col'), function (col) {
          var visible = col.querySelectorAll('.mh-drop:not(.mh-search-hide)').length;
          col.classList.toggle('mh-search-hide', terms.length > 0 && visible === 0);
        });
        try { window.sessionStorage.setItem(storeKey, search.value); } catch (err) { /* ignore */ }
      }
      try {
        var saved = window.sessionStorage.getItem(storeKey);
        if (saved) search.value = saved;
      } catch (err) { /* ignore */ }
      search.addEventListener('input', applySearch);
      search.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') { search.value = ''; applySearch(); }
      });
      applySearch();
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

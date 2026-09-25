# Datenmodell fuer die Verteiler-Ansicht.
#
# Ein "Verteiler-Ticket" ist entweder das Posteingang-Ticket (Root-Verteiler,
# Einstellung inbox_ticket_id) oder ein Ticket, das in der Adress-Matrix einer
# Alias-Adresse zugeordnet ist (Alias-Verteiler). Fuer diese Tickets ersetzt
# das Plugin die normale Ticket-Ansicht durch eine Sortier-Oberflaeche
# (siehe MailHandlerDistributorIssuesPatch und views/mail_handler_distributor).
module MailHandlerDistributor
  # Kurze Vorschau eines Kommentars: erste nicht-leere Zeile, ohne Markup,
  # auf diese Laenge gekuerzt (CSS kuerzt zusaetzlich per Ellipsis).
  PREVIEW_LENGTH = 140

  Comment = Struct.new(:journal, :indice, :preview, :suggestion, :origin_issue, :moved_at, :expires_at, keyword_init: true)
  AliasEntry = Struct.new(:email, :issue, :project, :hide_in_root, keyword_init: true)
  TrackerColumn = Struct.new(:tracker, :issues, keyword_init: true)

  class << self
    def settings
      Setting.plugin_redmine_mail_handler || {}
    end

    def root_issue_id
      settings['inbox_ticket_id'].to_i
    end

    # ── Papierkorb ──────────────────────────────────────────────────────────
    DEFAULT_TRASH_RETENTION_HOURS = 48

    def trash_issue_id
      settings['trash_ticket_id'].to_i
    end

    def trash_issue
      trash_issue_id > 0 ? Issue.find_by(id: trash_issue_id) : nil
    end

    def trash?(issue)
      issue && trash_issue_id > 0 && issue.id == trash_issue_id
    end

    def trash_retention_hours
      h = settings['trash_retention_hours'].to_i
      h > 0 ? h : DEFAULT_TRASH_RETENTION_HOURS
    end

    # Ablaufzeitpunkt eines Kommentars im Papierkorb: Zeitpunkt der
    # Verschiebung (Move-Protokoll) + Aufbewahrungsfrist; ohne Protokoll
    # zaehlt updated_on des Journals (wird beim Anlegen durch den Move gesetzt).
    def trash_expiry(journal, move = nil)
      base = move&.created_at || journal.updated_on || journal.created_on || Time.current
      base + trash_retention_hours.hours
    end

    # Loescht abgelaufene Kommentare im Papierkorb (inkl. mitverschobener
    # Anhaenge). Liefert die Anzahl geloeschter Kommentare.
    def purge_trash!
      trash = trash_issue
      return 0 unless trash

      deleted = 0
      journals = trash.journals.where.not(notes: [nil, '']).includes(:details).to_a
      moves = MailHandlerCommentMove.where(new_journal_id: journals.map(&:id)).index_by(&:new_journal_id)
      journals.each do |journal|
        next unless trash_expiry(journal, moves[journal.id]) <= Time.current
        journal.details.select { |d| d.property == 'attachment' }.each do |d|
          Attachment.find_by(id: d.prop_key)&.destroy
        end
        journal.destroy
        deleted += 1
      end
      Rails.logger.info("[MailHandler] Papierkorb: #{deleted} abgelaufene Kommentare geloescht") if deleted > 0
      deleted
    end

    # ── System-Tracker ──────────────────────────────────────────────────────
    DEFAULT_TRACKER_NAME = 'Ticket-Verteiler'.freeze

    def tracker_name
      settings['distributor_tracker_name'].presence || DEFAULT_TRACKER_NAME
    end

    def tracker
      Tracker.find_by(name: tracker_name)
    end

    # ID des Trackers, der in Ticketlisten standardmaessig ausgeblendet wird
    # (kurz gecacht, wird bei jeder neuen IssueQuery abgefragt).
    def hidden_tracker_id
      Rails.cache.fetch("mail_handler/distributor_tracker_id/#{tracker_name}", expires_in: 5.minutes) do
        tracker&.id || 0
      end.then { |id| id > 0 ? id : nil }
    end

    # Alle System-Tickets: Posteingang, Alias-Verteiler, Papierkorb
    def system_issues
      ids = [root_issue_id, trash_issue_id] + alias_issue_ids
      Issue.where(id: ids.select { |i| i > 0 }.uniq).to_a
    end

    # Legt den Tracker an (falls noetig), aktiviert ihn in den betroffenen
    # Projekten und weist ihn allen System-Tickets zu. Liefert [tracker, anzahl].
    def apply_tracker!
      t = tracker
      unless t
        t = Tracker.new(name: tracker_name, default_status: IssueStatus.sorted.first)
        t.position = (Tracker.maximum(:position) || 0) + 1
        t.save!
      end
      Rails.cache.delete("mail_handler/distributor_tracker_id/#{tracker_name}")

      changed = 0
      system_issues.each do |issue|
        project = issue.project
        project.trackers << t unless project.trackers.include?(t)
        next if issue.tracker_id == t.id
        issue.update_column(:tracker_id, t.id)
        changed += 1
      end
      [t, changed]
    end

    # Alle Alias-Eintraege der Adress-Matrix mit existierendem Ticket,
    # unabhaengig vom "Mark Projekt"-Flag. Dubletten (mehrere Aliase auf
    # dasselbe Ticket) werden zu einem Eintrag zusammengefasst.
    def alias_entries
      by_issue = {}
      MailHandlerService.parse_address_matrix.each do |entry|
        next if entry[:ticket_id] <= 0
        if by_issue.key?(entry[:ticket_id])
          existing = by_issue[entry[:ticket_id]]
          existing.email << ", #{entry[:email]}"
          existing.hide_in_root ||= entry[:hide_in_root]
          next
        end
        issue = Issue.find_by(id: entry[:ticket_id])
        next unless issue
        by_issue[entry[:ticket_id]] = AliasEntry.new(email: entry[:email].dup, issue: issue, project: issue.project, hide_in_root: entry[:hide_in_root])
      end
      by_issue.values.sort_by { |e| [e.project&.name.to_s, e.issue.id] }
    end

    # Alias-Verteiler, die im Posteingang-Verteiler als Ziel-Kachel erscheinen
    # (Matrix-Flag "Im Root ausblenden" nicht gesetzt).
    def root_target_entries
      alias_entries.reject(&:hide_in_root)
    end

    def alias_issue_ids
      MailHandlerService.parse_address_matrix.map { |e| e[:ticket_id] }.uniq - [trash_issue_id]
    end

    # :root, :alias, :trash oder nil
    def kind(issue)
      return nil unless issue
      return :root if root_issue_id > 0 && issue.id == root_issue_id
      return :trash if trash?(issue)
      return :alias if alias_issue_ids.include?(issue.id)
      nil
    end

    # Kurzname: alles vor dem ersten Bindestrich
    # ("pfp12345-beschreibung-info" -> "pfp12345", "bewerbungen" -> "bewerbungen").
    def short_name(name)
      name.to_s.split('-', 2).first.to_s.strip.presence || name.to_s.strip
    end

    # Projekt-Kurzkennung fuer Root-Kacheln und Root-Vorschlaege: die
    # Projektkennung (identifier) bis zum ersten Bindestrich.
    def project_short_id(project)
      return nil unless project
      short_name(project.identifier.presence || project.name)
    end

    # Beschriftung eines Vorschlags / Ziels, abhaengig von der Ansicht:
    # im Root-Verteiler nur das Projekt (Kurzkennung), sonst Ticket mit Kurzname.
    def target_label(kind, issue)
      return nil unless issue
      return 'Papierkorb' if trash?(issue)
      if kind == :root
        proj = issue.project
        proj ? project_short_id(proj) : "##{issue.id}"
      else
        "##{issue.id} #{short_name(issue.subject)}"
      end
    end

    def issue_json(issue, kind = nil)
      return nil unless issue
      {
        id: issue.id,
        subject: issue.subject,
        project: issue.project&.name,
        project_identifier: issue.project&.identifier,
        is_trash: trash?(issue),
        label: target_label(kind, issue)
      }
    end

    def distributor?(issue)
      !kind(issue).nil?
    end

    # ── Menü / Rolle ────────────────────────────────────────────────────────
    DEFAULT_ROLE_NAME = 'Ticket_Verteiler'.freeze

    # Name der Rolle, die die Menüpunkte "Ticket-Verteiler" sehen darf.
    def role_name
      settings['distributor_role_name'].presence || DEFAULT_ROLE_NAME
    end

    # Hat der Benutzer die Verteiler-Rolle in diesem Projekt (oder ist Admin)?
    def user_has_role?(user, project)
      return false unless user && project
      return true if user.admin?
      user.roles_for_project(project).any? { |r| r.name == role_name }
    end

    # Hat der Benutzer die Verteiler-Rolle in irgendeinem Projekt (oder ist Admin)?
    def user_has_role_anywhere?(user)
      return false unless user && user.logged?
      return true if user.admin?
      user.memberships.joins(:roles).where(roles: { name: role_name }).exists?
    end

    # Verteiler-Ticket eines Projekts: Alias-Verteiler (niedrigste ID), sonst
    # das Posteingang-Ticket, falls es in diesem Projekt liegt.
    def issue_for_project(project)
      return nil unless project
      alias_issue = alias_entries.select { |e| e.project && e.project.id == project.id }
                                 .map(&:issue).min_by(&:id)
      return alias_issue if alias_issue
      root = Issue.find_by(id: root_issue_id) if root_issue_id > 0
      root if root && root.project_id == project.id
    end

    def root_issue
      root_issue_id > 0 ? Issue.find_by(id: root_issue_id) : nil
    end

    # Bedingungen fuer die Menüpunkte (siehe init.rb)
    def show_project_menu?(project, user = User.current)
      return false unless project && user_has_role?(user, project)
      !issue_for_project(project).nil?
    end

    def show_top_menu?(user = User.current)
      root_issue_id > 0 && user_has_role_anywhere?(user)
    end

    # Soll fuer diesen Request die Verteiler-Ansicht statt der normalen
    # Ticket-Ansicht gerendert werden? Mit ?classic=1 laesst sich die
    # Standardansicht weiterhin aufrufen (z.B. um das Ticket zu bearbeiten).
    def render_for?(issue, request, params)
      # Nur normale HTML-Seitenaufrufe (kein PDF/Atom/API, kein XHR). Der
      # Accept-Header wird bewusst nicht ausgewertet: "*/*" (z.B. curl) liefert
      # in Rails kein request.format.html?.
      return false unless params[:format].blank? || params[:format].to_s == 'html'
      return false if request.xhr?
      return false if params[:classic].present?
      distributor?(issue)
    end

    # Kommentare (Journale mit Notizen) eines Verteiler-Tickets inkl. Vorschlag.
    # Im Papierkorb zusaetzlich Herkunfts-Ticket und Ablaufzeitpunkt.
    def comments(issue, user = User.current)
      journals = issue.visible_journals_with_index.select { |j| j.notes.present? }
      journals.reverse! if user.wants_comments_in_reverse_order?

      in_trash = trash?(issue)
      suggestions = in_trash ? {} : MailHandlerCommentMove.suggestions_for(issue.id, journals.map(&:user_id), user)
      moves = MailHandlerCommentMove.where(new_journal_id: journals.map(&:id)).index_by(&:new_journal_id)

      journals.map do |journal|
        move = moves[journal.id]
        Comment.new(
          journal: journal,
          indice: journal.indice,
          preview: preview_text(journal.notes, PREVIEW_LENGTH),
          suggestion: suggestions[journal.user_id],
          origin_issue: (move && Issue.visible(user).find_by(id: move.source_issue_id)),
          moved_at: move&.created_at,
          expires_at: (in_trash ? trash_expiry(journal, move) : nil)
        )
      end
    end

    # Tickets eines Alias-Projekts, gruppiert nach Tracker (in Tracker-Reihenfolge).
    # Das Verteiler-Ticket selbst und andere Verteiler-Tickets werden ausgelassen.
    def tracker_columns(project, exclude_issue_ids = [], user = User.current)
      return [] unless project

      issues = project.issues
                      .visible(user)
                      .where.not(id: exclude_issue_ids)
                      .includes(:tracker, :status, :assigned_to)
                      .order(:id)
                      .to_a

      grouped = issues.group_by(&:tracker)
      project.trackers.sorted.map do |tracker|
        list = grouped[tracker] || []
        next if list.empty?
        TrackerColumn.new(tracker: tracker, issues: list)
      end.compact
    end

    # Erste sinnvolle Zeile eines Kommentars ohne Wiki-/Markdown-Zeichen.
    def preview_text(notes, length, multiline: false)
      text = notes.to_s.gsub(/\r/, '')
      if multiline
        text = text.strip
      else
        line = text.each_line.map(&:strip).find { |l| !l.empty? && !l.match?(/\A[-=_*#>|]+\z/) }
        text = line.to_s
      end
      text = text.gsub(/<[^>]+>/, ' ')                 # HTML-Tags
                 .gsub(/\A[#>*\-+\s]+/, '')             # fuehrende Markup-Zeichen
                 .gsub(/[*_`]{1,3}([^*_`]+)[*_`]{1,3}/, '\1') # *fett* / _kursiv_
                 .gsub(/!\[[^\]]*\]\([^)]*\)/, '')      # Markdown-Bilder
                 .gsub(/\[([^\]]+)\]\([^)]*\)/, '\1')   # Markdown-Links
                 .gsub(/[ \t]+/, ' ')
                 .strip
      text.length > length ? "#{text[0, length - 1]}…" : text
    end
  end
end

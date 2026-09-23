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

  Comment = Struct.new(:journal, :indice, :preview, :suggestion, keyword_init: true)
  AliasEntry = Struct.new(:email, :issue, :project, keyword_init: true)
  TrackerColumn = Struct.new(:tracker, :issues, keyword_init: true)

  class << self
    def settings
      Setting.plugin_redmine_mail_handler || {}
    end

    def root_issue_id
      settings['inbox_ticket_id'].to_i
    end

    # Alle Alias-Eintraege der Adress-Matrix mit existierendem Ticket,
    # unabhaengig vom "Mark Projekt"-Flag. Dubletten (mehrere Aliase auf
    # dasselbe Ticket) werden zu einem Eintrag zusammengefasst.
    def alias_entries
      by_issue = {}
      MailHandlerService.parse_address_matrix.each do |entry|
        next if entry[:ticket_id] <= 0
        if by_issue.key?(entry[:ticket_id])
          by_issue[entry[:ticket_id]].email << ", #{entry[:email]}"
          next
        end
        issue = Issue.find_by(id: entry[:ticket_id])
        next unless issue
        by_issue[entry[:ticket_id]] = AliasEntry.new(email: entry[:email].dup, issue: issue, project: issue.project)
      end
      by_issue.values.sort_by { |e| [e.project&.name.to_s, e.issue.id] }
    end

    def alias_issue_ids
      MailHandlerService.parse_address_matrix.map { |e| e[:ticket_id] }.uniq
    end

    # :root, :alias oder nil
    def kind(issue)
      return nil unless issue
      return :root if root_issue_id > 0 && issue.id == root_issue_id
      return :alias if alias_issue_ids.include?(issue.id)
      nil
    end

    def distributor?(issue)
      !kind(issue).nil?
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
    def comments(issue, user = User.current)
      journals = issue.visible_journals_with_index.select { |j| j.notes.present? }
      journals.reverse! if user.wants_comments_in_reverse_order?

      suggestions = MailHandlerCommentMove.suggestions_for(issue.id, journals.map(&:user_id), user)

      journals.map do |journal|
        Comment.new(
          journal: journal,
          indice: journal.indice,
          preview: preview_text(journal.notes, PREVIEW_LENGTH),
          suggestion: suggestions[journal.user_id]
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

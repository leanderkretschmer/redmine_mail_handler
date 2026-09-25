# Ersetzt die Ticket-Ansicht (issues#show) fuer Verteiler-Tickets durch die
# Verteiler-Oberflaeche. Alle before_actions von Redmine (find_issue,
# authorize) laufen weiterhin, nur das Rendering wird ausgetauscht.
#
# Hinweis: Der prepend am Dateiende ist der Mechanismus, der den Patch aktiv
# macht; die Datei wird aus init.rb geladen.
module MailHandlerDistributorIssuesPatch
  def show
    if MailHandlerDistributor.render_for?(@issue, request, params)
      render_mail_handler_distributor
      return
    end
    super
  end

  private

  def render_mail_handler_distributor
    @distributor_kind = MailHandlerDistributor.kind(@issue)
    @distributor_comments = MailHandlerDistributor.comments(@issue)
    @distributor_can_move = @distributor_comments.any? { |c| c.journal.editable_by?(User.current) } ||
                            User.current.allowed_to?(:edit_issue_notes, @issue.project)

    @distributor_trash = MailHandlerDistributor.trash_issue
    @distributor_trash = nil if @distributor_trash && @distributor_trash.id == @issue.id

    case @distributor_kind
    when :root
      @distributor_aliases = MailHandlerDistributor.alias_entries
    when :alias
      exclude = [@issue.id, MailHandlerDistributor.root_issue_id, MailHandlerDistributor.trash_issue_id] + MailHandlerDistributor.alias_issue_ids
      @distributor_columns = MailHandlerDistributor.tracker_columns(@issue.project, exclude.uniq)
    when :trash
      @distributor_retention_hours = MailHandlerDistributor.trash_retention_hours
    end

    render template: 'mail_handler_distributor/show'
  end
end

IssuesController.prepend(MailHandlerDistributorIssuesPatch) unless IssuesController.ancestors.include?(MailHandlerDistributorIssuesPatch)

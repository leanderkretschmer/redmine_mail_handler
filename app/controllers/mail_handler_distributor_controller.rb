# AJAX-Endpunkt der Verteiler-Ansicht: verschiebt einen Kommentar in ein
# anderes Ticket. Die eigentliche Verschiebung uebernimmt das Plugin
# redmine_move_comments ueber dessen Hook controller_journals_edit_post
# (derselbe Weg wie beim Bearbeiten eines Kommentars mit "In Ticket verschieben").
class MailHandlerDistributorController < ApplicationController
  before_action :require_login

  def move_comment
    journal = Journal.find_by(id: params[:journal_id])
    return render_error_json('Kommentar nicht gefunden.', :not_found) unless journal
    return render_error_json('Kommentar ist kein Ticket-Kommentar.', :unprocessable_entity) unless journal.journalized_type == 'Issue'

    source_issue = journal.journalized
    return render_403_json unless source_issue.visible? && journal.editable_by?(User.current)

    target_id = params[:target_issue_id].to_s.strip.sub(/\A#/, '')
    return render_error_json('Bitte eine Ticket-Nummer angeben.', :unprocessable_entity) unless target_id.match?(/\A\d+\z/)

    target_issue = Issue.visible.find_by(id: target_id.to_i)
    return render_error_json("Ticket ##{target_id} nicht gefunden.", :not_found) unless target_issue
    return render_error_json('Ziel ist das aktuelle Ticket.', :unprocessable_entity) if target_issue.id == source_issue.id

    unless move_comments_plugin_available?
      return render_error_json('Das Plugin redmine_move_comments ist nicht installiert.', :not_implemented)
    end

    source_user_id = journal.user_id
    Redmine::Hook.call_hook(
      :controller_journals_edit_post,
      controller: self,
      request: request,
      project: source_issue.project,
      journal: journal,
      params: { 'new_issue_id' => target_issue.id.to_s }
    )

    if journal.respond_to?(:wrong_new_issue_id) && journal.wrong_new_issue_id.present?
      return render_error_json("Ticket ##{target_id} konnte nicht verwendet werden.", :unprocessable_entity)
    end

    # Erfolg: das Quell-Journal ist entweder geloescht oder hat keine Notiz mehr.
    remaining = Journal.find_by(id: journal.id)
    unless remaining.nil? || remaining.notes.blank?
      return render_error_json('Kommentar konnte nicht verschoben werden.', :unprocessable_entity)
    end

    suggestion = MailHandlerCommentMove.suggestion_for(source_issue.id, source_user_id)

    render json: {
      ok: true,
      journal_id: journal.id,
      user_id: source_user_id,
      target: issue_json(target_issue),
      suggestion: suggestion ? issue_json(suggestion) : nil
    }
  rescue => e
    Rails.logger.error("[MailHandler] move_comment failed: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    render_error_json("Fehler beim Verschieben: #{e.message}", :internal_server_error)
  end

  private

  def move_comments_plugin_available?
    Redmine::Hook.hook_listeners(:controller_journals_edit_post).any? { |l| l.class.name == 'MoveCommentsHooks' }
  end

  def issue_json(issue)
    { id: issue.id, subject: issue.subject, project: issue.project&.name, url: issue_path(issue) }
  end

  def render_error_json(message, status)
    render json: { ok: false, error: message }, status: status
  end

  def render_403_json
    render_error_json('Keine Berechtigung, diesen Kommentar zu verschieben.', :forbidden)
  end
end

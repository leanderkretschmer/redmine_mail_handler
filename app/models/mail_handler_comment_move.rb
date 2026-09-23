# Ein Eintrag pro verschobenem Kommentar (siehe Hook move_comments_after_journal_move).
class MailHandlerCommentMove < ActiveRecord::Base
  belongs_to :target_issue, class_name: 'Issue', optional: true

  validates :journal_user_id, :source_issue_id, :target_issue_id, presence: true

  # Wie viele der letzten Verschiebungen eines Absenders (aus demselben
  # Verteiler) auf dasselbe Ziel zeigen muessen, bevor ein Vorschlag gemacht wird.
  SUGGESTION_MIN_MOVES = 3

  # Protokolliert einen vom redmine_move_comments-Plugin durchgefuehrten Move.
  def self.record(source_journal, new_journal, target_issue)
    return unless source_journal && target_issue
    return unless source_journal.journalized_type == 'Issue'

    create!(
      journal_user_id: source_journal.user_id,
      source_issue_id: source_journal.journalized_id,
      target_issue_id: target_issue.id,
      new_journal_id: new_journal&.id,
      moved_by_id: User.current&.id,
      created_at: Time.current
    )
  end

  # Vorschlag fuer einen Absender innerhalb eines Verteiler-Tickets.
  #
  # Es wird nur dann ein Ziel vorgeschlagen, wenn die letzten
  # SUGGESTION_MIN_MOVES Verschiebungen dieses Absenders aus diesem Verteiler
  # alle in dasselbe Ticket gingen. Wechseln die Ziele, gibt es keinen
  # Vorschlag, weil dann nicht sicher gesagt werden kann, was korrekt waere.
  #
  # Liefert ein Issue oder nil.
  def self.suggestion_for(source_issue_id, journal_user_id, user = User.current)
    recent = where(source_issue_id: source_issue_id, journal_user_id: journal_user_id)
             .order(id: :desc)
             .limit(SUGGESTION_MIN_MOVES)
             .pluck(:target_issue_id)

    return nil unless recent.length >= SUGGESTION_MIN_MOVES && recent.uniq.length == 1

    Issue.visible(user).find_by(id: recent.first)
  end

  # Vorschlaege fuer mehrere Absender auf einmal: { user_id => Issue }.
  def self.suggestions_for(source_issue_id, journal_user_ids, user = User.current)
    journal_user_ids.uniq.compact.each_with_object({}) do |uid, memo|
      issue = suggestion_for(source_issue_id, uid, user)
      memo[uid] = issue if issue
    end
  end
end

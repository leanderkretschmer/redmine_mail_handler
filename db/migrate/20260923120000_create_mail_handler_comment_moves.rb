# Protokolliert, wohin Kommentare aus Verteiler-Tickets verschoben wurden.
# Grundlage fuer die Ziel-Vorschlaege in der Verteiler-Ansicht.
class CreateMailHandlerCommentMoves < ActiveRecord::Migration[7.2]
  def change
    create_table :mail_handler_comment_moves do |t|
      t.integer :journal_user_id, null: false   # Absender (User des Kommentars)
      t.integer :source_issue_id, null: false   # Verteiler-Ticket, aus dem verschoben wurde
      t.integer :target_issue_id, null: false   # Ziel-Ticket
      t.integer :new_journal_id                 # neu angelegter Journal-Eintrag im Ziel
      t.integer :moved_by_id                    # Benutzer, der verschoben hat
      t.datetime :created_at, null: false
    end

    add_index :mail_handler_comment_moves, [:source_issue_id, :journal_user_id, :id],
              name: 'idx_mh_comment_moves_source_user'
    add_index :mail_handler_comment_moves, :target_issue_id
  end
end

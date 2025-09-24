class DropMailDeferredEntries < ActiveRecord::Migration[6.1]
  def up
    # Entferne die mail_deferred_entries Tabelle falls sie existiert
    if table_exists?(:mail_deferred_entries)
      drop_table :mail_deferred_entries
    end
  end

  def down
    # Erstelle die Tabelle wieder falls sie rückgängig gemacht werden soll
    unless table_exists?(:mail_deferred_entries)
      create_table :mail_deferred_entries do |t|
        t.string :message_id, null: false, limit: 255
        t.string :from_address, null: false, limit: 255
        t.text :subject
        t.datetime :deferred_at, null: false
        t.datetime :expires_at, null: false
        t.string :reason, default: 'unknown_user'
        t.timestamps
      end
      
      add_index :mail_deferred_entries, :message_id, unique: true
      add_index :mail_deferred_entries, :from_address
      add_index :mail_deferred_entries, :expires_at
      add_index :mail_deferred_entries, :deferred_at
      add_index :mail_deferred_entries, :reason
    end
  end
end
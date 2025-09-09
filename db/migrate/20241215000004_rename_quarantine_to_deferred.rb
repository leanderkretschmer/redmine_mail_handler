class RenameQuarantineToDeferred < ActiveRecord::Migration[6.1]
  def up
    # Check if old table exists and rename it
    if table_exists?(:mail_quarantine_entries)
      rename_table :mail_quarantine_entries, :mail_deferred_entries
      rename_column :mail_deferred_entries, :quarantined_at, :deferred_at
    elsif !table_exists?(:mail_deferred_entries)
      # Create new table if neither exists
      create_table :mail_deferred_entries do |t|
        t.string :message_id, null: false, limit: 255
        t.string :from_address, null: false, limit: 255
        t.text :subject
        t.datetime :deferred_at, null: false
        t.datetime :expires_at, null: false
        t.timestamps
      end
      
      add_index :mail_deferred_entries, :message_id, unique: true
      add_index :mail_deferred_entries, :from_address
      add_index :mail_deferred_entries, :expires_at
      add_index :mail_deferred_entries, :deferred_at
    end
  end
  
  def down
    if table_exists?(:mail_deferred_entries)
      rename_table :mail_deferred_entries, :mail_quarantine_entries
      rename_column :mail_quarantine_entries, :deferred_at, :quarantined_at
    end
  end
end
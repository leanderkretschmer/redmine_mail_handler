class CreateMailQuarantineEntries < ActiveRecord::Migration[6.1]
  def change
    create_table :mail_quarantine_entries do |t|
      t.string :message_id, null: false, limit: 255
      t.string :from_address, null: false, limit: 255
      t.text :subject
      t.datetime :quarantined_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    
    add_index :mail_quarantine_entries, :message_id, unique: true
    add_index :mail_quarantine_entries, :from_address
    add_index :mail_quarantine_entries, :expires_at
    add_index :mail_quarantine_entries, :quarantined_at
  end
end
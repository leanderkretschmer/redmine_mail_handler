class CreateMailHandlerLogs < ActiveRecord::Migration[6.0]
  def self.up
    create_table :mail_handler_logs do |t|
      t.string :level, null: false, limit: 10
      t.text :message, null: false
      t.string :mail_subject, limit: 255
      t.string :mail_from, limit: 255
      t.string :mail_message_id, limit: 255
      t.integer :ticket_id
      t.timestamps null: false
    end
    
    add_index :mail_handler_logs, :level
    add_index :mail_handler_logs, :created_at
    add_index :mail_handler_logs, :ticket_id
    add_index :mail_handler_logs, :mail_message_id
  end

  def self.down
    drop_table :mail_handler_logs
  end
end


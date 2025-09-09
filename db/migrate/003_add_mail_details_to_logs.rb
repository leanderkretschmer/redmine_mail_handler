class AddMailDetailsToLogs < ActiveRecord::Migration[6.1]
  def change
    add_column :mail_handler_logs, :mail_subject, :string, limit: 500
    add_column :mail_handler_logs, :mail_from, :string, limit: 255
    add_column :mail_handler_logs, :mail_message_id, :string, limit: 100
    add_column :mail_handler_logs, :ticket_id, :integer
    
    add_index :mail_handler_logs, :mail_subject
    add_index :mail_handler_logs, :mail_from
    add_index :mail_handler_logs, :ticket_id
  end
end
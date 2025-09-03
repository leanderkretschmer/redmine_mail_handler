class AddUpdatedAtToMailHandlerLogs < ActiveRecord::Migration[6.1]
  def change
    add_column :mail_handler_logs, :updated_at, :datetime
    
    # Setze updated_at für existierende Einträge auf created_at
    reversible do |dir|
      dir.up do
        execute "UPDATE mail_handler_logs SET updated_at = created_at WHERE updated_at IS NULL"
      end
    end
  end
end
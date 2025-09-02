class CreateMailHandlerLogs < ActiveRecord::Migration[6.1]
  def change
    create_table :mail_handler_logs do |t|
      t.string :level, null: false, limit: 10
      t.text :message, null: false
      t.datetime :created_at, null: false
    end

    add_index :mail_handler_logs, :level
    add_index :mail_handler_logs, :created_at
    add_index :mail_handler_logs, [:level, :created_at]
  end
end
class AddReasonToMailDeferredEntries < ActiveRecord::Migration[5.2]
  def change
    unless column_exists?(:mail_deferred_entries, :reason)
      add_column :mail_deferred_entries, :reason, :string, default: 'unknown_user'
      add_index :mail_deferred_entries, :reason
    end
  end
end
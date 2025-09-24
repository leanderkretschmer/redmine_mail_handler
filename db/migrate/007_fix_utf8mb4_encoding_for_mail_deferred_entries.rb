class FixUtf8mb4EncodingForMailDeferredEntries < ActiveRecord::Migration[6.1]
  def up
    # Konvertiere die subject-Spalte zu UTF8MB4 um Emojis zu unterstützen
    if table_exists?(:mail_deferred_entries)
      # Für MySQL: Konvertiere zu utf8mb4
      if connection.adapter_name.downcase.include?('mysql')
        execute "ALTER TABLE mail_deferred_entries CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
        change_column :mail_deferred_entries, :subject, :text, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
        change_column :mail_deferred_entries, :from_address, :string, limit: 255, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
        change_column :mail_deferred_entries, :message_id, :string, limit: 255, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci'
        change_column :mail_deferred_entries, :reason, :string, charset: 'utf8mb4', collation: 'utf8mb4_unicode_ci' if column_exists?(:mail_deferred_entries, :reason)
      end
    end
  end

  def down
    # Rückgängig machen: Zurück zu utf8
    if table_exists?(:mail_deferred_entries)
      if connection.adapter_name.downcase.include?('mysql')
        execute "ALTER TABLE mail_deferred_entries CONVERT TO CHARACTER SET utf8 COLLATE utf8_unicode_ci"
        change_column :mail_deferred_entries, :subject, :text, charset: 'utf8', collation: 'utf8_unicode_ci'
        change_column :mail_deferred_entries, :from_address, :string, limit: 255, charset: 'utf8', collation: 'utf8_unicode_ci'
        change_column :mail_deferred_entries, :message_id, :string, limit: 255, charset: 'utf8', collation: 'utf8_unicode_ci'
        change_column :mail_deferred_entries, :reason, :string, charset: 'utf8', collation: 'utf8_unicode_ci' if column_exists?(:mail_deferred_entries, :reason)
      end
    end
  end
end
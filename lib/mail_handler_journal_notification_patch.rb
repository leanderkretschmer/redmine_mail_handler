# Unterdrueckt Redmine-Benachrichtigungen fuer Kommentare im Papierkorb-Ticket
# (Einstellung trash_ticket_id). Jeder in den Papierkorb verschobene Kommentar
# legt dort ein neues Journal an; ohne diesen Patch wuerde Redmine dafuer
# "Ticket aktualisiert"-Mails an Beobachter, Autor und Zustaendigen schicken.
#
# Greift ueber Journal#notify?, das Redmine in send_notification (after_create_commit)
# auswertet – damit sind alle Wege abgedeckt (Verteiler-Ansicht, Kommentar
# bearbeiten/verschieben, Mail-Import).
module MailHandlerJournalNotificationPatch
  def notify?
    return false if journalized_type == 'Issue' && MailHandlerDistributor.trash_issue_id > 0 &&
                    journalized_id == MailHandlerDistributor.trash_issue_id
    super
  end
end

Journal.prepend(MailHandlerJournalNotificationPatch) unless Journal.ancestors.include?(MailHandlerJournalNotificationPatch)

# View-Helper fuer die Menüpunkte "Ticket-Verteiler" (siehe init.rb).
# Redmine ruft Symbol-URLs eines Menüeintrags als Helper-Methode auf,
# fuer das Projektmenü mit dem Projekt als Argument.
module MailHandlerDistributorMenuHelper
  # Top-Menü → Posteingang-Verteiler (Root)
  def mail_handler_root_distributor_path
    issue = MailHandlerDistributor.root_issue
    issue ? issue_path(issue) : '#'
  end

  # Projektmenü → Alias-Verteiler des Projekts
  def mail_handler_project_distributor_path(project)
    issue = MailHandlerDistributor.issue_for_project(project)
    issue ? issue_path(issue) : '#'
  end
end

ApplicationHelper.include(MailHandlerDistributorMenuHelper) unless ApplicationHelper.include?(MailHandlerDistributorMenuHelper)

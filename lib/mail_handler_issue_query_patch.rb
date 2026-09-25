# Blendet Tickets mit dem System-Tracker "Ticket-Verteiler" (Einstellung
# distributor_tracker_name) in Ticketlisten standardmaessig aus: jede neue
# Abfrage mit Standardfilter (nur "Status offen") bekommt zusaetzlich den
# Filter "Tracker ist nicht <Verteiler-Tracker>". Der Filter ist im
# Filter-Formular sichtbar und kann vom Benutzer entfernt werden. Gespeicherte
# Abfragen und explizit gesetzte Filter bleiben unberuehrt.
module MailHandlerIssueQueryPatch
  def initialize(attributes = nil, *args)
    super
    # Nur den Redmine-Standardfilter ergaenzen, nie explizit uebergebene Filter
    if attributes.respond_to?(:key?) && (attributes.key?(:filters) || attributes.key?('filters'))
      return
    end
    return unless filters.is_a?(Hash) && filters.keys == ['status_id']

    tracker_id = MailHandlerDistributor.hidden_tracker_id
    return unless tracker_id

    filters['tracker_id'] = { operator: '!', values: [tracker_id.to_s] }
  rescue => e
    Rails.logger.warn("[MailHandler] IssueQuery patch: #{e.message}")
  end
end

IssueQuery.prepend(MailHandlerIssueQueryPatch) unless IssueQuery.ancestors.include?(MailHandlerIssueQueryPatch)

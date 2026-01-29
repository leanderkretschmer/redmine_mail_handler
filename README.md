# Import & User Creation Logic

## User Creation

Users are automatically created only under specific conditions.

**Condition:** An email is received from an unknown sender address **AND** the subject contains a valid ticket ID (e.g., `[#123]`).

**Location:** [MailHandlerService#create_new_user](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L383)

**Process:**
1. Check if user exists: [MailHandlerService#find_existing_user](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L640)
2. If not found and ticket ID exists, create user:
   ```ruby
   # lib/mail_handler_service.rb:776
   if ticket_id
     # Unknown user + ticket ID -> create user
     new_user = create_new_user(from_address)
   else
     # Unknown user without ticket ID -> defer
     defer_message(imap, msg_id, mail)
   end
   ```
3. User attributes:
   - **Login:** Email address (or dummy if configured)
   - **Firstname:** Derived from email ([MailHandlerService#get_user_firstname](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L480))
   - **Lastname:** 'Auto-generated' (configurable)
   - **Status:** Locked (`User::STATUS_LOCKED`)
   - **Notifications:** None

## Mail Import Logic

Mails are imported either as a new comment on a specific ticket or into a central "Inbox Ticket".

**Entry Point:** [MailHandlerService#process_message](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L702)

### Scenarios

1.  **Known User + Ticket ID:**
    - Action: Add to specific ticket.
    - Code: `add_mail_to_ticket(mail, ticket_id, existing_user)`

2.  **Known User + No Ticket ID:**
    - Action: Add to Inbox Ticket.
    - Code: `add_mail_to_inbox_ticket(mail, existing_user)`
    - Requirement: `inbox_ticket_id` setting must be set.

3.  **Unknown User + Ticket ID:**
    - Action: Create User -> Add to specific ticket.

4.  **Unknown User + No Ticket ID:**
    - Action: Defer message (moved to 'Deferred' folder).
    - Logic: User needs to be created manually or wait for retry.

### Deferred Processing

Mails from unknown users without ticket IDs are parked in the 'Deferred' folder.

**Location:** [MailHandlerService#process_deferred_mails](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L87)

- The system periodically checks these mails.
- If the user has been created since the mail arrived, the mail is processed.
- If the deferral period expires, the mail is moved to 'Archive'.

## Code References

- **Main Loop:** [MailHandlerService#import_mails](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L27)
- **Ticket ID Extraction:** [MailHandlerService#extract_ticket_id](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L811)
- **Adding Comment:** [MailHandlerService#add_mail_to_ticket](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L822)

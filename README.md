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
- If the mail is from an address on the ignore list or from one of the system's own addresses (IMAP/SMTP account, Redmine `mail_from`, dummy-mail domain), it is moved to 'Ignored' instead. No user is ever created for a system address.
- If the recipient matches an alias from the address matrix, the user is created and the mail is filed into the alias ticket. **Alias mails never stay in 'Deferred'.** A ticket ID in the subject alone does *not* create a user (that would re-import bounced Redmine notifications); such mails stay deferred until the sender exists.
- If the deferral period expires, the mail is moved to 'Archive'.

## Restart & "Sudden" User Creation from Deferred

If many mails from the "Deferred" folder are processed after a restart, it usually means **users were created externally** (e.g., LDAP Sync, Manual Creation) while the mails were deferred.

**Explanation:**
1.  **Logic:** The deferred processing job ([MailHandlerService#process_deferred_message](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L204)) strictly checks if a user **already exists** (`find_existing_user`).
2.  **No Creation:** It does **NOT** create new users, except for mails whose recipient matches an alias in the address matrix (those are processed immediately).
3.  **Trigger:** When the scheduler starts (on restart) or the cron job runs (e.g. 02:00), it iterates through all deferred mails.
4.  **Match:** If it finds that users (who were previously unknown) now exist in Redmine, it processes the mails and archives them.

**Possible External Factors:**
- **LDAP Synchronization:** Users logged in or were synced via cron.
- **Manual Administration:** An admin created the users.
- **Other Plugins:** Another tool created the user records.

## Distributor View (Verteiler-Ansicht)

For distributor tickets the plugin replaces the normal issue page (`issues#show`) with a sorting UI. Redmine's header and menus stay, only the content area changes. `?classic=1` opens the standard issue view.

**Distributor tickets:**
- **Root distributor:** the inbox ticket (`inbox_ticket_id`).
- **Alias distributors:** every ticket referenced in the address matrix.

**Layout:**
- Top 40 %: all comments of the ticket, one compact row each: `#journal_id | author | first line of the comment`, followed by a ticket number input (Enter or → moves the comment) and, if available, a suggested target ticket (click to move).
- Below: the move targets. The root distributor shows one box per alias distributor (ticket ID, project, alias address). An alias distributor shows all visible tickets of its project as vertical columns per tracker (tracker order); clicking a tracker header shows only that tracker as a grid across the full width, clicking again restores all columns. Closed tickets are hidden by default (toggle).
- Comments can be dragged from the top area and dropped on any box.

**Moving:** `POST /mail_handler/distributor/move_comment` (`journal_id`, `target_issue_id`) delegates to the `redmine_move_comments` plugin via its `controller_journals_edit_post` hook, so the move behaves exactly like "move to issue" in the comment edit form (attachments, sendmail badges, pdftopng listeners). The plugin must be installed. Only users who may edit the comment can move it.

**Suggestions:** every move is logged in `mail_handler_comment_moves` (hook `move_comments_after_journal_move`). A target is suggested for a sender once their last 3 moves out of the same distributor all went to the same ticket. If the targets vary, no suggestion is shown.

**Search:** the targets area has a filter box; tiles (and tracker columns) that do not match all typed words are hidden. The filter survives moves (no reload) and is remembered per distributor in `sessionStorage`.

**Suggestions in the root distributor** are shown as projects (`identifier · name`), because targets there are alias distributors, one per project. Alias distributors suggest tickets (`#id subject`). Root tiles show the project identifier bold and the ticket number small.

**Hiding alias distributors in the root view:** the address matrix has a fourth field per line (`email:ticket:mark_project:hide_in_root`, checkbox "Im Root ausblenden" in the settings table). Entries flagged `1` are not offered as tiles in the inbox distributor; mail assignment, project menu and the alias ticket's own view are unaffected.

**Trash:** the setting `trash_ticket_id` names a system ticket that every distributor offers as drop target "Papierkorb". Moved comments are kept `trash_retention_hours` (default 48) and then deleted by an hourly scheduler job (`MailHandlerDistributor.purge_trash!`, including moved attachments). The trash ticket has its own view listing every entry with origin ticket, remaining time and a "zurück" button that moves the comment back to the ticket it came from (origin taken from `mail_handler_comment_moves`).

**System tracker:** the setting `distributor_tracker_name` (default `Ticket-Verteiler`) names a tracker for all system tickets (inbox, alias distributors, trash). "Mail Handler Administration › System-Tracker anwenden" creates it if needed, enables it in the affected projects and assigns it to those tickets. `IssueQuery` is patched (`lib/mail_handler_issue_query_patch.rb`) so that every new query with Redmine's default filter additionally gets "Tracker is not <that tracker>", hiding the system tickets from issue lists by default; the filter is visible and removable, saved queries and explicit filters are untouched.

**Menu items:** users with the role named in the setting `distributor_role_name` (default `Ticket_Verteiler`) and admins get a top-menu entry "Ticket-Verteiler" linking to the inbox ticket, and in every project that has an alias distributor a project-menu entry "Ticket-Verteiler" linking to that project's alias ticket (lowest ID if several). Registered in `init.rb`, URLs come from `lib/mail_handler_distributor_menu_helper.rb`.

**Code:** `lib/mail_handler_distributor.rb` (data), `lib/mail_handler_distributor_issues_patch.rb` (issues#show override), `app/controllers/mail_handler_distributor_controller.rb`, `app/views/mail_handler_distributor/show.html.erb`, `assets/{javascripts,stylesheets}/mail_handler_distributor.*`, `app/models/mail_handler_comment_move.rb`.

## Code References

- **Main Loop:** [MailHandlerService#import_mails](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L27)
- **Ticket ID Extraction:** [MailHandlerService#extract_ticket_id](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L811)
- **Adding Comment:** [MailHandlerService#add_mail_to_ticket](file:///Users/leanderkretschmer/redmine_mail_handler-2/lib/mail_handler_service.rb#L822)

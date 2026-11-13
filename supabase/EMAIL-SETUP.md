# Guild email setup (qgpcwebapp@gmail.com), one time

All site email goes out from the guild Gmail account, two ways:
- Supabase's own sign-in emails (password reset, magic link) use the SMTP settings in step 2.
- Every other email (new-member invite, renewal approved, renewal reminder, declined) is sent by an Edge Function using the two secrets in step 3.

## 1. Gmail app password
1. Sign in to qgpcwebapp@gmail.com. Go to myaccount.google.com/apppasswords (2-Step Verification must be on; turn it on under Security first if the page says it is not available).
2. Create one named "Guild website".
3. Copy the 16-letter password. Keep it private; it goes only into Supabase (steps 2 and 3). Google shows it once; if lost, make a new one and update both places.

## 2. Supabase: send Supabase's own emails through Gmail
Authentication > Emails (or Project Settings > Authentication) > SMTP Settings > turn on Custom SMTP:
- Sender email: qgpcwebapp@gmail.com
- Sender name: Quilters Guild of Parker County
- Host: smtp.gmail.com   Port: 465
- Username: qgpcwebapp@gmail.com   Password: the app password
Save. Then Authentication > Rate Limits: raise "emails sent per hour" (default is low) to about 30.
Wording of the password-reset and magic-link emails is edited under Authentication > Emails > Templates ("Reset password", "Magic link"). The "Invite user" template is no longer used.

## 3. Supabase: secrets for the Edge Functions
Edge Functions > Secrets:
- `GMAIL_USER` = qgpcwebapp@gmail.com
- `GMAIL_APP_PASSWORD` = the app password (paste it; do not retype it)
Optional: `SITE_URL` = https://qgpc.github.io/WebApp/ (this is the default).

## 4. Deploy the functions
Edge Functions > Deploy a new function > Via Editor. One function per folder under `supabase/functions/`, named exactly like the folder; paste in its `index.ts`, then Deploy. Leave "Verify JWT" on.
- `invite-member` (new-member sign-in email; wording is in the file)
- `send-renewal-email` (renewal approved)
- `send-renewal-reminders` (reminder to members who have not renewed)
- `send-decline-email` (request declined)
To change a function later, open it in the dashboard, paste the new code over the old, Deploy.

## 5. Commit and push
GitHub Desktop: commit the changed pages and the `supabase` folder, push, then Ctrl+Shift+R on the site.

## Sending limits
A normal Gmail account allows about 500 recipients a day. A renewal reminder to the whole not-yet-renewed list uses one per member, so it fits easily for a guild this size.

## Test
- New member: submit a test application on Join (use an address you control), Payment Received, Membership Approved. You should see "Sign-in email sent to ...". Open the email and set a password. If a person already has an account, the page says so; they use Forgot password instead.
- Renewal approved: approve a test renewal; "Renewal approved. An email was sent to ...".
- Reminder: with the Renew Membership switch on, open Membership Database, choose Status "Not yet renewed", Send a renewal reminder.

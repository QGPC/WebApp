# Guild email setup (qgpcwebapp@gmail.com), one time

## 1. Gmail app password
1. Sign in to qgpcwebapp@gmail.com. Google Account > Security > turn on 2-Step Verification (required).
2. Search "App passwords" in the Google Account search box. Create one named "Guild website".
3. Copy the 16-letter password. Keep it private; it goes only into Supabase (step 2).

## 2. Supabase: send all site email through Gmail
Authentication > Emails (or Project Settings > Authentication) > SMTP Settings > turn on Custom SMTP:
- Sender email: qgpcwebapp@gmail.com
- Sender name: Quilters Guild of Parker County
- Host: smtp.gmail.com   Port: 465
- Username: qgpcwebapp@gmail.com   Password: the app password
Save. Then Authentication > Rate Limits: raise "emails sent per hour" (default is low) to about 30.

## 3. Invite email wording
Authentication > Emails > Templates > "Invite user". Suggested subject: Welcome to the Quilters Guild website
Keep the {{ .ConfirmationURL }} link in the body. (Final wording: see the draft emails doc.)

## 4. Deploy the function
Edge Functions > Deploy a new function > Via Editor. Name it exactly `invite-member`.
Paste in the contents of `supabase/functions/invite-member/index.ts`, then Deploy.
(Leave "Verify JWT" on.)

## 5. Commit and push
GitHub Desktop: commit `membership-requests.html` and the `supabase` folder, push, then Ctrl+Shift+R on the site.

## Test
Submit a test application on Join (use an address you control), Payment Received, Membership Approved.
You should see "Sign-in email sent to ...". Open the email and set a password.
If a person already has an account, the page says so; they use Forgot password instead.

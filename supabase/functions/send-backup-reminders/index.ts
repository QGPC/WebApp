// send-backup-reminders: emails every Superuser and Administrator when a site backup is due.
// Who can call it:
//   * a signed-in Superuser or Administrator (the Backups page calls it once per visit when a backup is due), or
//   * a scheduled job that sends the header x-cron-secret equal to the secret CRON_SECRET (see the end of
//     supabase/44-backup-restore.sql). Deploy this function with "Verify JWT" turned OFF; it checks who is calling.
// When it sends: a backup is due (the newest backup_log row is older than the reminder setting, or there is none),
// and no reminder has gone out since the due date, or the last one was 7 or more days ago. A backup made by
// anyone ends the reminders. Body: {} (nothing needed). Returns { ok, due, sent, reason }.
// Sends through the guild Gmail account using the secrets GMAIL_USER and GMAIL_APP_PASSWORD.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const SITE = Deno.env.get("SITE_URL") ?? "https://qgpc.github.io/WebApp/";
const GUILD = "Quilter's Guild of Parker County";
const cors = {
  "Access-Control-Allow-Origin": "https://qgpc.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const DAY = 86400000;

// calendar date in Texas for a moment in time, as yyyy-mm-dd
const txDate = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // who is asking?
    const secret = Deno.env.get("CRON_SECRET");
    const sent = req.headers.get("x-cron-secret");
    let allowed = !!secret && !!sent && sent === secret;
    if (!allowed) {
      const auth = req.headers.get("Authorization") ?? "";
      const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
      const { data: u } = await caller.auth.getUser();
      if (!u?.user) return reply({ error: "Please sign in again." }, 401);
      const isAdm = await caller.rpc("is_admin");
      if (isAdm.data !== true) return reply({ error: "Only a Superuser or an Administrator can do this." }, 403);
      allowed = true;
    }

    const { data: cfg } = await admin.from("site_config").select("backup_reminder_days").limit(1).single();
    const days = Number(cfg?.backup_reminder_days) || 30;
    const { data: lastRow } = await admin.from("backup_log").select("performed_at").order("performed_at", { ascending: false }).limit(1);
    const last = lastRow && lastRow[0] ? new Date(lastRow[0].performed_at) : null;
    const now = new Date();
    const today = txDate(now);
    let dueDate = today;                       // never backed up: due now
    if (last) {
      const d = new Date(txDate(last) + "T12:00:00Z");
      dueDate = new Date(d.getTime() + days * DAY).toISOString().slice(0, 10);
    }
    if (dueDate > today) return reply({ ok: true, due: false, sent: 0, reason: "No backup is due yet." });

    const { data: remRow } = await admin.from("backup_reminders").select("sent_at").order("sent_at", { ascending: false }).limit(1);
    const lastRem = remRow && remRow[0] ? new Date(remRow[0].sent_at) : null;
    if (lastRem) {
      const sinceDue = txDate(lastRem) >= dueDate;            // already reminded since it came due
      const recent = now.getTime() - lastRem.getTime() < 7 * DAY - 3600000;
      if (sinceDue && recent) return reply({ ok: true, due: true, sent: 0, reason: "A reminder was already sent this week." });
    }

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);

    const { data: holders } = await admin.from("member_roles").select("members(email, first_name)").in("role_key", ["superuser", "administrator"]);
    const seen = new Set<string>();
    const people: { email: string; first: string }[] = [];
    for (const h of (holders ?? []) as { members: { email: string; first_name: string } | { email: string; first_name: string }[] | null }[]) {
      const m = Array.isArray(h.members) ? h.members[0] : h.members;
      if (m?.email && !seen.has(m.email.toLowerCase())) { seen.add(m.email.toLowerCase()); people.push({ email: m.email, first: m.first_name }); }
    }
    if (!people.length) return reply({ ok: true, due: true, sent: 0, reason: "No Superuser or Administrator has an email address." });

    const overdue = Math.floor((new Date(today + "T12:00:00Z").getTime() - new Date(dueDate + "T12:00:00Z").getTime()) / DAY);
    const when = last
      ? `The last backup was made on ${new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", year: "numeric", month: "long", day: "numeric" }).format(last)}.`
      : "No backup has been made yet.";
    const transport = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    let okCount = 0;
    const failed: string[] = [];
    for (const p of people) {
      const lines = [
        `Hello ${p.first},`,
        "",
        overdue > 0 ? `A backup of the Guild website is overdue (it was due ${overdue} day${overdue === 1 ? "" : "s"} ago). ${when}` : `A backup of the Guild website is due today. ${when}`,
        "",
        `To make one, sign in at ${SITE}, open Site Administration, and choose Backups. It takes about a minute. Put the backup's password in the Guild's password manager. A backup made by any Superuser or Administrator clears this reminder for everyone.`,
        "",
        "Do not reply to this message with a password or a backup file.",
        "",
        GUILD + " website",
      ];
      try {
        await transport.sendMail({
          from: `"${GUILD}" <${user}>`,
          to: p.email,
          subject: "Time to back up the Guild website",
          text: lines.join("\n"),
          html: lines.map((l) => (l === "" ? "<br>" : `<p style="margin:0 0 8px">${esc(l)}</p>`)).join(""),
        });
        okCount++;
      } catch (e) {
        failed.push(p.email + ": " + String((e as Error)?.message ?? e));
      }
    }
    if (okCount > 0) await admin.from("backup_reminders").insert({ recipients: okCount });
    return reply({ ok: true, due: true, sent: okCount, failed });
  } catch (e) {
    return reply({ error: "The reminder could not be sent: " + String((e as Error)?.message ?? e) }, 500);
  }
});

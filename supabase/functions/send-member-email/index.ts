// send-member-email: one email from a board member to every current member.
// Who can call it: the President, Vice President, Program Chair, Administrators and the Superuser.
// Current members = status Active or in the grace period, with an email address.
// Each member gets their own message (addresses stay private). Sent through the guild Gmail account
// using the secrets GMAIL_USER and GMAIL_APP_PASSWORD. Gmail allows about 500 a day; this function
// refuses a send that would go past DAILY_LIMIT (counted with the database function emails_sent_today).
// Calls (JSON body, `action`):
//   status                              -> who it would go to, today's count, the sender's name and role
//   test    {subject, message, reply_to} -> one copy to the caller (counts as 1)
//   start   {subject, message, reply_to} -> records the send, returns {email_id, recipients}
//   batch   {email_id}                   -> sends the next 20 not yet sent; returns {sent, failed, remaining}
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const DAILY_LIMIT = 500;
const BATCH = 20;
const GUILD = "Quilter's Guild of Parker County";
const FOOTER = `You are receiving this email because you are a member of the ${GUILD}.`;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

type Member = { id: string; first_name: string; last_name: string; email: string };

function build(message: string, name: string, role: string) {
  const sig = `— ${name}${role ? ", " + role : ""}`;
  const text = `${message}\n\n${sig}\n${GUILD}\n\n${FOOTER}`;
  const paras = message.split(/\n{2,}/).map((p) =>
    `<p style="margin:0 0 14px;line-height:1.5">${esc(p).replace(/\n/g, "<br>")}</p>`).join("");
  const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;color:#1F2433">${paras}` +
    `<p style="margin:18px 0 0">${esc(sig)}<br>${esc(GUILD)}</p>` +
    `<p style="margin:22px 0 0;font-size:13px;color:#5A5F6E">${esc(FOOTER)}</p></div>`;
  return { text, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return reply({ error: "Please sign in again." }, 401);
    const ok = await caller.rpc("can_email_members");
    if (ok.data !== true) return reply({ error: "Only the President, Vice President, Program Chair, Administrators and the Superuser can email the members." }, 403);

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action ?? "");
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const me = (await caller.rpc("current_member_id")).data as string | null;
    if (!me) return reply({ error: "No membership record is linked to this account." }, 403);
    const { data: self } = await admin.from("members").select("first_name, last_name, email").eq("id", me).single();
    const name = `${self?.first_name ?? ""} ${self?.last_name ?? ""}`.trim();
    // the sender's most senior role (lowest sort order) for the signature
    const { data: mr } = await admin.from("member_roles").select("role_key").eq("member_id", me);
    const keys = (mr ?? []).map((x: { role_key: string }) => x.role_key);
    let role = "";
    if (keys.length) {
      const { data: rl } = await admin.from("roles").select("label, sort_order").in("role_key", keys).order("sort_order").limit(1);
      role = rl?.[0]?.label ?? "";
    }

    const gmailUser = Deno.env.get("GMAIL_USER");
    const countRecipients = async () => {
      const { data, error } = await admin.from("members_with_status").select("id, first_name, last_name, email")
        .in("status", ["active", "grace"]).not("email", "is", null).neq("email", "").order("last_name").limit(2000);
      if (error) throw new Error("Could not read the member list.");
      return (data ?? []) as Member[];
    };
    const sentToday = async () => Number((await admin.rpc("emails_sent_today")).data ?? 0);

    if (action === "status") {
      const members = await countRecipients();
      const { count: inactive } = await admin.from("members_with_status").select("id", { count: "exact", head: true }).eq("status", "inactive");
      const today = await sentToday();
      return reply({ ok: true, recipients: members.length, inactive: inactive ?? 0, sent_today: today, limit: DAILY_LIMIT,
        sender_name: name, sender_role: role, sender_email: self?.email ?? "", from_address: gmailUser ?? "" });
    }

    // the rest need a subject and a message (not "batch", which uses the saved send)
    const subject = String(body?.subject ?? "").replace(/[\r\n]+/g, " ").trim();
    const message = String(body?.message ?? "").replace(/\r\n/g, "\n").trim();
    const replyTo = body?.reply_to === "sender" ? "sender" : "guild";
    const pass = Deno.env.get("GMAIL_APP_PASSWORD");
    const mailer = () => {
      if (!gmailUser || !pass) throw new Error("Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD).");
      return nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gmailUser, pass } });
    };
    const headerFor = (to: string, subj: string, rt: string, n: string, r: string, msg: string) => {
      const b = build(msg, n, r);
      return {
        from: `"${GUILD}" <${gmailUser}>`, to, subject: subj,
        ...(rt === "sender" && self?.email ? { replyTo: `"${n}" <${self.email}>` } : {}),
        text: b.text, html: b.html,
      };
    };

    if (action === "test" || action === "start") {
      if (!subject) return reply({ error: "Please type a subject." }, 400);
      if (!message) return reply({ error: "Please type a message." }, 400);
      if (subject.length > 150) return reply({ error: "The subject is too long (150 letters at most)." }, 400);
      if (message.length > 10000) return reply({ error: "The message is too long." }, 400);
      const today = await sentToday();

      if (action === "test") {
        if (today + 1 > DAILY_LIMIT) return reply({ error: "The daily email limit has been reached. Please try again tomorrow." }, 409);
        if (!self?.email) return reply({ error: "Your membership record has no email address." }, 400);
        const t = mailer();
        await t.sendMail(headerFor(self.email, "[Test] " + subject, replyTo, name, role, message));
        await admin.from("member_emails").insert({ sent_by: me, sender_name: name, sender_role: role, subject, body: message,
          reply_to: replyTo, is_test: true, recipients: 1, sent: 1 });
        return reply({ ok: true, to: self.email });
      }

      const members = await countRecipients();
      if (!members.length) return reply({ error: "There are no current members with an email address." }, 409);
      if (today + members.length > DAILY_LIMIT) {
        return reply({ error: `This would send ${members.length} emails, but only ${Math.max(0, DAILY_LIMIT - today)} are left today (Gmail allows about ${DAILY_LIMIT} a day). Please send it tomorrow.` }, 409);
      }
      const { data: row, error } = await admin.from("member_emails").insert({ sent_by: me, sender_name: name, sender_role: role,
        subject, body: message, reply_to: replyTo, is_test: false, recipients: members.length }).select("id").single();
      if (error || !row) return reply({ error: "Could not start the send." }, 500);
      return reply({ ok: true, email_id: row.id, recipients: members.length });
    }

    if (action === "batch") {
      const emailId = String(body?.email_id ?? "");
      const { data: em } = await admin.from("member_emails").select("*").eq("id", emailId).single();
      if (!em) return reply({ error: "That send was not found." }, 404);
      if (em.sent_by !== me) return reply({ error: "Only the person who started this send can continue it." }, 403);
      if (em.is_test) return reply({ error: "That was a test copy." }, 400);
      const members = await countRecipients();
      const { data: done } = await admin.from("member_email_recipients").select("member_id").eq("email_id", emailId);
      const doneSet = new Set((done ?? []).map((x: { member_id: string }) => x.member_id));
      const todo = members.filter((m) => !doneSet.has(m.id));
      const slice = todo.slice(0, BATCH);
      const t = slice.length ? mailer() : null;
      let sent = 0, failed = 0;
      for (const m of slice) {
        try {
          await t!.sendMail(headerFor(m.email, em.subject, em.reply_to, em.sender_name ?? "", em.sender_role ?? "", em.body));
          await admin.from("member_email_recipients").insert({ email_id: emailId, member_id: m.id, status: "sent" });
          sent++;
        } catch (e) {
          await admin.from("member_email_recipients").insert({ email_id: emailId, member_id: m.id, status: "failed",
            error: String((e as Error)?.message ?? e).slice(0, 300) });
          failed++;
        }
      }
      const { data: all } = await admin.from("member_email_recipients").select("status").eq("email_id", emailId);
      const s = (all ?? []).filter((x: { status: string }) => x.status === "sent").length;
      const f = (all ?? []).filter((x: { status: string }) => x.status === "failed").length;
      await admin.from("member_emails").update({ sent: s, failed: f }).eq("id", emailId);
      return reply({ ok: true, sent_now: sent, failed_now: failed, sent: s, failed: f, planned: em.recipients,
        remaining: Math.max(0, todo.length - slice.length) });
    }

    return reply({ error: "Unknown request." }, 400);
  } catch (e) {
    return reply({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

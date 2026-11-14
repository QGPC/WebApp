// send-workshop-reminder: the Workshops Chair emails everyone registered for a workshop.
// Who can call it: the Workshops Chair, Administrators and the Superuser (can_cancel_workshops).
// Body: { month_id, message }. Goes to registrations that are accepted or paid and waiting for acceptance
// (not the waitlist, not cancelled). One separate email per person, through the guild Gmail account
// (GMAIL_USER, GMAIL_APP_PASSWORD). Records the time and count on the workshop month.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const GUILD = "Quilter's Guild of Parker County";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return reply({ error: "Please sign in again." }, 401);
    const ok = await caller.rpc("can_cancel_workshops");
    if (ok.data !== true) return reply({ error: "Only the Workshops Chair can send reminders." }, 403);

    const body = await req.json().catch(() => ({}));
    const monthId = String(body?.month_id ?? "");
    const message = String(body?.message ?? "").trim();
    if (!monthId) return reply({ error: "No workshop was given." }, 400);
    if (!message) return reply({ error: "Please write the reminder." }, 400);
    if (message.length > 4000) return reply({ error: "That reminder is too long." }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: m } = await admin.from("program_months").select("id, ws_title").eq("id", monthId).single();
    if (!m) return reply({ error: "That workshop was not found." }, 404);
    const { data: regs } = await admin.from("workshop_registrations")
      .select("name, email").eq("month_id", monthId).in("status", ["waiting", "accepted"]);
    if (!regs || !regs.length) return reply({ error: "Nobody is registered for this workshop yet." }, 409);

    const gmailUser = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!gmailUser || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);

    const t = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gmailUser, pass } });
    const title = m.ws_title || "your workshop";
    let sent = 0;
    const failed: string[] = [];
    for (const r of regs) {
      const first = String(r.name || "").trim().split(/\s+/)[0] || "there";
      const text = `Hello ${first},\n\n${message}\n\n${GUILD}`;
      const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;color:#1F2433"><p style="margin:0 0 14px;line-height:1.5">Hello ${esc(first)},</p>` +
        message.split(/\n{2,}/).map((p) => `<p style="margin:0 0 14px;line-height:1.5">${esc(p).replace(/\n/g, "<br>")}</p>`).join("") +
        `<p style="margin:18px 0 0">${esc(GUILD)}</p></div>`;
      try {
        await t.sendMail({ from: `"${GUILD}" <${gmailUser}>`, to: r.email, subject: `Reminder: ${title}`, text, html });
        sent++;
      } catch (_e) {
        failed.push(String(r.name));
      }
    }
    if (sent > 0) {
      await admin.from("program_months").update({ ws_reminder_at: new Date().toISOString(), ws_reminder_count: sent }).eq("id", monthId);
    }
    return reply({ ok: true, sent, failed });
  } catch (e) {
    return reply({ error: e instanceof Error ? e.message : "Something went wrong." }, 500);
  }
});

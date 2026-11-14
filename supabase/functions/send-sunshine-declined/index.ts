// send-sunshine-declined: emails the person who shared a Sunshine & Shadows note when the Chair declines it
// and wrote a note to them. Who can call it: the Sunshine & Shadows Chair, Administrators and the Superuser
// (can_manage_sunshine). Body: { note_id }. Sent through the guild Gmail account (GMAIL_USER, GMAIL_APP_PASSWORD).
// The result is recorded on the note (decline_emailed_at or email_error).
// Wording is a first draft for Rex to approve.
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
    const ok = await caller.rpc("can_manage_sunshine");
    if (ok.data !== true) return reply({ error: "Only the Sunshine & Shadows Chair can send this email." }, 403);

    const body = await req.json().catch(() => ({}));
    const id = String(body?.note_id ?? "");
    if (!id) return reply({ error: "No note was given." }, 400);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: n } = await admin.from("sunshine_notes").select("*").eq("id", id).single();
    if (!n) return reply({ error: "That note was not found." }, 404);
    if (n.status !== "declined") return reply({ error: "That note was not declined." }, 409);
    if (!n.decline_note) return reply({ error: "There is no note to send." }, 400);
    const { data: m } = await admin.from("members").select("first_name,email").eq("id", n.submitted_by).single();
    if (!m?.email) return reply({ error: "The sender has no email address on file." }, 404);

    const gmailUser = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!gmailUser || !pass) {
      const msg = "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD).";
      await admin.from("sunshine_notes").update({ email_error: msg }).eq("id", id);
      return reply({ error: msg }, 500);
    }

    const lines = [
      `Hello ${m.first_name},`,
      `Thank you for sharing a note about ${n.about_name} with the Sunshine & Shadows Chair. We were not able to post it on the Guild website.`,
      n.decline_note,
      `If you have any questions, just reply to this email.`,
    ];
    const text = `${lines.join("\n\n")}\n\n${GUILD}`;
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;color:#1F2433">` +
      lines.map((l) => `<p style="margin:0 0 14px;line-height:1.5">${esc(l)}</p>`).join("") +
      `<p style="margin:18px 0 0">${esc(GUILD)}</p></div>`;

    try {
      const t = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gmailUser, pass } });
      await t.sendMail({ from: `"${GUILD}" <${gmailUser}>`, to: m.email, subject: "About the note you shared", text, html });
    } catch (e) {
      const msg = "The email could not be sent. " + (e instanceof Error ? e.message : "");
      await admin.from("sunshine_notes").update({ email_error: msg.slice(0, 300) }).eq("id", id);
      return reply({ error: "Email not sent." }, 502);
    }
    await admin.from("sunshine_notes").update({ decline_emailed_at: new Date().toISOString(), email_error: null }).eq("id", id);
    return reply({ ok: true });
  } catch (e) {
    return reply({ error: e instanceof Error ? e.message : "Something went wrong." }, 500);
  }
});

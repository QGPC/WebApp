// send-workshop-accepted: emails a person that their workshop registration was accepted.
// Who can call it: the Workshop Manager (Workshops Chair, Program Chair, Administrators, Superuser).
// Body: { registration_id }. Sent through the guild Gmail account (GMAIL_USER, GMAIL_APP_PASSWORD).
// Members get a link to the Programs & Workshops page (they sign in). Non-members get their private
// materials link. The result is recorded on the registration (last_accepted_email_at or email_error).
// Wording is a first draft for Rex to approve.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const SITE = Deno.env.get("SITE_URL") ?? "https://qgpc.github.io/WebApp/";
const GUILD = "Quilter's Guild of Parker County";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const niceDate = (d: string | null) =>
  d ? new Date(d + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric", year: "numeric", timeZone: "UTC" }) : "";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const auth = req.headers.get("Authorization") ?? "";
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return reply({ error: "Please sign in again." }, 401);
    const ok = await caller.rpc("can_manage_workshops");
    if (ok.data !== true) return reply({ error: "Only the Workshop Manager can send this email." }, 403);

    const body = await req.json().catch(() => ({}));
    const id = String(body?.registration_id ?? "");
    if (!id) return reply({ error: "No registration was given." }, 400);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    const { data: reg } = await admin.from("workshop_registrations").select("*").eq("id", id).single();
    if (!reg) return reply({ error: "That registration was not found." }, 404);
    if (reg.status !== "accepted") return reply({ error: "That registration is not accepted." }, 409);
    const { data: m } = await admin.from("program_months").select("*").eq("id", reg.month_id).single();
    if (!m) return reply({ error: "That workshop was not found." }, 404);

    const gmailUser = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!gmailUser || !pass) {
      const msg = "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD).";
      await admin.from("workshop_registrations").update({ email_error: msg }).eq("id", id);
      return reply({ error: msg }, 500);
    }

    const title = m.ws_title || "the workshop";
    const link = reg.is_member
      ? `${SITE}programs.html?m=${String(m.month_on).slice(0, 7)}`
      : `${SITE}materials.html?t=${reg.access_token}`;
    const when = [niceDate(m.ws_date), m.ws_time].filter(Boolean).join(", ");
    const where = m.ws_place || m.prog_place || "";
    const lines = [
      `Hello ${reg.name},`,
      `Your registration for ${title} is accepted. We are glad you are coming!`,
      [when && `When: ${when}`, where && `Where: ${where}`].filter(Boolean).join("\n"),
      reg.is_member
        ? `Your patterns and materials are now open. Sign in and open the workshop on the Programs & Workshops page:\n${link}`
        : `Your patterns and materials are now open. This is your private link; please keep it to yourself:\n${link}`,
      `If you have any questions, just reply to this email.`,
    ].filter(Boolean);
    const text = `${lines.join("\n\n")}\n\n${GUILD}`;
    const html = `<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;color:#1F2433">` +
      lines.map((l) => `<p style="margin:0 0 14px;line-height:1.5">${esc(l).replace(/\n/g, "<br>").replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1">$1</a>')}</p>`).join("") +
      `<p style="margin:18px 0 0">${esc(GUILD)}</p></div>`;

    try {
      const t = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user: gmailUser, pass } });
      await t.sendMail({ from: `"${GUILD}" <${gmailUser}>`, to: reg.email, subject: `Your registration for ${title} is accepted`, text, html });
    } catch (e) {
      const msg = "The email could not be sent. " + (e instanceof Error ? e.message : "");
      await admin.from("workshop_registrations").update({ email_error: msg.slice(0, 300) }).eq("id", id);
      return reply({ error: "Email not sent. Try again." }, 502);
    }
    await admin.from("workshop_registrations").update({ last_accepted_email_at: new Date().toISOString(), email_error: null }).eq("id", id);
    return reply({ ok: true });
  } catch (e) {
    return reply({ error: e instanceof Error ? e.message : "Something went wrong." }, 500);
  }
});

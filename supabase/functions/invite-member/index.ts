// invite-member: emails a newly approved member the link to set up their password.
// Only the Membership Chair or the Superuser can call it.
// The sign-in link is made by Supabase (generateLink) and the email is sent from the guild Gmail account,
// the same way as send-decline-email and send-renewal-email, using the secrets GMAIL_USER and GMAIL_APP_PASSWORD.
// The wording lives in this file, so the Supabase "Invite user" email template is no longer used.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const SITE = Deno.env.get("SITE_URL") ?? "https://qgpc.github.io/WebApp/";
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

    // who is asking? (uses their own sign-in, so database rules apply)
    const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
    const { data: u } = await caller.auth.getUser();
    if (!u?.user) return reply({ error: "Please sign in again." }, 401);
    const su = await caller.rpc("is_superuser");
    const mc = await caller.rpc("has_role", { p_role: "membership_chair" });
    if (!(su.data === true || mc.data === true)) return reply({ error: "Only the Membership Chair or the Superuser can send sign-in emails." }, 403);

    const { member_id } = await req.json();
    if (!member_id) return reply({ error: "Missing member." }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: m, error: me } = await admin.from("members").select("email, first_name, paid_through_year").eq("id", member_id).single();
    if (me || !m?.email) return reply({ error: "Member not found." }, 404);

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);

    // make the one-time "set up your password" link (this also creates the sign-in account)
    const { data: link, error: le } = await admin.auth.admin.generateLink({
      type: "invite", email: m.email, options: { redirectTo: SITE + "set-password.html" },
    });
    if (le || !link?.properties?.action_link) {
      const msg = le?.message ?? "";
      const already = /already|registered|exists/i.test(msg);
      return reply({ error: already ? "That person already has a website account. Ask them to use Forgot password on the sign-in page." : (msg || "The sign-in link could not be made.") }, already ? 409 : 500);
    }
    const actionLink = link.properties.action_link;

    const through = m.paid_through_year ? `Your membership runs through December 31, ${m.paid_through_year}.` : "";
    const intro = [
      `Hello ${m.first_name},`,
      "",
      "Your membership in the Quilter's Guild of Parker County has been approved. Welcome!",
      ...(through ? ["", through] : []),
      "",
      "To sign in to the members' area, please set up your password using the link below. The link works once.",
    ];
    const outro = [
      `After that you can sign in any time at ${SITE} with this email address and your new password. If the link has stopped working, go to the sign-in card, choose "Forgot password?", and we will send a new one.`,
      "",
      "If you did not apply to join the Guild, you can ignore this message.",
      "",
      "Membership Chair",
      "Quilter's Guild of Parker County",
    ];
    const text = [...intro, "", actionLink, "", ...outro].join("\n");
    const p = (l: string) => (l === "" ? "<br>" : `<p style="margin:0 0 8px">${esc(l)}</p>`);
    const html = intro.map(p).join("")
      + `<p style="margin:14px 0"><a href="${esc(actionLink)}" style="display:inline-block;padding:12px 22px;border-radius:999px;background:#0157AE;color:#ffffff;font-weight:700;text-decoration:none">Set up my password</a></p>`
      + `<p style="margin:0 0 8px;font-size:13px;color:#5A5F6E">If the button does not work, copy this address into your browser:<br>${esc(actionLink)}</p>`
      + outro.map(p).join("");

    const transport = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    await transport.sendMail({
      from: `"Quilter's Guild of Parker County" <${user}>`,
      to: m.email,
      subject: "Welcome to the Quilter's Guild of Parker County",
      text, html,
    });

    return reply({ ok: true, email: m.email });
  } catch (e) {
    return reply({ error: "The email could not be sent: " + String((e as Error)?.message ?? e) }, 500);
  }
});

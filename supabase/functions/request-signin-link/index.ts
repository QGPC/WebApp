// request-signin-link: lets a member who has no website account yet (for example someone added by the
// CSV import) get their first "set up your password" email from the sign-in page ("Forgot password?").
// Anyone can call it, so it is careful:
//   * It ALWAYS answers the same way ({ ok: true }), whether or not the email belongs to a member, so it
//     cannot be used to find out who is a member.
//   * It only sends when the email matches a member record that has no website account.
//   * At most one email per address every 10 minutes, and no more than 150 emails a day from this function
//     (Gmail allows about 500 a day in total), counted in public.signin_link_requests.
// Sends through the guild Gmail account (qgpcwebapp@gmail.com) using the secrets GMAIL_USER and GMAIL_APP_PASSWORD.
// Members who already have an account get their reset email from Supabase as before.
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
    const body = await req.json().catch(() => ({}));
    const email = String(body?.email ?? "").trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 200) return reply({ ok: true });

    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

    // only a member record with no website account yet
    const { data: m } = await admin.from("members")
      .select("id, email, first_name, auth_user_id").eq("email", email).limit(1).maybeSingle();
    if (!m || m.auth_user_id) return reply({ ok: true });

    // rate limits
    const tenMin = new Date(Date.now() - 10 * 60 * 1000).toISOString();
    const day = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
    const recent = await admin.from("signin_link_requests").select("id", { count: "exact", head: true }).eq("email", email).gte("at", tenMin);
    if ((recent.count ?? 0) > 0) return reply({ ok: true });
    const today = await admin.from("signin_link_requests").select("id", { count: "exact", head: true }).gte("at", day);
    if ((today.count ?? 0) >= 150) return reply({ ok: true });

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ ok: true });

    await admin.from("signin_link_requests").insert({ email });
    await admin.from("signin_link_requests").delete().lt("at", new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString());

    const { data: link, error: le } = await admin.auth.admin.generateLink({
      type: "invite", email: m.email, options: { redirectTo: SITE + "set-password.html" },
    });
    if (le || !link?.properties?.action_link) return reply({ ok: true });
    const actionLink = link.properties.action_link;

    const intro = [
      `Hello ${m.first_name},`,
      "",
      "You asked to sign in to the Quilter's Guild of Parker County website for the first time. Your membership is on file.",
      "",
      "Please set up your password using the link below. The link works once.",
    ];
    const outro = [
      `After that you can sign in any time at ${SITE} with this email address and your new password. If the link has stopped working, go to the sign-in card, choose "Forgot password?", and we will send a new one.`,
      "",
      "If you did not ask for this, you can ignore this message. Nothing will change.",
      "",
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
      subject: "Set up your password for the Quilter's Guild website",
      text, html,
    });
    return reply({ ok: true });
  } catch (_e) {
    return reply({ ok: true });
  }
});

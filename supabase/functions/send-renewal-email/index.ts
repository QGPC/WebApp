// send-renewal-email: emails a member that their renewal was approved ("you are renewed through December 31, YYYY").
// Only the Membership Chair or the Superuser can call it. It only sends for a renewal request that has been approved,
// to the email address on that request. It sends once; the chair's "Send again" button passes resend: true.
// Wording comes from this file and the database, not from the caller.
// Sends through the guild Gmail account using the secrets GMAIL_USER and GMAIL_APP_PASSWORD (same as send-decline-email).
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
    if (!(su.data === true || mc.data === true)) return reply({ error: "Only the Membership Chair or the Superuser can send this email." }, 403);

    const { request_id, resend } = await req.json();
    if (!request_id) return reply({ error: "Missing request." }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: r, error: re } = await admin.from("membership_requests")
      .select("first_name, email, kind, status, renewal_year, approval_emailed_at").eq("id", request_id).single();
    if (re || !r) return reply({ error: "Request not found." }, 404);
    if (r.kind !== "renewal") return reply({ error: "That request is not a renewal." }, 409);
    if (r.status !== "approved") return reply({ error: "That renewal has not been approved." }, 409);
    if (r.approval_emailed_at && resend !== true) return reply({ error: "An email was already sent for that renewal." }, 409);

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);

    // the Membership Chair's email address(es), from the member list
    const { data: chairs } = await admin.from("member_roles").select("members(email)").eq("role_key", "membership_chair");
    const emails = (chairs ?? [])
      .map((c: { members: { email: string } | { email: string }[] | null }) => Array.isArray(c.members) ? c.members[0]?.email : c.members?.email)
      .filter((e: string | undefined): e is string => !!e);
    const contact = emails.join(" or ");

    const through = r.renewal_year ? `December 31, ${r.renewal_year}` : "the end of this year";
    const lines = [
      `Hello ${r.first_name},`,
      "",
      "Thank you for renewing your membership in the Quilter's Guild of Parker County!",
      "",
      `Your renewal has been approved, and your membership now runs through ${through}.`,
      "",
      `You can sign in to the members' area any time at ${SITE} with your email address and password. If you have forgotten your password, choose "Forgot password?" on the sign-in card.`,
      "",
      contact
        ? `If anything in your membership record looks wrong, please contact the Membership Chair at ${contact}.`
        : "If anything in your membership record looks wrong, please contact the Membership Chair.",
      "",
      "We are glad to have you with us.",
      "",
      "Membership Chair",
      "Quilter's Guild of Parker County",
    ];
    const text = lines.join("\n");
    const html = lines.map((l) => (l === "" ? "<br>" : `<p style="margin:0 0 8px">${esc(l)}</p>`)).join("");

    const transport = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    await transport.sendMail({
      from: `"Quilter's Guild of Parker County" <${user}>`,
      to: r.email,
      subject: "Your Quilter's Guild of Parker County membership is renewed",
      text, html,
    });

    await admin.from("membership_requests").update({ approval_emailed_at: new Date().toISOString() }).eq("id", request_id);
    return reply({ ok: true, email: r.email });
  } catch (e) {
    return reply({ error: "The email could not be sent: " + String((e as Error)?.message ?? e) }, 500);
  }
});

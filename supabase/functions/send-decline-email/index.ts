// send-decline-email: emails a person that their membership application or renewal was declined.
// Only the Membership Chair or the Superuser can call it, and it only sends for a request that has
// already been declined, to the email address on that request, once. The message wording and the
// optional reason (saved when the request was declined) come from the database, not from the caller.
// Sends through the guild Gmail account using the secrets GMAIL_USER and GMAIL_APP_PASSWORD.
// The email names the Membership Chair's email address (looked up from the member list; left out if no
// one holds the Membership Chair role) and, when a payment had been marked received, says it will be refunded.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

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

    const { request_id } = await req.json();
    if (!request_id) return reply({ error: "Missing request." }, 400);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: r, error: re } = await admin.from("membership_requests")
      .select("first_name, email, kind, status, payment_status, decline_note, decline_emailed_at").eq("id", request_id).single();
    if (re || !r) return reply({ error: "Request not found." }, 404);
    if (r.status !== "declined") return reply({ error: "That request has not been declined." }, 409);
    if (r.decline_emailed_at) return reply({ error: "An email was already sent for that request." }, 409);

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);
    // the Membership Chair's email address(es), from the member list
    const { data: chairs } = await admin.from("member_roles").select("members(email)").eq("role_key", "membership_chair");
    const emails = (chairs ?? [])
      .map((c: { members: { email: string } | { email: string }[] | null }) => Array.isArray(c.members) ? c.members[0]?.email : c.members?.email)
      .filter((e: string | undefined): e is string => !!e);
    const contact = emails.join(" or ");

    const what = r.kind === "renewal" ? "membership renewal" : "membership application";
    const reason = (r.decline_note ?? "").trim();
    const lines = [
      `Hello ${r.first_name},`,
      "",
      `Thank you for your interest in the Quilter's Guild of Parker County. We are sorry to let you know that your ${what} has been declined.`,
    ];
    if (reason) lines.push("", `A note from the Membership Chair: ${reason}`);
    if (r.payment_status === "received") lines.push("", "If you paid dues with this request, your payment will be refunded.");
    lines.push("", contact
      ? `If you would like more information, please contact the Membership Chair at ${contact}.`
      : "If you would like more information, please contact the Membership Chair.");
    lines.push("", "Membership Chair", "Quilter's Guild of Parker County");
    const text = lines.join("\n");
    const html = lines.map((l) => (l === "" ? "<br>" : `<p style="margin:0 0 8px">${esc(l)}</p>`)).join("");

    const transport = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    await transport.sendMail({
      from: `"Quilter's Guild of Parker County" <${user}>`,
      to: r.email,
      subject: "Your Quilter's Guild of Parker County membership request",
      text, html,
    });

    await admin.from("membership_requests").update({ decline_emailed_at: new Date().toISOString() }).eq("id", request_id);
    return reply({ ok: true, email: r.email });
  } catch (e) {
    return reply({ error: "The email could not be sent: " + String((e as Error)?.message ?? e) }, 500);
  }
});

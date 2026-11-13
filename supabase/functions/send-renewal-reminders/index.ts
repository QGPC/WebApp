// send-renewal-reminders: emails a renewal reminder to members who have not renewed yet.
// Only the Membership Chair or the Superuser can call it, and only while the Renew Membership switch is on.
// Who gets one: members who are Active or in the grace period and are paid through only the year before the
// renewal target year (the same list as "Not yet renewed" on the Membership Chair page), minus anyone who
// already has a renewal request waiting and anyone reminded in the last 7 days.
// Calls: { dry_run: true } returns the counts and sends nothing. { batch: 20, exclude: [ids] } sends up to
// `batch` emails and returns how many are still left, so the page can call again until nothing is left.
// Sends through the guild Gmail account using the secrets GMAIL_USER and GMAIL_APP_PASSWORD.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const SITE = Deno.env.get("SITE_URL") ?? "https://qgpc.github.io/WebApp/";
const RECENT_DAYS = 7;
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
    if (!(su.data === true || mc.data === true)) return reply({ error: "Only the Membership Chair or the Superuser can send renewal reminders." }, 403);

    const body = await req.json().catch(() => ({}));
    const dry = body?.dry_run === true;
    const batch = Math.max(1, Math.min(Number(body?.batch) || 20, 40));
    const exclude: string[] = Array.isArray(body?.exclude) ? body.exclude.map(String) : [];

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: cfg } = await admin.from("site_config").select("*").limit(1).single();
    if (!cfg?.renewals_open) return reply({ error: "The Renew Membership button is off. Turn it on (Membership Page Admin) before sending reminders, so members can actually renew." }, 409);

    // the year being renewed for: same rule as the Membership Chair page
    const now = new Date(), yr = now.getFullYear();
    const target = yr + (now > new Date(yr, 2, 31, 23, 59, 59) ? 1 : 0);

    const { data: due, error: de } = await admin.from("members_with_status")
      .select("id, first_name, email, membership_type, paid_through_year, status")
      .eq("paid_through_year", target - 1).in("status", ["active", "grace"]).limit(2000);
    if (de) return reply({ error: "Could not read the member list." }, 500);

    const { data: pend } = await admin.from("membership_requests").select("member_id")
      .eq("kind", "renewal").in("status", ["new", "paid"]);
    const pending = new Set((pend ?? []).map((x: { member_id: string | null }) => x.member_id).filter(Boolean));
    const since = new Date(now.getTime() - RECENT_DAYS * 86400000).toISOString();
    const { data: rec } = await admin.from("renewal_reminders").select("member_id")
      .eq("target_year", target).gte("sent_at", since);
    const recent = new Set((rec ?? []).map((x: { member_id: string }) => x.member_id));
    const skip = new Set(exclude);

    let skippedPending = 0, skippedRecent = 0, noEmail = 0;
    const todo = (due ?? []).filter((m: { id: string; email: string | null }) => {
      if (!m.email) { noEmail++; return false; }
      if (pending.has(m.id)) { skippedPending++; return false; }
      if (recent.has(m.id)) { skippedRecent++; return false; }
      if (skip.has(m.id)) return false;
      return true;
    });

    if (dry) {
      return reply({ ok: true, dry_run: true, target, not_renewed: (due ?? []).length, to_send: todo.length,
        skipped_waiting: skippedPending, skipped_recent: skippedRecent, no_email: noEmail, recent_days: RECENT_DAYS });
    }

    const user = Deno.env.get("GMAIL_USER"), pass = Deno.env.get("GMAIL_APP_PASSWORD");
    if (!user || !pass) return reply({ error: "Email sending is not set up yet (missing GMAIL_USER or GMAIL_APP_PASSWORD)." }, 500);

    // the Membership Chair's email address(es), from the member list
    const { data: chairs } = await admin.from("member_roles").select("members(email)").eq("role_key", "membership_chair");
    const emails = (chairs ?? [])
      .map((c: { members: { email: string } | { email: string }[] | null }) => Array.isArray(c.members) ? c.members[0]?.email : c.members?.email)
      .filter((e: string | undefined): e is string => !!e);
    const contact = emails.join(" or ");
    const me = await caller.rpc("current_member_id");

    const transport = nodemailer.createTransport({ host: "smtp.gmail.com", port: 465, secure: true, auth: { user, pass } });
    const slice = todo.slice(0, batch);
    let sent = 0;
    const failed: { id: string; email: string; error: string }[] = [];

    for (const m of slice as { id: string; first_name: string; email: string; membership_type: string; paid_through_year: number }[]) {
      const dues = cfg["renew_dues_" + String(m.membership_type).toLowerCase()];
      const duesLine = m.membership_type === "Exempt"
        ? "Exempt members renew with no payment."
        : (dues !== undefined && dues !== null ? `Renewal dues for a ${m.membership_type} membership are $${Number(dues).toFixed(2)}.` : "");
      const lines = [
        `Hello ${m.first_name},`,
        "",
        `This is a friendly reminder that your Quilter's Guild of Parker County membership ran through December 31, ${m.paid_through_year}, and renewals for ${target} are now open.`,
        "",
        `To keep your membership, please renew by March 31, ${target}. After that date, memberships that have not been renewed are marked Inactive.`,
        "",
        `To renew, sign in at ${SITE} and choose Renew Membership on your home page.${duesLine ? " " + duesLine : ""}`,
        "",
        contact
          ? `If you have trouble signing in (the sign-in card has a "Forgot password?" link) or have a question, please contact the Membership Chair at ${contact}.`
          : `If you have trouble signing in (the sign-in card has a "Forgot password?" link) or have a question, please contact the Membership Chair.`,
        "",
        "If you have already renewed, thank you, and you can ignore this message.",
        "",
        "Membership Chair",
        "Quilter's Guild of Parker County",
      ];
      try {
        await transport.sendMail({
          from: `"Quilter's Guild of Parker County" <${user}>`,
          to: m.email,
          subject: `Time to renew your Quilter's Guild of Parker County membership for ${target}`,
          text: lines.join("\n"),
          html: lines.map((l) => (l === "" ? "<br>" : `<p style="margin:0 0 8px">${esc(l)}</p>`)).join(""),
        });
        await admin.from("renewal_reminders").insert({ member_id: m.id, target_year: target, sent_by: me.data ?? null });
        sent++;
      } catch (e) {
        failed.push({ id: m.id, email: m.email, error: String((e as Error)?.message ?? e) });
      }
    }

    return reply({ ok: true, target, sent, failed, remaining: todo.length - slice.length });
  } catch (e) {
    return reply({ error: "The reminders could not be sent: " + String((e as Error)?.message ?? e) }, 500);
  }
});

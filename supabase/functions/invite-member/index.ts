// invite-member: emails a newly approved member their sign-in (password setup) link.
// Only the Membership Chair or the Superuser can call it. Supabase sends the email
// through the guild Gmail account set up under Authentication > SMTP Settings.
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = Deno.env.get("SITE_URL") ?? "https://qgpc.github.io/WebApp/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

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
    const { data: m, error: me } = await admin.from("members").select("email, first_name").eq("id", member_id).single();
    if (me || !m?.email) return reply({ error: "Member not found." }, 404);

    const { error } = await admin.auth.admin.inviteUserByEmail(m.email, { redirectTo: SITE + "set-password.html" });
    if (error) {
      const already = /already|registered|exists/i.test(error.message);
      return reply({ error: already ? "That person already has a website account. Ask them to use Forgot password on the sign-in page." : error.message }, already ? 409 : 500);
    }
    return reply({ ok: true, email: m.email });
  } catch (e) {
    return reply({ error: String(e?.message ?? e) }, 500);
  }
});

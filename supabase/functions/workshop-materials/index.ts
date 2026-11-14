// workshop-materials: gives a non-member their workshop files through the private link in the
// acceptance email. No sign-in. Body: { token }.
// Returns the workshop's title and date and the file list with short-lived (1 hour) download links,
// but only while the registration is accepted. Undoing the accept turns the link off.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json().catch(() => ({}));
    const token = String(body?.token ?? "");
    if (!/^[a-f0-9]{64}$/.test(token)) return reply({ error: "This link is not valid." }, 404);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: reg } = await admin.from("workshop_registrations").select("month_id, status, name").eq("access_token", token).maybeSingle();
    if (!reg) return reply({ error: "This link is not valid." }, 404);
    if (reg.status !== "accepted") return reply({ error: "These files are not open yet. You will have access once your registration is accepted." }, 403);
    const { data: m } = await admin.from("program_months").select("ws_title, ws_date, ws_time, ws_place, prog_place").eq("id", reg.month_id).single();
    const { data: files } = await admin.from("workshop_materials").select("name, path, bytes").eq("month_id", reg.month_id).order("sort_order");
    const out = [];
    for (const f of files ?? []) {
      const { data: s } = await admin.storage.from("workshop-materials").createSignedUrl(f.path, 3600, { download: f.name });
      if (s?.signedUrl) out.push({ name: f.name, bytes: f.bytes, url: s.signedUrl });
    }
    return reply({ name: reg.name, workshop: m, files: out });
  } catch (_e) {
    return reply({ error: "Something went wrong. Please try again." }, 500);
  }
});

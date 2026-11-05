// TaskBridj payments. One Supabase Edge Function, three jobs:
//   POST {action:"init", campaign_id}   -> starts a Paystack payment for the project's budget
//   POST {action:"verify", reference}   -> asks Paystack if a payment really succeeded, then funds the project
//   POST ?action=webhook                -> Paystack tells us a payment succeeded (signature checked)
// The price always comes from the database, never from the browser. A success screen alone never funds a project.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SECRET = Deno.env.get("PAYSTACK_SECRET_KEY") ?? "";
const SITE = (Deno.env.get("SITE_URL") ?? "").replace(/\/$/, "");
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function hmac512(body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function paystackVerify(ref: string) {
  const r = await fetch(`https://api.paystack.co/transaction/verify/${encodeURIComponent(ref)}`, {
    headers: { Authorization: `Bearer ${SECRET}` },
  });
  return await r.json();
}
// Ask Paystack, then let the database decide (it checks amount, currency and duplicates).
async function settle(ref: string): Promise<{ state: string; message?: string }> {
  const v = await paystackVerify(ref);
  if (!v?.status || v?.data?.status !== "success") return { state: "not_paid" };
  const { data, error } = await db.rpc("mark_payment_paid", {
    p_ref: ref, p_amount_kobo: v.data.amount, p_currency: v.data.currency,
  });
  if (error) return { state: "error", message: error.message };
  return { state: String(data) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (!SECRET) return json({ error: "Payments are not set up yet" }, 503);
  const action = new URL(req.url).searchParams.get("action");

  // ---- Paystack webhook (no login; protected by the signature)
  if (action === "webhook") {
    const raw = await req.text();
    const sig = req.headers.get("x-paystack-signature") ?? "";
    if (!safeEqual(sig, await hmac512(raw))) return new Response("bad signature", { status: 401 });
    try {
      const ev = JSON.parse(raw);
      if (ev?.event === "charge.success" && ev?.data?.reference) await settle(String(ev.data.reference));
    } catch (_) { /* ignore malformed events */ }
    return new Response("ok");
  }

  // ---- everything else needs a logged-in business
  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: u } = await db.auth.getUser(token);
  const user = u?.user;
  if (!user) return json({ error: "Please log in" }, 401);
  const { data: prof } = await db.from("profiles").select("role,suspended").eq("id", user.id).single();
  if (!prof || prof.role !== "business" || prof.suspended) return json({ error: "Only active business accounts can pay" }, 403);

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch (_) { return json({ error: "Bad request" }, 400); }

  if (body.action === "init") {
    if (!SITE) return json({ error: "Payments are not set up yet" }, 503);
    const { data: c } = await db.from("campaigns").select("id,business_id,budget,funded,status,title").eq("id", String(body.campaign_id)).single();
    if (!c || c.business_id !== user.id) return json({ error: "Project not found" }, 404);
    if (c.funded) return json({ error: "This project is already funded" }, 400);
    if (c.status === "rejected") return json({ error: "This project was rejected" }, 400);
    const kobo = Math.round(Number(c.budget) * 100);
    if (!(kobo > 0)) return json({ error: "Invalid project amount" }, 400);
    const reference = "TB" + Date.now().toString(36) + crypto.randomUUID().replace(/-/g, "").slice(0, 8);
    const { error: ie } = await db.from("payments").insert({ reference, campaign_id: c.id, business_id: user.id, amount_kobo: kobo });
    if (ie) return json({ error: "Could not start payment" }, 500);
    const r = await fetch("https://api.paystack.co/transaction/initialize", {
      method: "POST",
      headers: { Authorization: `Bearer ${SECRET}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        email: user.email, amount: kobo, currency: "NGN", reference,
        callback_url: `${SITE}/business.html`, metadata: { campaign_id: c.id, title: c.title },
      }),
    });
    const j = await r.json();
    if (!j?.status) return json({ error: j?.message ?? "Could not start payment" }, 502);
    return json({ url: j.data.authorization_url, reference });
  }

  if (body.action === "verify") {
    const ref = String(body.reference ?? "");
    const { data: p } = await db.from("payments").select("reference").eq("reference", ref).eq("business_id", user.id).single();
    if (!p) return json({ error: "Payment not found" }, 404);
    return json(await settle(ref));
  }

  return json({ error: "Unknown action" }, 400);
});

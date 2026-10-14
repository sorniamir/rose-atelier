import { createClient } from "npm:@supabase/supabase-js@2";

function headers() {
  return {
    "Access-Control-Allow-Origin": Deno.env.get("ALLOWED_ORIGIN") ?? "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8",
  };
}

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: headers() });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: headers() });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" });

  const origin = req.headers.get("origin");
  const allowOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "*";
  if (origin && allowOrigin !== "*" && origin !== allowOrigin) {
    return reply(403, { error: "Origin not allowed" });
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return reply(401, { error: "Authentication required." });

  const projectUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
  const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!projectUrl || !publicKey || !secretKey) {
    console.error("Missing required Supabase environment configuration.");
    return reply(500, { error: "Inventory service is not configured." });
  }

  try {
    const token = authHeader.slice("Bearer ".length);
    const userClient = createClient(projectUrl, publicKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: userData, error: authError } = await userClient.auth.getUser(token);
    if (authError || !userData.user) return reply(401, { error: "Session is invalid or expired." });

    const body = await req.json();
    const productId = body?.product_id;
    const delta = body?.quantity_delta;
    const reason = body?.reason;
    const note = body?.note;

    if (typeof productId !== "string"
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(productId)
      || !Number.isInteger(delta) || delta === 0 || Math.abs(delta) > 50000
      || !["restock", "return", "correction"].includes(reason)
      || (note !== undefined && note !== null && (typeof note !== "string" || note.length > 800))) {
      return reply(400, { error: "Invalid inventory adjustment." });
    }

    const serverClient = createClient(projectUrl, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // Never trust editable user metadata for role checks; use the server-controlled table.
    const { data: adminRecord, error: adminError } = await serverClient
      .from("store_admins")
      .select("user_id")
      .eq("user_id", userData.user.id)
      .maybeSingle();
    if (adminError || !adminRecord) return reply(403, { error: "Administrator permission required." });

    const { data: stock, error: adjustmentError } = await serverClient.rpc("adjust_product_inventory", {
      p_product_id: productId,
      p_quantity_delta: delta,
      p_reason: reason,
      p_note: typeof note === "string" ? note.trim() : null,
      p_actor_user_id: userData.user.id,
    });

    if (adjustmentError || typeof stock !== "number") {
      console.error("Inventory adjustment failed:", adjustmentError?.code ?? "unknown");
      return reply(409, { error: "Adjustment failed. Confirm product and stock values." });
    }

    return reply(200, { product_id: productId, stock, message: "Inventory updated and audit entry recorded." });
  } catch (error) {
    console.error("Invalid inventory request:", error instanceof Error ? error.name : "unknown");
    return reply(400, { error: "The inventory request could not be processed." });
  }
});

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = () => {
  const configured = Deno.env.get("ALLOWED_ORIGIN") ?? "*";
  return {
    "Access-Control-Allow-Origin": configured,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Content-Type": "application/json; charset=utf-8",
  };
};

function reply(status: number, body: Record<string, unknown>, headers: Record<string, string>) {
  return new Response(JSON.stringify(body), { status, headers });
}

function requiredText(value: unknown, min: number, max: number): value is string {
  return typeof value === "string" && value.trim().length >= min && value.trim().length <= max;
}

Deno.serve(async (req: Request) => {
  const headers = cors();
  if (req.method === "OPTIONS") return new Response("ok", { headers });
  if (req.method !== "POST") return reply(405, { error: "Method not allowed" }, headers);

  const origin = req.headers.get("origin");
  const allowOrigin = Deno.env.get("ALLOWED_ORIGIN") ?? "*";
  if (origin && allowOrigin !== "*" && origin !== allowOrigin) {
    return reply(403, { error: "Origin not allowed" }, headers);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return reply(401, { error: "Sign in before creating an order." }, headers);
  }

  const projectUrl = Deno.env.get("SUPABASE_URL");
  const publicKey = Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
  const secretKey = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!projectUrl || !publicKey || !secretKey) {
    console.error("Missing required Supabase environment configuration.");
    return reply(500, { error: "Checkout service is not configured." }, headers);
  }

  try {
    const token = authHeader.slice("Bearer ".length);
    const userClient = createClient(projectUrl, publicKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: userResult, error: authError } = await userClient.auth.getUser(token);
    const user = userResult.user;
    if (authError || !user) return reply(401, { error: "Session is invalid or expired." }, headers);

    const body = await req.json();
    if (!requiredText(body?.customer_name, 2, 160)
      || !requiredText(body?.customer_phone, 8, 32)
      || !requiredText(body?.shipping_address, 8, 1200)) {
      return reply(400, { error: "Please provide valid name, phone, and shipping address." }, headers);
    }
    if (body.customer_note !== undefined && body.customer_note !== null
      && (typeof body.customer_note !== "string" || body.customer_note.length > 800)) {
      return reply(400, { error: "Customer note is too long." }, headers);
    }
    if (!Array.isArray(body?.items) || body.items.length < 1 || body.items.length > 20) {
      return reply(400, { error: "An order must contain between 1 and 20 product lines." }, headers);
    }

    const seen = new Set<string>();
    const items = [];
    for (const item of body.items) {
      if (!item || typeof item.product_id !== "string"
        || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(item.product_id)
        || !Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity > 20) {
        return reply(400, { error: "A product line is invalid." }, headers);
      }
      if (seen.has(item.product_id)) {
        return reply(400, { error: "Each product may appear only once in the order." }, headers);
      }
      seen.add(item.product_id);
      items.push({ product_id: item.product_id, quantity: item.quantity });
    }

    const serverClient = createClient(projectUrl, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const currency = (Deno.env.get("STORE_CURRENCY_CODE") ?? "IRR").toUpperCase();
    if (!/^[A-Z]{3}$/.test(currency)) {
      return reply(500, { error: "Store currency is not configured correctly." }, headers);
    }

    // The database reads trusted prices and locks stock rows atomically.
    // Client-supplied prices are never accepted.
    const { data: orderId, error: orderError } = await serverClient.rpc("create_store_order", {
      p_customer_id: user.id,
      p_customer_name: body.customer_name.trim(),
      p_customer_phone: body.customer_phone.trim(),
      p_shipping_address: body.shipping_address.trim(),
      p_customer_note: typeof body.customer_note === "string" ? body.customer_note.trim() : null,
      p_currency_code: currency,
      p_items: items,
    });

    if (orderError || !orderId) {
      console.error("Order creation failed:", orderError?.code ?? "unknown");
      return reply(409, { error: "Order could not be created. Check product availability and try again." }, headers);
    }

    return reply(201, {
      order_id: orderId,
      status: "pending_payment",
      message: "Stock has been reserved temporarily. No payment has been taken yet.",
    }, headers);
  } catch (error) {
    console.error("Invalid checkout request:", error instanceof Error ? error.name : "unknown");
    return reply(400, { error: "The checkout request could not be processed." }, headers);
  }
});

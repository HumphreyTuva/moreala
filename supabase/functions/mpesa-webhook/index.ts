// Supabase Edge Function — M-Pesa Daraja STK Push callback handler.
//
// Deploy: supabase functions deploy mpesa-webhook --no-verify-jwt
// Set this URL as your Daraja "CallBackURL" for the STK push request.
//
// Flow:
//  1. Client calls a separate `mpesa-initiate` function (not included —
//     stub noted at bottom) which fires the STK push and inserts a
//     `payments` row with status='pending' and the CheckoutRequestID.
//  2. Safaricom calls THIS endpoint when the user completes/cancels the
//     prompt on their phone.
//  3. We verify the payload shape, update the matching `payments` row,
//     and — only on success — bump the user's plan_tier / scan credit.
//
// SECURITY: this function uses the SERVICE ROLE key, which bypasses RLS.
// That is intentional and required (this is the only writer allowed to
// touch `payments.status`), but it means this function is the sole
// source of truth for "did the client actually pay." Never trust a
// client-reported success flag.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

// Optional but recommended: Safaricom doesn't sign callbacks by default,
// so if you want extra assurance the caller is legit, put a random
// path segment or shared secret in the CallBackURL you register with
// Daraja and check it here.
const WEBHOOK_SHARED_SECRET = Deno.env.get("MPESA_WEBHOOK_SECRET"); // optional

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  if (WEBHOOK_SHARED_SECRET) {
    const url = new URL(req.url);
    if (url.searchParams.get("secret") !== WEBHOOK_SHARED_SECRET) {
      return new Response("Forbidden", { status: 403 });
    }
  }

  let body: any;
  try {
    body = await req.json();
  } catch {
    return new Response("Bad request", { status: 400 });
  }

  // Daraja STK callback shape:
  // { Body: { stkCallback: { CheckoutRequestID, ResultCode, ResultDesc, CallbackMetadata? } } }
  const callback = body?.Body?.stkCallback;
  if (!callback?.CheckoutRequestID) {
    return new Response("Malformed payload", { status: 400 });
  }

  const { CheckoutRequestID, ResultCode, CallbackMetadata } = callback;

  console.log("Full Daraja callback:", JSON.stringify(callback));
  
  // Find the pending payment row this callback corresponds to.
  const { data: payment, error: findErr } = await supabase
    .from("payments")
    .select("*")
    .eq("checkout_request_id", CheckoutRequestID)
    .single();

  if (findErr || !payment) {
    // Always return 200 to Safaricom even on lookup failure, or they'll
    // retry the callback repeatedly. Log server-side for investigation.
    console.error("No matching payment for CheckoutRequestID", CheckoutRequestID, findErr);
    return new Response("OK", { status: 200 });
  }

  if (ResultCode !== 0) {
    // User cancelled or payment failed on Safaricom's side.
    await supabase
      .from("payments")
      .update({ status: "failed" })
      .eq("id", payment.id);
    return new Response("OK", { status: 200 });
  }

  // Success. Pull the M-Pesa receipt number out of CallbackMetadata.
  const items: any[] = CallbackMetadata?.Item ?? [];
  const receipt = items.find((i) => i.Name === "MpesaReceiptNumber")?.Value;

  if (!receipt) {
    console.error("Success callback missing MpesaReceiptNumber", body);
    return new Response("OK", { status: 200 });
  }

  const { error: updateErr } = await supabase
    .from("payments")
    .update({ status: "success", mpesa_receipt: String(receipt) })
    .eq("id", payment.id);

  if (updateErr) {
    console.error("Failed to update payment", updateErr);
    return new Response("OK", { status: 200 });
  }

  // Apply the entitlement. This is the only place tier upgrades /
  // scan credits get granted — never on the client.
  if (payment.purpose === "scan") {
    await supabase.rpc("increment_scan_credit", { p_user_id: payment.user_id });
  } else if (payment.purpose === "lecturer_monthly" || payment.purpose === "lecturer_semester") {
    await supabase
      .from("users")
      .update({ plan_tier: "lecturer" })
      .eq("id", payment.user_id);
  }

  return new Response("OK", { status: 200 });
});

// NOTE: you still need an `mpesa-initiate` function (client-callable,
// authenticated) that:
//   1. Validates the user's request (which tier/scan they're buying)
//   2. Calls Safaricom's OAuth + STK Push endpoints server-side
//   3. Inserts a `payments` row with status='pending' and the returned
//      CheckoutRequestID
// It's omitted here because it needs your live Daraja consumer
// key/secret and shortcode to test against — wire it up once you have
// sandbox credentials from Safaricom, and I can write the exact
// STK-push call with you at that point.

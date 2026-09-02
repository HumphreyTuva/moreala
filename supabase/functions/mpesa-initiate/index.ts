// Initiates a Safaricom Daraja STK push (the prompt that pops up on
// the student/lecturer's phone asking them to enter their M-Pesa PIN).
// This is the counterpart to mpesa-webhook, which only RECEIVES the
// result — this function is what STARTS the payment.
//
// Deploy: supabase functions deploy mpesa-initiate
//
// REQUIRES real Safaricom Daraja credentials:
//   MPESA_CONSUMER_KEY, MPESA_CONSUMER_SECRET, MPESA_SHORTCODE,
//   MPESA_PASSKEY, MPESA_CALLBACK_URL, MPESA_ENV, MPESA_TRANSACTION_TYPE

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const MPESA_ENV = Deno.env.get("MPESA_ENV") ?? "sandbox";
const BASE_URL =
  MPESA_ENV === "production"
    ? "https://api.safaricom.co.ke"
    : "https://sandbox.safaricom.co.ke";

const CONSUMER_KEY = Deno.env.get("MPESA_CONSUMER_KEY")!;
const CONSUMER_SECRET = Deno.env.get("MPESA_CONSUMER_SECRET")!;
const SHORTCODE = Deno.env.get("MPESA_SHORTCODE")!;
const TILL_NUMBER = Deno.env.get("MPESA_TILL_NUMBER") ?? SHORTCODE;
const PASSKEY = Deno.env.get("MPESA_PASSKEY")!;
const CALLBACK_URL = Deno.env.get("MPESA_CALLBACK_URL")!;
const TRANSACTION_TYPE = Deno.env.get("MPESA_TRANSACTION_TYPE") ?? "CustomerBuyGoodsOnline";

const PRICES: Record<string, number> = {
  scan: 40,
  lecturer_monthly: 500,
  lecturer_semester: 1200,
};

Deno.serve(async (req: Request) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Unauthorized", { status: 401 });

  const supabaseAsCaller = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user: authUser },
  } = await supabaseAsCaller.auth.getUser();
  if (!authUser) return new Response("Unauthorized", { status: 401 });

  const { purpose, phone_number } = await req.json().catch(() => ({}));
  if (!purpose || !PRICES[purpose]) {
    return new Response("Invalid purpose", { status: 400 });
  }
  if (!phone_number || !/^254\d{9}$/.test(phone_number)) {
    return new Response("phone_number must be in 2547XXXXXXXX format", { status: 400 });
  }

  const { data: internalUser } = await supabase
    .from("users")
    .select("id")
    .eq("auth_id", authUser.id)
    .single();
  if (!internalUser) return new Response("User record not found", { status: 404 });

  const amount = PRICES[purpose];

  const authString = btoa(`${CONSUMER_KEY}:${CONSUMER_SECRET}`);
  const tokenRes = await fetch(`${BASE_URL}/oauth/v1/generate?grant_type=client_credentials`, {
    headers: { Authorization: `Basic ${authString}` },
  });
  if (!tokenRes.ok) {
    console.error("Daraja OAuth failed", await tokenRes.text());
    return new Response("Payment provider auth failed", { status: 502 });
  }
  const { access_token } = await tokenRes.json();

  const timestamp = formatDarajaTimestamp(new Date());
  const password = btoa(`${SHORTCODE}${PASSKEY}${timestamp}`);

  const stkRes = await fetch(`${BASE_URL}/mpesa/stkpush/v1/processrequest`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${access_token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      BusinessShortCode: SHORTCODE,
      Password: password,
      Timestamp: timestamp,
      TransactionType: TRANSACTION_TYPE,
      Amount: amount,
      PartyA: phone_number,
      PartyB: TILL_NUMBER,
      PhoneNumber: phone_number,
      CallBackURL: CALLBACK_URL,
      AccountReference: "Moreala",
      TransactionDesc: `Moreala ${purpose}`,
    }),
  });

  const stkData = await stkRes.json();
  if (!stkRes.ok || !stkData.CheckoutRequestID) {
    console.error("STK push failed", stkData);
    return new Response(
      JSON.stringify({ error: stkData.errorMessage ?? "STK push failed" }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }

  await supabase.from("payments").insert({
    user_id: internalUser.id,
    amount,
    purpose,
    checkout_request_id: stkData.CheckoutRequestID,
    status: "pending",
  });

  return new Response(
    JSON.stringify({ checkout_request_id: stkData.CheckoutRequestID }),
    { headers: { "Content-Type": "application/json" } }
  );
});

function formatDarajaTimestamp(date: Date): string {
  const pad = (n: number) => n.toString().padStart(2, "0");
  return (
    date.getFullYear().toString() +
    pad(date.getMonth() + 1) +
    pad(date.getDate()) +
    pad(date.getHours()) +
    pad(date.getMinutes()) +
    pad(date.getSeconds())
  );
}
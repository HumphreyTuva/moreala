// Supabase Edge Function — generates a short-lived signed URL for a
// private Cloudflare R2 object (walkthrough photo, audio note, etc.)
//
// Deploy: supabase functions deploy r2-signed-url
// This one DOES verify the caller's JWT (no --no-verify-jwt flag),
// since it must only hand out URLs to users who own or have class
// access to the underlying model — that check happens via RLS on the
// `photo_points` / `models` lookup below, using the caller's own
// auth token (not the service role), so private scans stay private.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.17";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const r2AccountId = Deno.env.get("R2_ACCOUNT_ID")!;
const r2AccessKeyId = Deno.env.get("R2_ACCESS_KEY_ID")!;
const r2SecretKey = Deno.env.get("R2_SECRET_ACCESS_KEY")!;
const r2Bucket = Deno.env.get("R2_BUCKET_NAME")!;

const SIGNED_URL_TTL_SECONDS = 60 * 10; // 10 minutes — plenty for a fetch+cache

Deno.serve(async (req: Request) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Unauthorized", { status: 401 });

  // Use the CALLER's JWT here (not service role) so RLS on photo_points
  // enforces "you can only get URLs for models you own or belong to."
  const supabase = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });

  const { object_key } = await req.json().catch(() => ({}));
  if (!object_key || typeof object_key !== "string") {
    return new Response("Missing object_key", { status: 400 });
  }

  // Confirm the caller can actually see the photo_point that owns this
  // object_key before signing anything. photo_url_forward/left/right
  // store the R2 object key (not a public URL) precisely so this check
  // is meaningful.
  const { data: point, error } = await supabase
    .from("photo_points")
    .select("id")
    .or(
      `photo_url_forward.eq.${object_key},photo_url_left.eq.${object_key},photo_url_right.eq.${object_key}`
    )
    .maybeSingle();

  if (error || !point) {
    return new Response("Forbidden", { status: 403 });
  }

  const r2 = new AwsClient({
    accessKeyId: r2AccessKeyId,
    secretAccessKey: r2SecretKey,
    service: "s3",
    region: "auto",
  });

  const endpoint = `https://${r2AccountId}.r2.cloudflarestorage.com/${r2Bucket}/${encodeURIComponent(
    object_key
  )}`;

  const signedRequest = await r2.sign(
    new Request(`${endpoint}?X-Amz-Expires=${SIGNED_URL_TTL_SECONDS}`, { method: "GET" }),
    { aws: { signQuery: true } }
  );

  return new Response(JSON.stringify({ url: signedRequest.url }), {
    headers: { "Content-Type": "application/json" },
  });
});

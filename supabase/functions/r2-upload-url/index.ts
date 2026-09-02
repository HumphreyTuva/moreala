// Mirror of r2-signed-url, but for PUT (upload) instead of GET
// (playback). Called by lib/screens/capture_screen.dart right before
// uploading the raw walkthrough video.
//
// Deploy: supabase functions deploy r2-upload-url

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.17";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const r2AccountId = Deno.env.get("R2_ACCOUNT_ID")!;
const r2AccessKeyId = Deno.env.get("R2_ACCESS_KEY_ID")!;
const r2SecretKey = Deno.env.get("R2_SECRET_ACCESS_KEY")!;
const r2Bucket = Deno.env.get("R2_BUCKET_NAME")!;

const SIGNED_URL_TTL_SECONDS = 60 * 30; // raw video uploads can take a while

Deno.serve(async (req: Request) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return new Response("Unauthorized", { status: 401 });

  const supabase = createClient(supabaseUrl, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });

  const { object_key } = await req.json().catch(() => ({}));
  if (!object_key || typeof object_key !== "string") {
    return new Response("Missing object_key", { status: 400 });
  }

  // Accepts two shapes, both scoped by modelId so ownership can be
  // checked before signing:
  //   raw-uploads/<modelId>/<timestamp>.mp4   (legacy video-upload path)
  //   models/<modelId>/<stopIndex>_<direction>.jpg  (stop-and-shoot capture)
  const parts = object_key.split("/");
  const validPrefix = parts[0] === "raw-uploads" || parts[0] === "models";
  if (!validPrefix || !parts[1]) {
    return new Response("Invalid object_key format", { status: 400 });
  }
  const modelId = parts[1];

  const { data: model, error } = await supabase
    .from("models")
    .select("id")
    .eq("id", modelId)
    .maybeSingle();

  if (error || !model) {
    // RLS on `models` (models_select) already restricts this to models
    // the caller owns or has legitimate access to; a miss here means
    // "no access" or "doesn't exist" — both correctly result in 403.
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
    new Request(`${endpoint}?X-Amz-Expires=${SIGNED_URL_TTL_SECONDS}`, { method: "PUT" }),
    { aws: { signQuery: true } }
  );

  return new Response(JSON.stringify({ url: signedRequest.url }), {
    headers: { "Content-Type": "application/json" },
  });
});

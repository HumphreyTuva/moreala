// Called right before a model row is deleted. Lists and deletes every
// object in R2 under that model's prefix (models/<id>/... and
// raw-uploads/<id>/...) so deleting a walkthrough doesn't leave
// orphaned files silently taking up storage forever.
//
// Deploy: supabase functions deploy delete-model-media

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  S3Client,
  ListObjectsV2Command,
  DeleteObjectsCommand,
} from "https://esm.sh/@aws-sdk/client-s3@3.583.0?target=deno";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const r2 = new S3Client({
  region: "auto",
  endpoint: `https://${Deno.env.get("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: Deno.env.get("R2_ACCESS_KEY_ID")!,
    secretAccessKey: Deno.env.get("R2_SECRET_ACCESS_KEY")!,
  },
});
const BUCKET = Deno.env.get("R2_BUCKET_NAME")!;

async function deleteAllUnderPrefix(prefix: string) {
  let continuationToken: string | undefined;
  do {
    const listRes = await r2.send(
      new ListObjectsV2Command({
        Bucket: BUCKET,
        Prefix: prefix,
        ContinuationToken: continuationToken,
      })
    );
    const objects = (listRes.Contents ?? []).map((o) => ({ Key: o.Key! }));
    if (objects.length > 0) {
      await r2.send(
        new DeleteObjectsCommand({
          Bucket: BUCKET,
          Delete: { Objects: objects },
        })
      );
    }
    continuationToken = listRes.IsTruncated ? listRes.NextContinuationToken : undefined;
  } while (continuationToken);
}

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

  const { model_id } = await req.json().catch(() => ({}));
  if (!model_id) return new Response("model_id is required", { status: 400 });

  const { data: internalUser } = await supabase
    .from("users")
    .select("id")
    .eq("auth_id", authUser.id)
    .single();
  if (!internalUser) return new Response("User record not found", { status: 404 });

  const { data: model } = await supabase
    .from("models")
    .select("id, owner_id")
    .eq("id", model_id)
    .single();
  if (!model || model.owner_id !== internalUser.id) {
    return new Response("Forbidden", { status: 403 });
  }

  try {
    await deleteAllUnderPrefix(`models/${model_id}/`);
    await deleteAllUnderPrefix(`raw-uploads/${model_id}/`);
  } catch (e) {
    console.error("R2 cleanup failed:", e);
    // Don't block the actual model deletion over this — an orphaned
    // file is a minor storage cost; failing to delete the model
    // itself over a cleanup hiccup would be worse.
    return new Response(JSON.stringify({ warning: "Media cleanup failed", detail: `${e}` }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
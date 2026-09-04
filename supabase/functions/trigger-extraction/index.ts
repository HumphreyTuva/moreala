// Called by the app right after a raw walkthrough video finishes
// uploading to R2. Verifies the caller actually owns the model, then
// forwards the extraction job to the keyframe-extractor worker
// (deployed separately — see server/keyframe-extractor/README).
//
// Deploy: supabase functions deploy trigger-extraction
//
// REQUIRES:
//   EXTRACTOR_WORKER_URL — the public URL of your deployed worker,
//     e.g. https://your-app.up.railway.app
//   WORKER_SECRET — must match the same secret set on the worker

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(supabaseUrl, serviceRoleKey);

const EXTRACTOR_WORKER_URL = Deno.env.get("EXTRACTOR_WORKER_URL")!;
const WORKER_SECRET = Deno.env.get("WORKER_SECRET")!;

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

  const { model_id, raw_video_object_key } = await req.json().catch(() => ({}));
  if (!model_id || !raw_video_object_key) {
    return new Response("model_id and raw_video_object_key are required", { status: 400 });
  }

  // Confirm the caller actually owns this model before triggering
  // (potentially costly) server-side processing on their behalf.
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

  // Forward to the worker. We don't wait for extraction to finish —
  // the worker responds immediately (202 Accepted) and processes in
  // the background, updating the model's `status` column when done.
  // The app polls that column rather than holding this connection open.
  try {
    const workerRes = await fetch(`${EXTRACTOR_WORKER_URL}/process`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-worker-secret": WORKER_SECRET,
      },
      body: JSON.stringify({ modelId: model_id, rawVideoObjectKey: raw_video_object_key }),
    });

    if (!workerRes.ok) {
      const text = await workerRes.text();
      console.error("Worker rejected the job:", workerRes.status, text);
      return new Response(JSON.stringify({ error: "Worker rejected the job" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }
  } catch (e) {
    console.error("Could not reach extraction worker:", e);
    return new Response(
      JSON.stringify({ error: "Could not reach extraction worker — is it deployed and running?" }),
      { status: 502, headers: { "Content-Type": "application/json" } }
    );
  }

  return new Response(JSON.stringify({ accepted: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
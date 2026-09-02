/**
 * Moreala Keyframe Extraction Worker
 * ==================================
 *
 * This is a standalone Node.js worker — NOT a Supabase Edge Function.
 * Edge Functions run on Deno with no ffmpeg binary and tight execution
 * limits; frame extraction from a multi-minute walkthrough video needs
 * a real process with disk access and no timeout. Run this as:
 *   - A small container on Fly.io / Railway / a DigitalOcean droplet, or
 *   - A Cloud Run job (has a generous execution time limit), triggered
 *     by a queue message when a video finishes uploading.
 *
 * WHAT THIS DOES:
 *   1. Downloads the raw walkthrough video from R2 (uploaded by the
 *      Flutter capture screen — see lib/screens/capture_screen.dart)
 *   2. Extracts frames at a fixed time interval (proxy for "every 1-2
 *      meters" — see NOTE below on why this is a proxy, not the real thing)
 *   3. Converts each frame to WebP at ~150-300KB
 *   4. Uploads frames to R2 under model/{modelId}/{index}_{direction}.webp
 *   5. Inserts photo_points rows with linked_next_id/linked_prev_id
 *      already wired into a simple linear chain
 *   6. Marks the model's status as 'ready'
 *
 * ============================================================
 * IMPORTANT — READ BEFORE USING THIS IN PRODUCTION
 * ============================================================
 * This extracts frames at a fixed TIME interval (e.g. every 2 seconds),
 * not a fixed DISTANCE interval, because distance requires knowing the
 * student's walking speed — which needs either:
 *   (a) phone accelerometer/pedometer data captured alongside the video, or
 *   (b) visual odometry / optical flow analysis of the footage itself.
 * Neither is implemented here. A fixed-time interval is a reasonable
 * starting proxy (a student walking at a natural pace covers roughly
 * consistent distance per second), but it WILL produce uneven spacing
 * if they pause, backtrack, or speed up. This needs real test footage
 * to tune the interval and validate the assumption — that tuning can't
 * be done blind, which is why it's flagged this clearly rather than
 * presented as solved.
 *
 * This also does NOT do the "Center/Forward, Look Left, Look Right"
 * multi-angle capture from a single video — it assumes one forward-
 * facing pass. A true 3-angle capture needs either (a) the student
 * manually doing 3 short pans at each stop, or (b) a 360/wide-angle
 * lens. That UX decision needs to be made with the client before this
 * pipeline is extended to fill photo_url_left/right.
 */

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFile } = require("child_process");
const { promisify } = require("util");
const execFileAsync = promisify(execFile);
const { createClient } = require("@supabase/supabase-js");
const { S3Client, PutObjectCommand, GetObjectCommand } = require("@aws-sdk/client-s3");

const FRAME_INTERVAL_SECONDS = 2; // tune against real footage

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

const r2 = new S3Client({
  region: "auto",
  endpoint: `https://${process.env.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: process.env.R2_ACCESS_KEY_ID,
    secretAccessKey: process.env.R2_SECRET_ACCESS_KEY,
  },
});

/**
 * Entry point. Call this with { modelId, rawVideoObjectKey }.
 * In production, wire this to run when a message lands on your queue
 * (e.g. a Supabase Storage webhook -> Cloud Run job trigger).
 */
async function processWalkthroughVideo({ modelId, rawVideoObjectKey }) {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "moreala-"));
  const localVideoPath = path.join(workDir, "input.mp4");
  const framesDir = path.join(workDir, "frames");
  fs.mkdirSync(framesDir);

  try {
    await downloadFromR2(rawVideoObjectKey, localVideoPath);
    const framePaths = await extractFrames(localVideoPath, framesDir);

    if (framePaths.length === 0) {
      throw new Error("No frames extracted — video may be corrupt or too short");
    }

    const photoPointRows = [];
    for (let i = 0; i < framePaths.length; i++) {
      const objectKey = `models/${modelId}/${i}_forward.webp`;
      await uploadToR2(framePaths[i], objectKey);
      photoPointRows.push({
        model_id: modelId,
        photo_url_forward: objectKey,
        order_index: i,
      });
    }

    // Insert in order, then wire up linked_next_id/linked_prev_id as a
    // simple linear chain. (A real capture session might branch — e.g.
    // a room with two doorways — but that requires the student to mark
    // branch points during capture, which isn't built yet either.)
    const { data: inserted, error: insertErr } = await supabase
      .from("photo_points")
      .insert(photoPointRows)
      .select()
      .order("order_index");

    if (insertErr) throw insertErr;

    for (let i = 0; i < inserted.length; i++) {
      const updates = {};
      if (i > 0) updates.linked_prev_id = inserted[i - 1].id;
      if (i < inserted.length - 1) updates.linked_next_id = inserted[i + 1].id;
      if (Object.keys(updates).length > 0) {
        await supabase.from("photo_points").update(updates).eq("id", inserted[i].id);
      }
    }

    await supabase.from("models").update({ status: "ready" }).eq("id", modelId);
    console.log(`Model ${modelId}: ${inserted.length} photo_points created.`);
  } catch (err) {
    console.error(`Model ${modelId} processing failed:`, err);
    await supabase.from("models").update({ status: "failed" }).eq("id", modelId);
    throw err;
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
}

async function downloadFromR2(objectKey, destPath) {
  const command = new GetObjectCommand({
    Bucket: process.env.R2_BUCKET_NAME,
    Key: objectKey,
  });
  const response = await r2.send(command);
  const writeStream = fs.createWriteStream(destPath);
  await new Promise((resolve, reject) => {
    response.Body.pipe(writeStream).on("finish", resolve).on("error", reject);
  });
}

async function uploadToR2(localPath, objectKey) {
  const fileBuffer = fs.readFileSync(localPath);
  await r2.send(
    new PutObjectCommand({
      Bucket: process.env.R2_BUCKET_NAME,
      Key: objectKey,
      Body: fileBuffer,
      ContentType: "image/webp",
    })
  );
}

/**
 * Uses ffmpeg (must be installed on the host — e.g. the official
 * ffmpeg apt package in your Dockerfile) to pull one frame every
 * FRAME_INTERVAL_SECONDS and convert straight to WebP.
 */
async function extractFrames(videoPath, outDir) {
  const pattern = path.join(outDir, "frame_%04d.webp");
  const fps = (1 / FRAME_INTERVAL_SECONDS).toFixed(4);

  await execFileAsync("ffmpeg", [
    "-i", videoPath,
    "-vf", `fps=${fps},scale=1280:-1`,
    "-q:v", "75",
    pattern,
  ]);

  const files = fs
    .readdirSync(outDir)
    .filter((f) => f.endsWith(".webp"))
    .sort();
  return files.map((f) => path.join(outDir, f));
}

module.exports = { processWalkthroughVideo };

// Minimal CLI entry point for manual testing:
//   node index.js <modelId> <rawVideoObjectKey>
if (require.main === module) {
  const [modelId, rawVideoObjectKey] = process.argv.slice(2);
  if (!modelId || !rawVideoObjectKey) {
    console.error("Usage: node index.js <modelId> <rawVideoObjectKey>");
    process.exit(1);
  }
  processWalkthroughVideo({ modelId, rawVideoObjectKey })
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
}

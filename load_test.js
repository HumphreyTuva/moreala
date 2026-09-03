// Moreala concurrency load test
// ============================================================
// Simulates N students simultaneously loading a shared walkthrough:
// reading its photo_points (a plain PostgREST call) and getting a
// signed R2 URL for one photo (the r2-signed-url edge function).
// This mirrors exactly what the spec's concurrency section cares
// about — no Realtime subscriptions involved, matching the app's
// actual behavior.
//
// USAGE:
//   1. Fill in the CONFIG values below.
//   2. Run: node load_test.js
//
// Needs Node.js 18 or newer (built-in fetch). Check with: node --version

const CONFIG = {
  SUPABASE_URL: "https://rbeocswjkpzmnvffzegb.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJiZW9jc3dqa3B6bW52ZmZ6ZWdiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcyMTI3MDMsImV4cCI6MjEwMjc4ODcwM30.Usseqj4rA7N1bot6YIXaat47ZY5mbjJB2hPSecVamoo",

  TEST_EMAIL: "humphreytuva2001@gmail.com",
  TEST_PASSWORD: "H477522t",  // fill in locally, don't send it to me

  MODEL_ID: "ae859da9-4a37-480c-9ada-140bd938b735",
  OBJECT_KEY: "models/ae859da9-4a37-480c-9ada-140bd938b735/0_forward.jpg",

  CONCURRENT_STUDENTS: 200,
};

async function signIn() {
  const res = await fetch(`${CONFIG.SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: CONFIG.SUPABASE_ANON_KEY,
    },
    body: JSON.stringify({ email: CONFIG.TEST_EMAIL, password: CONFIG.TEST_PASSWORD }),
  });
  const data = await res.json();
  if (!data.access_token) {
    throw new Error(`Sign-in failed: ${JSON.stringify(data)}`);
  }
  return data.access_token;
}

async function simulateOneStudent(token) {
  const start = Date.now();
  const results = { photoPointsMs: null, signedUrlMs: null, error: null };

  try {
    // 1. Read photo_points — plain PostgREST call, exactly what
    // WalkthroughScreen does when it opens.
    const t1 = Date.now();
    const ppRes = await fetch(
      `${CONFIG.SUPABASE_URL}/rest/v1/photo_points?model_id=eq.${CONFIG.MODEL_ID}&select=*`,
      {
        headers: {
          apikey: CONFIG.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${token}`,
        },
      }
    );
    if (!ppRes.ok) throw new Error(`photo_points read failed: HTTP ${ppRes.status}`);
    await ppRes.json();
    results.photoPointsMs = Date.now() - t1;

    // 2. Get a signed R2 URL — the edge function call that happens
    // every time a photo loads.
    const t2 = Date.now();
    const signedRes = await fetch(`${CONFIG.SUPABASE_URL}/functions/v1/r2-signed-url`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: CONFIG.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ object_key: CONFIG.OBJECT_KEY }),
    });
    if (!signedRes.ok) throw new Error(`r2-signed-url failed: HTTP ${signedRes.status}`);
    await signedRes.json();
    results.signedUrlMs = Date.now() - t2;
  } catch (e) {
    results.error = e.message;
  }

  results.totalMs = Date.now() - start;
  return results;
}

async function main() {
  console.log(`Signing in as ${CONFIG.TEST_EMAIL}...`);
  const token = await signIn();
  console.log("Signed in. Launching", CONFIG.CONCURRENT_STUDENTS, "simulated students...\n");

  const wallClockStart = Date.now();
  const promises = Array.from({ length: CONFIG.CONCURRENT_STUDENTS }, () =>
    simulateOneStudent(token)
  );
  const results = await Promise.all(promises);
  const wallClockMs = Date.now() - wallClockStart;

  const successes = results.filter((r) => !r.error);
  const failures = results.filter((r) => r.error);

  const avg = (arr) => (arr.length ? arr.reduce((a, b) => a + b, 0) / arr.length : 0);

  console.log("=".repeat(50));
  console.log("RESULTS");
  console.log("=".repeat(50));
  console.log(`Total students simulated: ${CONFIG.CONCURRENT_STUDENTS}`);
  console.log(`Succeeded: ${successes.length}`);
  console.log(`Failed: ${failures.length}`);
  console.log(`Total wall-clock time for all ${CONFIG.CONCURRENT_STUDENTS} concurrent requests: ${wallClockMs}ms`);
  console.log(`Average photo_points read latency: ${avg(successes.map((r) => r.photoPointsMs)).toFixed(0)}ms`);
  console.log(`Average signed-URL latency: ${avg(successes.map((r) => r.signedUrlMs)).toFixed(0)}ms`);
  console.log(`Average total per-student time: ${avg(successes.map((r) => r.totalMs)).toFixed(0)}ms`);

  if (failures.length > 0) {
    console.log("\nSample failure reasons:");
    const uniqueErrors = [...new Set(failures.map((f) => f.error))];
    uniqueErrors.slice(0, 5).forEach((e) => console.log(`  - ${e}`));
  }
  console.log("=".repeat(50));
}

main().catch((e) => {
  console.error("Load test crashed:", e);
  process.exit(1);
});
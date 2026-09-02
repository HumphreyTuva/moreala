# Moreala — Phase 1 Build

## Capture design change (read this first)

The walkthrough capture flow now works by **stop-and-shoot photos, not
continuous video**. At each spot, the student taps "Add Stop" and the
app walks them through three photos: Forward, then (after turning)
Left, then Right. Each stop uploads immediately and links itself to
the previous one — the node graph is built live as they walk, no
server-side processing step required.

This replaced an earlier continuous-video + server-side-ffmpeg design.
That approach had two real problems: it needed a distance estimate to
know where to cut frames (which needs phone sensor fusion or visual
odometry — nontrivial), and it never actually captured Left/Right
images, only a single forward-facing video. Stop-and-shoot solves both
by having the student explicitly stand at each spot and capture all
three angles on purpose. It's this direct trade: slightly slower to
record (a few seconds per stop instead of one continuous walk), for
correctness and simplicity.

The old video pipeline is still in the project under
`server/keyframe-extractor/` in case you want a "fast continuous
capture" mode later — but it is **not** part of the primary flow and
doesn't need to be deployed to test the app.

## What to test

1. **`lib/screens/capture_screen.dart`** — this is the main thing to
   put on a real device:
   - Does the Forward → Left → Right prompt sequence feel natural?
   - Are the thumbnails in the top-right a useful confirmation, or
     is there a need for a "retake" button before moving to the next
     angle? (Currently there's no retake — tapping capture always
     commits. Flag this if you want one added; it's a small addition.)
   - Photo quality/size on a real device — `ResolutionPreset.high` was
     chosen as a balance; the spec's 150-300KB WebP target isn't hit
     yet (see below).
   - Does upload-per-stop feel too slow on a real connection? Right
     now each of the 3 photos uploads sequentially before the next
     stop can start.

2. **`lib/screens/walkthrough_screen.dart`** — once a few stops exist,
   does Forward/Back/Left/Right navigation between them feel right?

## Known gaps to fix once you've tested

- **No image compression yet.** Photos upload as full-size JPEG from
  the camera, not the WebP-at-150-300KB the spec calls for. Once
  you've confirmed the capture *flow* feels right, the next step is
  adding client-side resize/compress (the `image` Dart package) before
  upload — didn't want to add that complexity before confirming the
  core flow works for you.
- **No retake button** — see above.
- **No branching support** — stops are a straight line only. A
  hallway with two doorways isn't handled.
- **No offline/poor-connection handling** — if upload fails mid-stop,
  the student has to redo that stop from scratch.

## Backend still needed for the rest of the app

- `supabase/schema.sql` — full schema + RLS, unchanged
- `supabase/functions/r2-upload-url` — now accepts both the legacy
  video path and the new `models/<modelId>/<n>_<direction>.jpg` keys
- `supabase/functions/r2-signed-url` — for playback in
  `walkthrough_screen.dart`
- M-Pesa (`mpesa-initiate`, `mpesa-webhook`) — you're handling this
  integration yourself per our last conversation, so not touched here

## Setup

1. Run `supabase/schema.sql` in your Supabase SQL editor.
2. Create the R2 bucket; deploy `r2-upload-url` and `r2-signed-url`
   with their env vars (see header comments in each `index.ts`).
3. `flutter pub get`, then:
   ```
   flutter run --dart-define=SUPABASE_URL=https://xxx.supabase.co --dart-define=SUPABASE_ANON_KEY=xxx
   ```
4. Sign up, create a `models` row manually (or add a "create
   walkthrough" screen — not built yet, easy addition), then open
   `CaptureScreen` with that model's id to start capturing stops.

Send feedback on the capture flow specifically once you've tried it on
a device — that's the piece most worth iterating on before anything
else gets built on top of it.

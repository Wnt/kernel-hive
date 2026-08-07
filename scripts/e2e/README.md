# E2E browser smoke scripts (run on CT950 osgallery-dev)

Playwright scripts that drive the live gallery SPA
(`https://192.0.2.10:8443`) end-to-end: click a tile card, wait for real
stream pixels, send input, screenshot. Chrome scripts run headed on the VNC
desktop; the Firefox check (`ff-check.mjs`) runs headless.

## Requirements

- Chrome scripts: run on CT950 with `DISPLAY=:1` (the shared headed-browser
  VNC desktop); they launch Chrome themselves with `--no-sandbox
  --ignore-certificate-errors` on that display.
- Firefox script: `npx playwright install firefox` once (bundled build
  firefox-1532 in `~/.cache/ms-playwright`), **and system libavcodec**
  (`apt-get install ffmpeg` → libavcodec60) — Firefox H.264 WebCodecs
  silently reports avc unsupported without it. No DISPLAY needed (headless
  Firefox is validated for WebCodecs + WebTransport).
- `~/e2e/node_modules` (playwright installed there). Node resolves
  `playwright` from the **script's own directory**, so either copy the script
  next to that `node_modules` (`cp scripts/e2e/ff-check.mjs ~/e2e/ && cd ~/e2e
  && node ff-check.mjs`) or symlink `node_modules` into `scripts/e2e/`
  (`ln -s ~/e2e/node_modules scripts/e2e/node_modules`) and run in place.
- Screenshots land in `~/e2e/shots/` (auto-created), timestamped filenames —
  never reuse fixed names (stale root-owned files caused EACCES crashes).

## The stream probe (important)

The SPA's 2D StreamView renders a `<video>` element fed by
`canvas.captureStream()` from an **offscreen** canvas. There is **no stream
`<canvas>` in the document**, so `document.querySelectorAll('canvas')` finds
nothing. Correct probe: find `<video>` with a `srcObject`, check
`readyState >= 2` and `videoWidth > 0`, and for pixel checks `drawImage()`
the video onto a temp canvas, then `getImageData()` and sample.

## Scripts

- `input-smoke-freedos.mjs` — full input smoke on the freedos tile: opens
  the tile, polls the stream video until >5% non-black pixels, clicks the
  video to focus, presses `c` at the RETRO GAMES boot menu (→ FreeCom
  command prompt), types `ver` + Enter, screenshots before/after, exits
  0 on PASS / 1 on FAIL.
- `input-smoke-stats.mjs [Tile]` — opens a tile (default FreeDOS), opens the
  Stats HUD (Stats button, falling back to Ctrl+n), dumps page innerText +
  browser console + a stream-video probe, screenshots.
- `tile-diag.mjs [Tile…]` — per-tile diagnostics loop (default FreeDOS):
  console/pageerror/`/signal/` network log, stream-video probe, screenshot
  per tile.
- `capture-aus.mjs [tile] [count]` + `parse-sps-vui.mjs <aus.json>` — capture
  production Annex-B AUs directly over WebTransport, then print the emitted
  SPS VUI/DPB fields (including `numReorderFrames` and
  `maxDecFrameBuffering`) and the exact SPS bytes.
- `direct-stream-proof.mjs <signaling.json> <out-prefix> [hex-scancodes]` —
  catalog-free WebTransport decode, non-black framebuffer, and reliable-key
  proof for a throwaway tile that must not enter the live lineup.
- `decoder-buffer-probe.mjs [Tile] [samples]` — headed Chrome probe that records
  each live `VideoDecoder.decode()` submit-to-output span and whether a later
  chunk was submitted first. A consistent one-frame DPB hold appears as roughly
  one frame of decode latency and `outputsAfterLaterSubmit` near the sample
  count; immediate output stays at the normal codec execution time and normally
  arrives before the next submit.
- `fd-check.mjs` — reference HUD-dump pattern for freedos (Ctrl+n stats
  toggle + body innerText dump).
- `ff-check.mjs [Tile]` — **Firefox** twin of fd-check with a hard verdict:
  headless bundled Firefox opens the gallery, clicks the tile (default
  FreeDOS), then asserts the stream `<video>`: `readyState>=2`,
  `videoWidth>0`, and non-black pixels via drawImage sampling (>50% default;
  `>=1%` floor for text-mode DOS tiles — a known-good Chrome decode of
  FreeDOS measures only ~1% non-black; override `FF_MIN_NONBLACK=<pct>`).
  Prints PASS/FAIL + banner chip + page console errors, screenshots to
  `~/e2e/shots/`, exit 0/1. Knobs: `GALLERY_URL`, `FF_WAIT_MS` (default
  30000). Baseline 2026-07-12 vs the pre-avc deployed bundle: **FAIL with
  "No video · stream stalled"** (video readyState 0) while the same tile
  decodes in Chrome — i.e. the Firefox WebCodecs-annexb bug. Expect PASS
  only after the avc-path client bundle is deployed.

Only click tiles that are actually streaming (check `labctl ls` on the lab
box); parked/placeholder cards have no stream to probe.

## Firefox WebTransport delivery-race harness (2026-07-12 root-cause kit)

Empirical kit that root-caused the "Firefox stalls, Chrome fine" bug. The
decoder was NEVER the problem — Firefox 151 decodes our exact AUs 1-in-1-out
in every mode (annexb AND avcC+AVCC). The bug: Firefox permanently stops
surfacing server-opened incoming uni-streams to JS when any arrive before the
`incomingUnidirectionalStreams` reader attaches (the server primes the cached
key AU at session accept, so it always races JS). Fix in
`spa/src/three/streamClient.ts`: attach receive readers BEFORE `await
wt.ready` + a Firefox-only poisoned-session watchdog fallback.

- `capture-aus.mjs [tile] [count]` — captures real Annex-B AUs (with the
  9-byte header stripped) from a live tile via a raw in-page WebTransport;
  writes `~/e2e/aus-<tile>.json` (base64 + frameId/isKey/ts). First AU is a
  key AU. Run in the chromium harness (capture only needs any working WT).
  `parse-sps-vui.mjs` consumes this output when the SPS/DPB is under test.
- `ff-decode-matrix.mjs [firefox|chromium] [aus-file] [--quick]` — WebCodecs
  permutation matrix over the captured AUs: {annexb, avcC+AVCC strip SPS/PPS,
  keep SPS/PPS, strip SEI} × {no flush, flush-after-key, flush-each} ×
  {no-preference, prefer-software, omitted}. Reports frames-out per
  permutation. 2026-07-12 result: 30/30 frames in EVERY no-flush permutation
  in BOTH browsers (per-chunk flush legitimately resets the key requirement —
  spec behavior, not a bug).
- `ff-attach-order.mjs [N]` — the decisive reproducer: stall rate vs reader
  attach order. pre-ready 10/10 OK; post-ready 6/10; input-writers-first
  (the old client order) 0/10.
- `ff-fix-verify.mjs [runs] [origin] [browser]` — end-to-end fix gate: loads
  the SPA bundle at `origin`, opens FreeDOS N times, asserts a FLOWING decode
  (≥30 VideoFrames and still growing) per run and counts `ff-session-rebuild`
  telemetry. Post-fix baseline: firefox 10/10 PASS with 0 rebuilds; chromium
  5/5 PASS. To gate an undeployed build, serve `spa/dist` locally with a
  /signal+/clientlog proxy to the box, then pass that origin.

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

## Opening a station — read this before writing a probe

**Never find a tile with `getByText`.** It searches the whole document, so on
the live grid it matches a poster blurb or a nav item long before the card. The
click lands somewhere harmless, the probe waits its 30s and prints "no live
video", and that gets filed as a STATION fault. It is not one: the daemon
journal shows no session was ever created. This cost a full debugging cycle on
win95, on a station that turned out to be fine.

`station-open.mjs` is the one correct way in, and every new probe should use it:

- `openStation(page, base, id)` — the visitor path. Resolves the card by
  **href** (`a.os-card[href$="/os/<id>"]`, which is the card's identity and
  cannot match prose), asserts exactly one match, clicks it, then **asserts the
  SPA actually navigated** before waiting on video. A swallowed click fails
  there, as a probe fault, instead of masquerading as a dead stream later.
  `{direct:true}` deep-links instead, which is what `station-accept-probe.mjs`
  does.
- `probeVideo`, `shotDir()`, `galleryUrl()` — the shared stream probe (see the
  section above), the timestamped shots dir, and the origin.

`GALLERY_URL` must be the lab's **internal** address (`https://<SH_HOST_IP>:8443`
from the gitignored `registry/local.env`). The public gallery host does not
answer on 8443 from inside CT950.

**Always validate a probe on a KNOWN-GOOD station first** (win311 is the usual
control) and confirm `journalctl -u streamhost@<id>` logged a `SESSION_ACCEPTED`
for the run. A probe that fails on a healthy station is a broken probe, and
every reading it produces on a sick one is noise.

- `open-check.mjs <id> [more…]` — did the visitor path OPEN the station, and
  nothing else. No input, no QMP, no guest state touched, so it is safe on a
  live or a sick station. Run it before any probe that claims to measure.

## Measuring the guest cursor on a LIVE station

Two traps, both of which have produced confident wrong numbers:

**The coordinate space is the FRAMEBUFFER, not `videoWidth`.** With ABR active
the same win311 tile decoded at 1024x768 on one run and 768x576 on the next.
A probe that takes its guest resolution from the `<video>` element then aims in
a space nobody else uses: the SPA maps a pointer to a fraction of the content
box and the guest lands it in true framebuffer pixels. That run reported 78-216px
errors on a perfectly healthy station — every one of them exactly the 1024/768
ratio. `cursor-track.mjs` now takes the framebuffer size from the locator's own
screendump, so target and measurement cannot drift apart.

**`measure-golden-cursor.py` is for a GOLDEN checkpoint, not a live station.**
It restores the snapshot first, so its two-frame diff is the cursor and nothing
else. Pointed at a live station with `--no-reset` it folds any on-screen
animation into the same diff — on live win311 it returned a 134x135 bbox (a
cursor is nearer 12x20) because Notepad's caret blinked, and printed the caret's
corner as a coordinate with nothing in the output saying so. It also issues
`cont`, which **resumes a paused guest** — an intervention, not an observation.

- `../dev/locate-live-cursor.py <station>` — the live-safe locator. Three-frame
  differential: `A0 -> A1` with no input identifies whatever is moving BY
  ITSELF, that mask (dilated) is subtracted from the `A1 -> B` nudge diff, and
  the nudge is undone. It never resets and never sends `cont`, opens exactly one
  short-lived QMP client, and says `NO_MATCH` when the surviving bbox is too big
  to be a cursor rather than printing a confident corner of a text caret. Prints
  `AT=<x>,<y> span=WxH FB=WxH`.

- `locate-relay.sh <relay-dir> [locator]` — **CT950 has no ssh route to
  labhost.** `cursor-track.mjs`'s original `execFileSync('ssh', ['lab', …])`
  therefore always threw, was swallowed by its own catch, and reported
  `measured: none` — which reads as "the guest cursor did not move", a claim
  about the station that a transport failure has no standing to make. `/data/vms`
  is bind-mounted into CT950, so this answers a file-drop RPC instead. Start it
  from a session that HAS the door; it forces `--no-reset` and charset-checks the
  station id so it can never restore a live exhibit, and it answers strictly
  serially so at most one QMP client exists at a time:

      ssh lab 'bash .../locate-relay.sh /data/vms/sandbox/<slot>/relay /tmp/llc.py' &
      KH_LOCATE_RELAY=/data/vms/sandbox/<slot>/relay node cursor-track.mjs <id>

  `cursor-track.mjs` distinguishes a locator that could not be REACHED
  (`UNTRUSTWORTHY` — the run measured nothing) from one that honestly said
  `NO_MATCH` (a lost sample on a busy screen). Collapsing the two made a healthy
  control print UNTRUSTWORTHY over a single busy frame, which only trains the
  reader to ignore the word.

**Calibration.** On live win311 a correct run reads ~10px, not 0: the nudge-diff
bbox top-left and the SPA's hotspot mapping differ by a small constant. win95's
warpd agent sets an exact absolute position and reads 0-1px. Compare a station to
its own before/after, not to zero.

## Scripts

- `walkin-shape-probe.mjs` / `walkin-scope-probe.mjs` — the merged grid renders
  the right museum for the right visitor. Take a staged bundle's URL and use its
  `?role=` preview lever (staged/dev builds only — `spa/src/data/session.ts`):
  an invited session must keep all 31 cards, the four nav links and `/os/<id>`
  card targets; a walk-in must get their three machines, a scope switch, no
  fleet-table link, and `/walkin/play/<os>` targets. The scope probe then widens
  to the whole museum and clicks a placard, which must open the exhibit poster
  IN PLACE rather than navigating. Both assert an empty console and, crucially,
  that neither grid is stuck on "Loading the collection…" — the regression they
  exist for. Run from `~/e2e` (see the node_modules note above):
  `node walkin-shape-probe.mjs https://<lab>:8443/staging/<slot>/`

- `rel-tap-wire-probe.mjs` — what the SPA actually PUTS ON THE WIRE when a
  finger glides then taps a **relative-pointer** station. Hooks
  `WritableStreamDefaultWriter.prototype.write` before app code runs, so every
  input record is read as bytes: it reports the RelMotion datagram count and
  each button record's carried point (`null` = the 3-byte coordinate-free form,
  which is what a rel station must send). Point it at the live origin and at a
  `stage.sh` slot for a before/after pair. See
  [`../../docs/lab/INPUT-DEBUGGING.md`](../../docs/lab/INPUT-DEBUGGING.md).
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

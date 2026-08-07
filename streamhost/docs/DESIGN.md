# streamhost — Architecture & Staged Rollout Plan

> [!IMPORTANT]
> **Historical, pre-cutover migration narrative.** This document preserves the
> design, measurements, rollout stages, and then-valid rollback plan as history;
> its neko commands and rollback sections are not current deployment guidance.
> The canonical registry now reports **33 lineup entries: 30 production
> streamhost tiles and 3 showcase posters**. Derive the live number with
> `python3 scripts/tiles-registry.py count` rather than copying a count from this
> narrative.

**Status:** prototype validated end-to-end on real hardware + real LAN. This
document is the design of record for productionizing a from-scratch, per-VM
streaming host in Rust that replaces the neko(Go)+pion+GStreamer stack that
drove the Kernel Hive tiles at design time. *(The plan has since been executed
in full: cutover complete — §9 — and the neko plane is retired.)*

**Scope of the win (headline):** input-to-photon latency drops from **~200 ms
(neko) to ~33 ms (streamhost)** — a **~6× reduction, ~165 ms faster** — measured
with the same single-clock canvas-diff methodology on both stacks. The residual
33 ms is dominated by the QEMU display-refresh floor (~15–30 ms), which neko
shares; essentially the entire 165 ms gap is streaming-stack overhead that
streamhost eliminates (WebRTC + jitter buffer + pion → WebTransport + WebCodecs).

- Compute host: `root@192.0.2.10`, Proxmox on Xeon D-2146NT, 8C/16T, AVX-512,
  **no GPU** (software encode only). QEMU on host is **11.0.0**.
- *Historical (2026-07-06 snapshot):* at design time the then-24 live gallery
  tiles ran as neko Docker containers inside **CT 110** (NAT1TO1
  `192.0.2.12`, one HTTP port per tile e.g. `:8106`, one UDP mux port per
  tile e.g. `53340`). The neko plane has since been retired; use the canonical
  registry count command above for the current fleet.
- Prototype source of truth (local): `~/Claude/Projects/Supermicro/streamhost/`.

---

## 1. Validated architecture

```
  ┌─────────── compute host (per VM/tile) ───────────┐          ┌──── Mac Chrome ────┐
  │                                                   │          │                    │
  │  QEMU  -display dbus,p2p=on   (no X, no GPU)       │          │                    │
  │     │  memfd shm scanout (zero-copy) ── OR ──      │          │                    │
  │     │  v1 copy-path fallback                        │          │                    │
  │     ▼                                              │          │                    │
  │  capture.rs  (zbus p2p, Listener object)           │          │                    │
  │     │  BGRA frame + damage Notify                  │          │                    │
  │     ▼                                              │  QUIC    │                    │
  │  encode.rs   libx264 zerolatency, Annex-B, dmg-gated│─────────▶│ transport (client) │
  │     │  1 AU per uni-stream [frame_id|type|ts]      │  uni-str │   │                │
  │     ▼                                              │          │   ▼                │
  │  transport.rs WebTransport server (wtransport/quinn)│         │ WebCodecs          │
  │     ▲  self-signed ECDSA P-256 cert (<14d)          │◀────────│ VideoDecoder(H264) │
  │     │  input datagrams (move/RTT) + reliable bidi   │ datagram│   │                │
  │     │  (keys/buttons)                               │  +bidi  │   ▼                │
  │  input.rs → QEMU dbus Mouse/Keyboard                │          │ <canvas>           │
  └───────────────────────────────────────────────────┘          └────────────────────┘
```

### 1.1 Capture — `capture.rs` (GO, validated)

QEMU `-display dbus,p2p=on` with a peer-to-peer D-Bus connection handed to us via
QMP. No X server, no GL/EGL (absent on the host — irrelevant), no neko.

Handshake (all validated in SPIKE A and running in the prototype):
1. Connect QMP socket, `qmp_capabilities`.
2. `getfd` passing one end of a `socketpair` via `SCM_RIGHTS`, then
   `add_client protocol=@dbus-display` — this is the p2p D-Bus channel to QEMU.
3. Build a zbus **p2p client** connection on that fd (`main_conn`) — reused for
   input injection too.
4. Export our own object at `/org/qemu/Display1/Listener` implementing:
   - `org.qemu.Display1.Listener` — the base interface. Its `Interfaces`
     property **must advertise `org.qemu.Display1.Listener.Unix.Map`** — this is
     the flag that flips QEMU's `can_share_map=true` and selects the zero-copy
     path. Also carries the v1 copy-path methods (`Scanout`/`Update`/`Disable`)
     as a fallback.
   - `org.qemu.Display1.Listener.Unix.Map` — `ScanoutMap(fd,offset,w,h,stride,
     pixman_format)` mmaps the passed **memfd** (`PROT_READ, MAP_SHARED`) for
     zero-copy framebuffer access; `UpdateMap(x,y,w,h)` bumps a damage
     generation and pulses a `tokio::Notify`.
5. Call `Console_0.RegisterListener(fd)` passing the other socketpair end.

Two capture paths are implemented and both proven 1:1:
- **shm zero-copy** (`shm=true`) — text console; frame read directly from the
  mmap, honoring `stride` (not `w*4`, or frames shear).
- **v1 copy path** (`shm=false`) — X desktop guests; QEMU pushes damaged rects we
  splice into a reconstructed framebuffer.

Damage-gated: the encoder only wakes on `UpdateMap`/`Update`, so idle tiles cost
~nothing. **The listener p2p connection must stay alive for the whole session**
or QEMU stops pushing updates (frozen capture) — held in `Capture._listener`.

### 1.2 Encode — `encode.rs` (GO, validated; one productionization step)

*(Prototype-era ffmpeg-child args below — superseded: the production encoder is
in-process libx264 on a dedicated thread, and the current knobs/defaults live in
[CONFIG.md](CONFIG.md).)*

Raw BGRA → **H.264 Annex-B access units via libx264, CPU-only, zerolatency**:
`-preset ultrafast -tune zerolatency -profile baseline -pix_fmt yuv420p`,
`bframes=0 repeat-headers=1 rc-lookahead=0 sync-lookahead=0 sc_threshold=0`,
`-g 300 -flush_packets 1`, plus the **wall-clock keyframe heartbeat** below.

- `repeat-headers=1` → SPS/PPS precede every IDR so a freshly-joined client can
  start decoding immediately; `bframes=0` → no reordering (kills the Chromium
  HW-decoder post-IDR buffering risk); Annex-B byte-stream is exactly what
  WebCodecs wants.
- Damage-gated + rate-capped: coalesces bursts, never delays isolated events.
- The latest keyframe is retained (`last_key`) and sent first to any new session.
- AU boundaries are found by draining the encoder pipe until quiet **and** a VCL
  NAL is present, with a hard cap so a stalled encoder can't spin.

#### 1.2.1 Keyframe heartbeat + keyframe-on-connect (fixes idle-tile poster fallback)

**Bug (root cause).** Keyframes were counted in *fed frames* (`-g 60`). Because
the pipeline is damage-gated, a STATIC guest (e.g. win98se at its boot modal)
feeds only ~2 fps, so an IDR appeared only every ~30–45 s. The browser client
(`streamClient.feedVideoAU`) **drops every delta AU until it sees a `key` AU**
and only then constructs its `VideoDecoder` — so a tab that connected between
keyframes waited past its negotiation timeout and fell back to the **poster**
("timed out negotiating tile stream"). Worse, priming a *stale* cached `last_key`
alone doesn't fix it: the next broadcast AU is a P-frame that references a frame
the joiner never received, so the decoder can't cleanly continue until a *fresh*
IDR heads the stream.

**Fix — drive keyframes off WALL-CLOCK, not fed-frame count.** ffmpeg args
(validated on-host across idle/busy feed rates, and live on the gallery):

```
-use_wallclock_as_timestamps 1     # each frame's PTS = real arrival time
-vf setpts=PTS-STARTPTS            # rebase to 0 (else t = unix-epoch seconds and
                                   #   the force expr is always-true → every frame IDR)
-fps_mode passthrough              # STRICT 1:1 in/out — NO CFR frame duplication
                                   #   (each output frame == one WebTransport uni-stream)
-force_key_frames expr:gte(t,n_forced*P)   # a forced IDR every P s of WALL time,
                                   #   regardless of fps.  P = keyframe_ms/1000
                                   #   (default now 2500 ms — see CONFIG.md)
```

This makes a fresh, correctly-chained IDR appear at least every `keyframe_ms` of
real time whenever frames are flowing. Crucially the IDR rate is **capped at
1/P**, not 1-per-frame: a busy tile at 21 fps still emits only ~1 IDR/s (measured
`1.1 idr/s @ 21.4 fps` live on freedos), so there is no bandwidth/CPU blow-up —
the bulk of frames stay P / damage-gated. `-g 300` is now just a coarse fallback.

**Keyframe-on-connect.** `EncoderOut::request_keyframe()` (called by
`transport::handle_session` on every new WebTransport session) bumps an atomic the
capture→encode loop polls every 2 ms while watched (50 ms when unwatched); the
loop then feeds a frame immediately (bypassing the damage wait) so the joiner's
fresh IDR lands within ≤ `keyframe_ms` even on a frozen guest. The session is
*also* primed with the freshest cached `last_key` for instant go-live; the
heartbeat's next IDR (≤ `keyframe_ms`) then cleanly re-syncs the P-chain.

**Idle CPU is preserved (heartbeat only costs when watched).** The heartbeat feed
is gated on `tx.receiver_count() > 0`: with **no** client subscribed the loop
reverts to pure damage-gating (no forced-IDR feeds), so an unwatched idle tile
still costs ~0 (measured flat: 1.17 % → 1.27 % on win98se, i.e. within the
pre-existing 2 ms damage-poll noise — the extra IDRs are spent only on the 1–2
tiles actually being viewed). `keyframe_ms` is configurable via `SH_KEYFRAME_MS`
/ `--keyframe-ms` (default now 2500 — see CONFIG.md; clamped 100–10000).

**Prototype vs production delta (only this module):** the prototype drives
libx264 through an `ffmpeg` child process rather than the in-process `x264.h`
FFI. Same encoder, same zerolatency Annex-B output, same CPU cost; the subprocess
adds only a pipe memcpy (~tens of µs at 640×480). **The measured latency includes
this overhead, so the numbers are honest.** Production step = swap this one module
for in-process libx264 FFI (or the `x264` crate); nothing else in the pipeline
changes. Measured encode cost today: **snapshot→AU p50 8.2 ms / p95 10 ms**.

### 1.3 Transport — `transport.rs` (GO-with-caveats, validated)

**WebTransport over QUIC** via `wtransport` (on `quinn`). Chrome connects with
`serverCertificateHashes` pinned to a **self-signed ECDSA P-256** cert.

- **Video out:** one H.264 Annex-B AU per **unidirectional QUIC stream**, 9-byte
  header `[frame_id u32 LE | au_type u8 | capture_ts u32 LE]`. Per-frame streams
  (not datagram fragmentation) give loss isolation and correct ordering without a
  jitter buffer — this is the key design refinement over the original brief.
- **Input in:** mouse-move + RTT ping over **datagrams** (unreliable, coalesced,
  kept < ~200 B so they always fit the path MTU); buttons/keys over a
  client-opened **reliable bidi stream** (length-prefixed).
- Cert validity is capped `now−1h .. now+13d` (Chrome refuses >14d) and the
  SHA-256 hash (base64 + hex) is written to a hash file for the client to fetch.
- `keep_alive_interval(3s)`.

**Caveat (owned in §7):** the <14-day cap forces automated rotation and a
per-session live-hash fetch — no hardcoded pin.

### 1.4 Input — `input.rs` (GO, validated)

Browser input records → QEMU dbus `Mouse`/`Keyboard` on `main_conn`. Compact
little-endian wire format:

| type | meaning | fields |
|---|---|---|
| 1 | mouse move **absolute** | u16 x, u16 y → `SetAbsPosition` |
| 2 | mouse button | u8 button, u8 down → `Press`/`Release` |
| 3 | key | u8 down, u16 QEMU keycode (XT set1) → `Press`/`Release` |
| 4 | mouse move **relative** | i16 dx, i16 dy → `RelMotion` |
| 5 | mouse wheel | i16 dx, i16 dy (dy used) → wheel up/down click (`input.rs`) |
| 6 | touch | u8 kind, u8 slot, u16 x, u16 y → `MultiTouch.SendEvent` |

Absolute positioning (type 1) needs the guest to bind `usb-tablet`
(Windows/ReactOS/evdev-Linux do). Guests whose X only reads relative
`/dev/input/mice` (e.g. TinyCore tinyX) use type 4. Type 4 is now also the
**pointer-lock direct-rel** path: the SPA forwards raw `movementX/Y` deltas 1:1
(no homing/corner-pin), live on the qnx/freedos/msdoswin1 tiles. Proven live in
the prototype: typed `echo hi`, ran commands, the console echoed and executed
them.

### 1.5 Signaling

Deliberately minimal. There is **no neko-style WebSocket control plane**. A
session needs exactly two facts to connect: the **UDP endpoint** (host:port) and
the **current cert hash**. The client fetches the live hash over plain HTTP from
the same host at connect time (the prototype serves it from a hash file). This is
the whole "signaling" surface — it replaces neko's `member/list`,
`signal/provide/answer/candidate`, `screen/resolution`, `system/init`
message soup. Control/host arbitration, clipboard, and resolution reporting move
into small typed control messages on the reliable stream during productionization
(see §3.1 / §7).

---

## 2. Measured prototype latency vs neko

Same methodology on both stacks: **single client clock** (`performance.now()`),
photon detected by canvas/video pixel-diff on the decoded frame — no cross-machine
clock sync needed.

| Metric | **streamhost** | neko baseline (ReactOS tile :8106) |
|---|---|---|
| input-to-photon **median** | **~33 ms** (32/34/34) | **~200 ms** (196–205) |
| mean / p95 | ~34 ms / ~60 ms | ~192 ms / ~220–236 ms |
| hits | 53–54 / 60 | 55 / 55 |
| signal | keystroke → console char echo | click → Start-menu open |

**Δ = ~33 ms vs ~200 ms → ~6× lower, ~165 ms faster.**

Honest decomposition of the 33 ms:
- server capture→AU encode (incl. ffmpeg + drain): **p50 8.2 ms / p95 10 ms**
- network one-way ~1.5 ms (datagram RTT ~3 ms)
- client decode ~1.3 ms + receive→render ~1.4 ms
- residual **~18–20 ms = QEMU display refresh** (`GUI_REFRESH_INTERVAL` ~30 ms →
  ~15 ms avg wait) + input path + guest echo.

That QEMU-refresh floor is **shared by neko** (it captures the same QEMU display),
so the ~165 ms gap is essentially all streaming-stack.

**Throughput / CPU (single tile):** sustained **~63 fps** under continuous
full-screen change (`yes` scrolling), still 1:1 decode; idle ~2 fps (damage-gated).
At ~63 fps, x264/ffmpeg ≈ **30–36 % of one core**; the Rust host (capture +
WebTransport) **< 1 %**. Decode is 1:1 and lossless: **32,500+ AUs received ==
decoded == drawn, `lastError:-`**, on both the shm and copy paths.

**Headroom math for 24 tiles:** 8C/16T. Tiles are rarely all in full-motion at
once (gallery = mostly-idle desktops). Worst case per busy tile ≈ ⅓ core;
even 12 simultaneously-busy tiles ≈ 4 cores. Idle tiles ≈ 0. Comfortable — but
the all-tiles-busy ceiling is an explicit validation gate in §3.3.

---

## 3. Rust workspace layout

Cargo workspace, ~1100 lines today. Source of truth: `streamhost/` in the repo.

*(Snapshot of the prototype tree — pre-dates the encode split: `encode.rs` is
now the `encode/` module (`mod.rs` + `worker.rs` + `handoff.rs`, dedicated
encode thread), and `run/launch_vm951.sh` became `run/launch_tile.sh`.)*

```
streamhost/
├── Cargo.toml                 # [workspace] members = ["streamhost"]
├── docs/DESIGN.md             # this document
├── README.md                  # run/build instructions
├── streamhost/                # the crate
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs            # arg parse; wires capture→encode→transport
│       ├── capture.rs         # QEMU dbus p2p capture (shm + v1 copy fallback)
│       ├── encode.rs          # BGRA → libx264 zerolatency Annex-B AUs
│       ├── transport.rs       # WebTransport server; cert; AU-per-uni-stream
│       └── input.rs           # input records → QEMU dbus Mouse/Keyboard
├── web/
│   └── client.html            # STANDALONE WebCodecs test page + measurement harness
└── run/
    ├── launch_tile.sh         # throwaway validation VM (was launch_vm951.sh)
    └── serve_client.sh        # serve client on localhost (secure context)
```

Build/run on host under a namespaced work dir (never on live tiles or CT112):
`/data/vms/streamhost/build`, VM under `/data/vms/streamhost/run951`.

### Which `streamhost` binary is authoritative (read this before debugging one)

There are several `target/release/streamhost` files on the box and only one of
them is real. `scripts/dev/build-deploy.sh` builds with
`CARGO_TARGET_DIR=/data/vms/streamhost/build/target`, then installs a
content-addressed copy under `/usr/local/lib/streamhost/` and points each tile's
`current` symlink at it — and the symlink is what systemd actually runs.

- **Authoritative build output:** `/data/vms/streamhost/build/target/release/streamhost`
- **What a tile runs:** `/usr/local/lib/streamhost/tiles/<tile>/current`
  (→ `streamhost-<sha>`; `previous` beside it is the rollback target)
- **Stale, renamed to `streamhost.STALE-<date>.DO-NOT-USE` 2026-07-31:**
  `/data/vms/streamhost/target/release/` (an older layout — its `bootrec-tap` IS
  still live, see `docs/guests/ninefront.md`, so the tree stays) and
  `/data/vms/streamhost/build/streamhost/target/release/` (artifacts left inside
  the source subdir). Both predate the `SH_CAPTURE=x11` backend and **panic on
  `SH_INPUT_BACKEND=x11test`**, so running one against the irix tile fails in a
  way that looks like a tile bug.
- Builds under `/data/vms/soltest/**` (e.g. `sh-x11-target`) are experiments, not
  release candidates. Promote by rebuilding through `build-deploy.sh`.

**Target production module split** (adds crates, keeps the same pipeline):
- `streamhost-core` (lib): capture + encode + transport + input, session mgmt.
- `streamhost` (bin): per-VM daemon; CLI/env config; systemd-friendly.
- `x264` in-process FFI replacing the ffmpeg child in `encode.rs`.
- new: `session.rs` (host/control arbitration, clipboard, resolution reporting
  as typed control messages), `metrics.rs` (Prometheus/stats endpoint),
  `cert.rs` (rotation + live-hash HTTP endpoint).

---

## 4. Staged rollout plan

Guiding principle: **the neko stack keeps serving all 24 tiles untouched until
each tile is individually cut over, and every cutover has a one-command
rollback.** No stage modifies the running neko containers or the SPA product
files except the deliberate SPA client swap in Stage 2 (behind a flag) and the
per-tile container swap in Stage 3.

### Stage 0 — Groundwork (prereq, ~0.5 day)
- Install `rustup`/cargo (latest stable) + `libx264-dev` on a **throwaway CT/VM
  (VMID 950+)**, never on live tiles or CT112.
- Freeze the prototype as the baseline; tag the workspace.
- Stand up CI on the host: `cargo build --release`, `cargo clippy`, a smoke test
  that boots VM 951 and asserts ≥1 decoded AU + an input round-trip.

### Stage 1 — Productionize the per-VM streamhost (~3–5 days)
Goal: a single robust daemon suitable to run one-per-tile.
1. **In-process libx264 FFI** replacing the ffmpeg child (`encode.rs`). Assert
   byte-identical AU semantics and re-measure encode latency (expect ≤ current).
2. **Session management:** multiple concurrent viewers per tile; host/control
   arbitration (who has input), view-only viewers, clean teardown. Typed control
   messages on the reliable stream (request/release control, clipboard get/set,
   resolution changed) — replacing the last of neko's WS control plane.
3. **Cert lifecycle:** auto-regenerate (`rcgen`) every ~10 days and on boot;
   serve the live base64 hash over a tiny HTTP endpoint; never pin.
4. **Resolution/mode changes:** the encoder already restarts on geometry change;
   propagate new resolution to clients as a control message (drives letterboxing).
5. **Absolute vs relative pointer per guest:** config flag; default absolute with
   `usb-tablet` where the guest supports it, relative fallback otherwise.
6. **Robustness:** reconnect/backoff if the p2p listener drops; watchdog that
   detects frozen capture (no damage + no scanout) and re-registers; structured
   logging + a `metrics.rs` stats endpoint (fps, AU count, encode p50/p95, viewer
   count, CPU).
7. **Packaging:** systemd unit template `streamhost@.service` parameterized by
   tile (QMP socket path, UDP port, hash-file path), or a thin Docker image if we
   keep tiles containerized (see §6). One instance per tile.
8. **Exit gate:** 24-hour soak on VM 951 + a second throwaway guest with an X
   desktop (copy path) — no leak, no freeze, cert rotates cleanly across a
   boundary, latency unchanged.

### Stage 2 — SPA client: WebTransport+WebCodecs behind the existing control handle (~4–6 days)
The SPA already has a clean seam: the **`NekoControlHandle`** interface
(`spa/src/three/useNekoControl.ts`) and the **`LiveTextureResult`** shape
(`useLiveTexture.ts`) are the only contracts the UI and 3D archetypes depend on.
The plan is to implement a new transport **behind the identical handle** so the UI
"barely changes."

1. **`streamClient.ts`** — a framework-free client: WebTransport connect (fetch
   live hash → `serverCertificateHashes`), read AU-per-uni-stream, feed
   `VideoDecoder(H.264, optimizeForLatency)`, paint to a `<canvas>`; send input
   over datagram + reliable stream. This is essentially the validated
   `web/client.html` refactored into a module.
2. **`useStreamControl.ts`** — implements the **exact `NekoControlHandle`
   surface** on top of `streamClient`:
   - input: `sendMouseMove/Button/Wheel`, `sendKey/sendKeyEvent/typeText`,
     `releaseAllKeys`, `sendTouch` → map to the type 1–4 input records.
   - control plane: `requestControl/releaseControl`, `setClipboard/getClipboard`
     → typed control messages (Stage 1.2).
   - latency lever: `setJitterBufferTargetMs`/`setJitterAuto` become **no-ops or
     a thin decode-depth control** (there is no jitter buffer — this is the whole
     point; keep the methods so the HUD slider still binds, but they gate at most
     a 0–2 frame decode queue).
   - `getStats()` → return `NekoStats` populated from WebTransport/WebCodecs
     (rtt from datagram ping, fps + frame w/h from the decoder, buffered amount
     from streams). Fields that don't apply (WebRTC jitter) report null/derived.
   - audio: `setAudioEnabled/isAudioEnabled` — **open question, see §7** (neko
     carried a WebRTC audio track; streamhost has no audio path yet).
   - `uvToGuest`, `getState`/`onStateChange`, `isConnected/isHost/getResolution`,
     `dispose` — same semantics.
3. **`useStreamTexture.ts`** — mirrors `useNekoTexture.ts`: returns
   `LiveTextureResult` (a `CanvasTexture` over the decode canvas + phase/aspect),
   so **both the 2D grid `StreamView` and the 3D `Exhibit`/`ScreenSurface` path**
   consume it unchanged. `StreamView` already routes by `binding.transport`; add
   a `remote-stream` transport that selects the new hook.
4. **Feature flag:** a per-binding/transport switch (`remote-neko` vs
   `remote-stream`) so a tile can be flipped in the SPA independently, and the SPA
   can run mixed (some tiles neko, some streamhost) during rollout.
   *(Since done: `remote-stream` was this plan's working name — the shipped
   transport enum value is `streamhost` (`spa/src/three/archetypeRegistry.ts`).
   The plan-era opt-in and retired client were removed after full cutover. Later
   `remote-stream` mentions in this historical document are the same plan-era name.)*
5. **Exit gate:** open a streamhost tile in BOTH the 2D StreamView and the 3D
   museum view; verify input, keyboard.lock, Ctrl+Alt+Del, touch OSK, letterbox
   math (`clientToGuest`/`uvToGuest`), stats HUD, fullscreen — parity with neko
   except audio (tracked). Visual + input diff vs the neko tile.

### Stage 3 — Roll out across the 24 tiles, container-by-container, with rollback (~3–5 days)
1. **Per-tile pairing:** each tile is a QEMU guest inside CT 110 today, captured
   by neko in the same container. streamhost attaches to the **same QEMU** via its
   QMP socket — so for a given tile we can run streamhost **alongside** neko
   (different UDP port) before cutover, and A/B them live.
2. **Cutover per tile:**
   - bring up `streamhost@<tile>` pointed at that tile's QMP socket + a new UDP
     port; publish its hash endpoint.
   - flip that tile's SPA binding `transport: remote-neko → remote-stream`.
   - verify (latency probe + input + visual); then stop that tile's neko
     capture/container.
3. **Rollback (one command):** flip the SPA binding back to `remote-neko` and
   restart the tile's neko container. Because neko was never modified and the
   streamhost instance is additive, rollback is instant and lossless. Keep neko
   images/compose files in place until the whole gallery is cut over + soaked.
4. **Order:** start with the tiles most tolerant of regressions and best
   validated (ReactOS :8106 was the A/B baseline), then KVM-safe Linux/X guests
   (copy path), then the fussy retro guests (RISC OS, NeXTSTEP, OS/2, AmigaOS,
   QNX, Haiku, TempleOS, Sailfish, MS-DOS). Do 1, soak 24 h, then batch.
5. **Exit gate:** all 24 on streamhost, neko stack idle-but-present, 48-hour
   gallery soak, aggregate CPU within budget under a scripted "all tiles active"
   stress.

### Stage 4 — Reproduction scripts + deployment (parallel with 1–3, finalized after 3)
- **`run/launch_vm951.sh`** generalized to `run/launch_tile.sh <vmid> <os>` for
  throwaway validation guests (namespaced dirs, unique VMIDs 950+, unique
  sockets/ports — per the concurrent-build-hygiene rule).
- **`deploy/streamhost@.service`** + an install script that, given a tile name,
  drops the unit, points it at the tile's QMP socket + UDP port, and starts it.
- **`deploy/rollout.sh <tile>`** and **`deploy/rollback.sh <tile>`** encoding the
  Stage-3 cutover/rollback exactly (idempotent, one tile at a time).
- **Cert rotation** as a systemd timer or in-daemon (Stage 1.3); hash endpoint
  reachable by the SPA.
- Fold all of this into the existing `MASTER-REPRODUCE.md` /
  `gallery-integrate-all.sh` conventions so the gallery stays reproducible from
  scratch. Add a streamhost manifest row per tile mirroring the neko notes files.
  *(Since done: `gallery-integrate-all.sh` is neko-era, deleted in the 2026-07
  restructure — git history; the per-tile manifest became `tiles-manifest.sh` +
  `bring-up-all.sh`, and `MASTER-REPRODUCE.md` Phase 5 now routes through them.)*
- Build artifact: `cargo build --release` on the host (or a thin container image
  if we keep the containerized model — §6).

### Stage 5 — Decommission neko (only after Stage 3 soak passes; human sign-off)
Remove neko containers/images and the WS control plane from the SPA once every
tile has soaked on streamhost. Keep one archived neko compose + image tag for
emergency rollback for a defined window.

**Rough total effort:** ~2.5–4 focused engineering weeks to full cutover
(Stage 1 ≈ 1 wk, Stage 2 ≈ 1 wk, Stage 3+4 ≈ 0.5–1.5 wk incl. soaks), gated by
the soak windows more than by code.

---

## 5. How the current neko stack stays running until cutover

- Nothing in Stages 0–2 touches CT112. Development happens on throwaway VMID
  950+ guests only.
- streamhost attaches to a tile's **existing QEMU QMP socket** and uses a
  **separate UDP port** — it is purely additive and can run **alongside** neko on
  the same guest for live A/B.
- The SPA runs **mixed**: the `remote-neko` ↔ `remote-stream` per-tile flag means
  un-migrated tiles keep using neko while migrated ones use streamhost.
- Cutover per tile is: start streamhost → flip SPA flag → verify → stop that
  tile's neko. Rollback is: flip flag back → restart neko. neko images/compose
  are retained through the whole rollout + soak (Stage 5 removes them, with
  sign-off).
- The prototype's `web/client.html` remains a **standalone** test page; the SPA's
  neko client and product files are not modified until the deliberate, flagged
  Stage-2 swap.

---

## 6. Deployment-model open choice: container vs host daemon

Today each tile is `neko-qemu:latest` containing QEMU **and** the neko capture in
one container inside CT 110. streamhost separates capture from QEMU (attaches over
QMP), so we can either:
- **(A) keep the container model:** replace neko in the image with the streamhost
  binary; QEMU + streamhost in one container per tile. Minimal disruption to the
  existing gallery topology, NAT1TO1, and reproduce scripts.
- **(B) host/CT systemd daemons:** QEMU per tile + `streamhost@<tile>` units.
  Simpler resource accounting and cert management, but changes the topology.

Recommendation: **(A) for rollout** (lowest risk, reuses NAT1TO1/port conventions,
keeps rollback trivial), revisit (B) as a later cleanup. This is a human decision
— see §7.

---

## 7. Top risks & open questions (need a human decision)

**Risks (with mitigations):**
1. **Chromium-only client.** WebTransport + WebCodecs-H.264 are solid on
   Chrome/Chromium (the gallery target) but weaker on Firefox/Safari. Fine for
   this gallery; a hard blocker if cross-browser is ever required. *Mitigation:
   Chromium-first; keep a webrtc-rs fallback ladder if needed.*
   *(Resolved 2026-07-13: Firefox is now supported on the WebTransport path
   (3-bug fix); a WebRTC fallback was measured ~5× worse and rejected —
   WebTransport stays the only transport.)*
2. **Cert rotation discipline.** <14-day cert cap → must auto-regenerate ~every
   10 days + on boot, and the client MUST fetch the live hash at connect (no
   hardcoded pin). A stale pin = connection refused. *Mitigation: Stage 1.3 hash
   endpoint; monitored.*
3. **H.264 HW-decode post-IDR buffering (Chromium).** Some decoders delay first
   output after an IDR. *Mitigated in the design* by `bframes=0` +
   `repeat-headers` + `optimizeForLatency`; must be re-confirmed on the actual
   client Macs at Stage 2. Fallback: webrtc-rs.
4. **All-tiles-busy CPU ceiling.** Single-tile CPU is comfortable (~⅓ core busy,
   <1 % idle) but 24 simultaneously-busy tiles on a GPU-less 8C/16T host is
   unproven. *Mitigation: Stage 3 stress gate; AVX-512 frequency-offset check —
   pin the colorspace converter to AVX2 and benchmark.*
5. **in-process libx264 FFI (Stage 1.1).** Least-trodden productionization step
   (version-specific `x264_param_t` ABI). *Mitigation: the validated ffmpeg-child
   path is a permanent working fallback; the rest of the pipeline is unchanged.*
6. **wtransport pre-1.0 API churn.** Pin the version; quinn core is stable.

**Open questions requiring a human call:**
- **Audio.** neko carried a WebRTC audio track; several gallery guests have sound
  (the compose files wire `-device AC97`). streamhost has **no audio path today**.
  Decisions: is per-tile audio in scope for cutover, or is muted-during-migration
  acceptable? If in scope, add an Opus-over-QUIC (uni-stream or datagram) path +
  WebAudio playback — roughly +2–3 days and its own validation. **This is the
  single biggest parity gap vs neko.**
- **Deployment model (A vs B, §6).** Container-per-tile (reuse topology) vs
  host/CT systemd daemons. Recommendation is (A) for rollout.
- **Multi-viewer / control-arbitration policy.** neko had implicit hosting +
  member lists. How many concurrent viewers per tile, and who gets input?
  Defines the Stage-1.2 session model.
- **Cert trust model.** Self-signed + per-session hash fetch is validated and
  simplest. Acceptable long-term, or do we want a small internal CA / mkcert-style
  root the client trusts (removes the rotation/hash-fetch dance)?
- **Decommission timing (Stage 5).** How long to retain the archived neko
  image/compose for emergency rollback after full cutover?

---

## 8. Recommended next step

Proceed to **Stage 1 (productionize the per-VM streamhost)** on a throwaway
VMID-950+ guest, starting with the in-process libx264 FFI swap and the session/
cert lifecycle — the two things that turn the validated prototype into a daemon we
can run one-per-tile. Get a human decision on **audio scope** and **deployment
model (§6)** before Stage 2, since audio is the only real parity gap and the
model choice shapes packaging. Architecture and the ~6× latency win are validated;
the remaining work is hardening and rollout mechanics, not research.

---

## 9. Final cutover status (2026-07-06) — gallery fully on streamhost

> **Historical — 2026-07-06 snapshot.** Everything below describes the fleet as
> it stood on cutover day. The current fleet is registry-derived (run
> `python3 scripts/tiles-registry.py count`); the neko plane has been retired
> entirely, VM 900 has
> been deleted, and the riscos/windows11 guardrails were removed 2026-07-08.

Stage 3 rollout is complete. All **24 QEMU/dbus-display tiles now run on streamhost**;
the two non-QEMU tiles (RISC OS, Windows 11) remain on neko as documented permanent
exceptions. This session finished the last two QEMU tiles (postmarketOS, qnx) and
reconciled the SPA signaling registry so every live daemon is also advertised.

### 9.1 The 24-tile status table

Transport legend: **SH** = streamhost (`streamhost@<tile>` daemon + its `qemu-streamhost.sh`
QEMU); **neko** = original neko container (permanent fallback).

| # | osId (SPA) | tile dir | UDP | transport | notes |
|--|--|--|--|--|--|
| 1 | reactos | reactos | 4433 | SH | NT-era: USB tablet, AC97 audio |
| 2 | alpine | alpine | 54081 | SH | |
| 3 | tinycore | tinycore | 54082 | SH | |
| 4 | win311 | win311 | 54090 | SH | PS/2 + SB16 |
| 5 | win95 | win95 | 54091 | SH | PS/2 + SB16 |
| 6 | win98se | win98se | 54092 | SH | PS/2 + SB16 |
| 7 | win2000 | win2000 | 54093 | SH | USB tablet + AC97 |
| 8 | winxp | winxp | 54094 | SH | USB tablet + AC97 |
| 9 | freedos | freedos | 54095 | SH | PS/2 + SB16 |
| 10 | ninefront | ninefront | 54096 | SH | |
| 11 | kolibrios | kolibrios | 54097 | SH | |
| 12 | toaruos | toaruos | 54098 | SH | |
| 13 | helenos | helenos | 54099 | SH | |
| 14 | solaris | solariscde | 54100 | SH | osId≠dir |
| 15 | android | android | 54101 | SH | audio; **reconciled into tiles.json this session** |
| 16 | serenityos | serenityos | 54102 | SH | needs RW qcow2 overlay over RO ext2 root (bring-up-all.sh) |
| 17 | **postmarketos** | postmarketos | 54103 | **SH (NEW)** | OVMF/UEFI, guest-driven **720×1440 portrait**, USB tablet+kbd, intel-hda audio |
| 18 | sailfishos | sailfishos | 54104 | SH | **reconciled into tiles.json this session** |
| 19 | templeos | templeos | 54105 | SH | |
| 20 | haiku | haiku | 54107 | SH | intel-hda audio (A/V both verified live) |
| 21 | os2warp | os2warp | 54108 | SH | **`--accel tcg`** (won't boot on KVM) |
| 22 | aros | amigaos | 54110 | SH | osId≠dir |
| 23 | **qnx** | qnx | 54112 | **SH (daemon started this session)** | LiveCD `-cdrom -boot d`, cirrus, AC97 |
| 24 | msdoswin1 | msdoswin1 | 54113 | SH | |
| — | riscos | (neko only) | — | **neko** | rpcemu — no QEMU, no dbus display → cannot stream. *(Since 07-08: ordinary gallery tile, guardrails removed.)* |
| — | windows11 | (neko-RDP) | — | **neko** | RDP tile (formerly VM900-backed and guardrailed). *(Since: VM 900 deleted; guardrails removed 07-08 — ordinary tile.)* |

**Coherence check passed:** all 24 osIds in `serve/tiles.json` have a listening UDP daemon
(24/24), and each `/signal/<osId>.json` resolves HTTP 200 with a cert-hash matching its live
daemon. RISC OS + Windows 11 are intentionally absent from `tiles.json`, so the SPA's
client-side switch falls back to neko for them.

### 9.2 Permanent neko exceptions

- **RISC OS** — runs under **rpcemu** (ARM/RiscPC emulator), *not* QEMU. streamhost's
  capture/input/audio all bind to QEMU's `-display dbus` D-Bus objects, which rpcemu does
  not expose. There is no dbus display to attach to, so RISC OS **cannot** be a streamhost
  tile. It stays on neko permanently. (Confirmed this session: `osgallery-riscos-1` healthy.)
- **Windows 11** — served as a neko-**RDP** tile from the guardrailed VM 900 family;
  left untouched per project guardrails. Stays on neko. *(Since superseded: VM 900 no
  longer exists on the box and the win11 guardrails were removed 2026-07-08 — the SPA's
  win11 tile is an ordinary `remote-rdp` tile now.)*

### 9.3 Known gap — resize-remap (mid-stream resolution change)

streamhost captures the QEMU dbus scanout at whatever geometry is current. If a guest
**changes resolution mid-stream** (e.g. std-VGA EDID default → the guest's real mode during
boot), the dbus `ScanoutMap` handoff can **freeze the capture** ("mid-boot resize freeze"),
and any already-connected SPA client keeps the old geometry so the absolute-pointer mapping
(0..32767 → pixels) and cursor calibration are off until the client reconnects.

**Mitigation (in effect):** for resolution-changing guests, start/restart the tile's
`streamhost@<tile>` daemon **only after the guest resolution has settled**. postmarketOS is
the canonical case: phosh boots std-VGA then switches to **720×1440 portrait**; the bring-up
recipe launches QEMU, waits for the res to settle at 720×1440 (poll via QMP `screendump`
dimensions), then starts the daemon so the very first captured frame is already 720×1440
(`first frame 720x1440 (shm=false)`, no resize). Steady-state resolution changes (rare in
these frozen museum guests) still require a client reconnect to re-map input. Fixing the
live remap (renegotiate geometry to connected clients without a reconnect) is future work.

### 9.4 Audio status

Path is **verified end-to-end structurally + empirically for live PCM ingress**; final
in-browser A/V-sync is **pending a user check** (the dev Mac cannot reach `:8443` — macOS
Local-Network-Privacy blocks 192.168.x.x from freshly-launched Chrome, and no CLI
WebTransport client was available). Evidence:
- Daemon registers the QEMU D-Bus `AudioOutListener` and logs `audio: registered dbus
  AudioOutListener (Opus @96k)` + `[audio] Init bits=16 signed=true float=false freq=48000
  ch=2` (real negotiated format) on audio tiles (haiku, android, postmarketos, …).
- **Live PCM measured:** driving Haiku to produce sound, the daemon received a continuous
  **~200 KB/s** stream of ~2 KB D-Bus `recvmsg` messages (836 in 8 s) — a near-exact match
  for 48 kHz·2ch·16-bit PCM (192 KB/s) — concurrent with large 219–548 KB video-frame
  recvmsgs. So live guest PCM reaches the Opus encoder alongside video.
- `encode_loop` Opus-encodes every 20 ms frame and `transport.rs` sends `KIND_AUDIO` packets
  per session; real WebTransport sessions have connected (`SESSION_ACCEPTED` in journals).
- What was **not** done: nobody has yet *heard* the decoded Opus in the SPA or confirmed
  A/V lip-sync — that is the one open user-facing verification.

### 9.5 CPU delta (all-streamhost vs neko baseline)

Measured on the 16-core dry-run host at near-idle (per-process utime+stime deltas over 30 s):

| metric | neko baseline | all-streamhost | delta |
|--|--|--|--|
| gallery CPU | **~11.6 cores** | **~5.3 cores** (3.75 daemons + 1.55 tile QEMUs, 24 tiles) | **≈ −54% (~6.3 cores freed)** |

streamhost roughly **halves** the gallery's steady-state CPU. (Daemons are damage-gated to
~0 on idle tiles; the 3.75 figure is a conservative snapshot taken right after several tiles
were woken for verification.)

### 9.6 One-command per-tile rollback (streamhost → neko)

Per `tiles/<tile>/ROLLBACK.md`. To revert a single tile with no effect on the others:

```
systemctl stop streamhost@<tile> \
  && kill "$(cat /data/vms/streamhost/tiles/<tile>/qemu.pid)" 2>/dev/null \
  && pct exec 110 -- docker start osgallery-<tile>-1 \
  && python3 - <<'PY'   # drop <osId> from the SPA signaling registry
import json,sys; p="/data/vms/streamhost/serve/tiles.json"
d=json.load(open(p)); d.pop("<osId>",None); json.dump(d,open(p,"w"),indent=2)
PY
```

Removing the osId from `tiles.json` makes `/signal/<osId>.json` 404, so the SPA's
client-side switch falls back to `remote-neko` for that tile. neko images/compose were never
touched, so the container restart is immediate. Reverse (neko → streamhost) = re-run the
tile's manifest line + `qemu-streamhost.sh` + `systemctl start streamhost@<tile>` + re-add
to `tiles.json`.

### 9.7 Reproducibility (NVMe rebuild)

The **entire streamhost control plane is now in the project repo** and self-consistent:
Rust source (`streamhost/src/*.rs`, verified byte-identical to host build), the tile emitter
`scripts/streamhost-tile.sh` (synced to the live version with `--accel kvm|tcg`), the systemd
unit `deploy/streamhost@.service`, the serve plane in the repo's top-level **`scripts/serve/`**
(the HTTPS+signaling server `osgallery-https-server.py`, the local-CA generator
`gen-local-ca.sh`, the signaling registry `tiles.json` — no longer duplicated in this
streamhost tree; mirrored to `/data/vms/streamhost/serve/` on the host, see
`docs/lab/MASTER-REPRODUCE.md` Phase 5), the
**per-tile manifest `tiles-manifest.sh`** (exact `streamhost-tile.sh` invocations, verified
to re-emit every `tile.env`/`qemu-streamhost.sh` byte-identically), and the ordered
**`bring-up-all.sh`** orchestrator (install unit → emit → launch QEMU + wait QMP → start
daemon → postmarketOS res-settle restart → serenity overlay → tiles.json + CA + server).
Only two things are **external by design** (not in git): the guest disk images/ISOs under
`/data/gallery-guests/` (large binaries; rebuilt via the existing `scripts/build-guests/`),
and the built SPA bundle in the serve webroot (built from `spa/` in this repo). With
those two restored, a from-scratch NVMe rebuild reproduces the full streamhost gallery, with
neko as the documented fallback.

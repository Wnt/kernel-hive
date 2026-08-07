# streamhost

Scratch-built per-VM streaming host in Rust — a from-scratch replacement for
neko(Go)+pion for the Kernel Hive tiles. Production hardening of the validated
stage-0 prototype (video+input, ~33 ms vs neko ~200 ms). This tree now also does
**audio**, **cert rotation + signaling**, **wheel/touch input**, and **per-tile
deploy**.

    QEMU -display dbus,p2p=on,audiodev=snd0   (no X, no GPU — software encode)
      | zbus p2p (one connection, reused for capture + input + audio)
      ├─ capture.rs   shm scanout (zero-copy, stride-honest) + v1 copy fallback + resize remap
      │     -> encode/   in-process libx264 zerolatency Annex-B AUs (damage-gated)
      ├─ audio.rs     QEMU dbus AudioOutListener -> 48k/stereo/s16 -> Opus low-latency
      └─ input.rs     Mouse/Keyboard/MultiTouch inject  <- browser records
                    |
      transport.rs  WebTransport/QUIC:  video=uni-stream kind1 | audio=uni-stream kind2
                    input in = datagrams (move/RTT) + per-type reliable input streams
                    (keys/buttons/wheel/touch — always on; legacy single bidi kept for old clients)
      cert.rs       self-signed P-256 (<13d), rotates ~10d, publishes signaling.json
    browser: WebCodecs VideoDecoder(H264) -> canvas ; AudioDecoder(Opus) -> WebAudio

## Production module map (`streamhost/src/`)
- `main.rs`      — wire config -> capture -> (audio) -> encode -> signaling -> transport.
- `config.rs`    — **per-tile** config (tile, QMP sock, UDP port, pointer, audio, cert
  rotation, signaling paths) from CLI flags **and** `SH_*` env (systemd/compose friendly).
- `clock.rs`     — shared monotonic epoch; video capture ts and audio Opus ts share it (A/V sync).
- `capture.rs`   — QEMU `-display dbus,p2p=on` capture. Zero-copy memfd **ScanoutMap**
  (honors `stride`, not `w*4`), **v1 copy-path fallback** for X desktops, **resize remap**
  (a ScanoutMap re-invocation munmaps, updates geometry, drops stale v1 fb, wakes the encoder).
- `encode/` (`mod.rs`, `worker.rs`, `handoff.rs`) — BGRA -> H.264 Annex-B via in-process
  libx264 (`x264-sys` FFI, zerolatency) on a dedicated encode thread per encoder
  (`worker.rs`), fed through a depth-1 latest-wins handoff (`handoff.rs`). Damage-gated;
  ABR tier / geometry change re-opens the encoder (fresh SPS+PPS+IDR); keyframe retained
  for late joiners. See ../docs/history/ENCODER-INPROCESS-FINDINGS.md for the ffmpeg-child -> FFI migration.
- `abr.rs`       — adaptive-bitrate controller: clients report stats via datagrams (~100 ms);
  the server steps a GLOBAL per-tile tier (one encoder broadcasts to all sessions) on genuine
  network congestion only — sustained loss / RTT growth, never decode-side metrics — with
  persistence, a 25 s dwell, and asymmetric hysteresis against oscillation.
- `audio.rs`     — **NEW.** Registers `org.qemu.Display1.AudioOutListener` on the same p2p
  connection; QEMU pushes guest PCM (`Init`+`Write`); converts to 48 kHz/stereo/i16 (resample +
  up/down-mix fallbacks), slices 20 ms frames, Opus-encodes (LowDelay), broadcasts timestamped packets.
- `input.rs`     — records -> QEMU dbus. type1 abs / type2 button / type3 key / type4 rel /
  **type5 wheel** (wheel-up=btn3/down=btn4) / **type6 touch** (MultiTouch.SendEvent).
- `warpd.rs`     — drives the in-guest warpd pointer agent (over a QEMU hostfwd TCP port, or
  a serial-chardev UNIX socket for legacy guests) when the QEMU absolute tablet can't cover
  the screen (e.g. Solaris 10 caps it at 1024x768); a background task owns the connection
  and reconnects, callers fire M/P/R/B commands into a channel that never blocks input.
- `cert.rs`      — **NEW.** ECDSA P-256 self-signed (now-1h .. now+13d); publishes the bare-hash
  file (back-compat) **and** `signaling.json` atomically.
- `signaling.rs` — **NEW.** Optional dependency-free plain-HTTP endpoint (testing/A-B) serving
  `signaling.json` / `/hash`. Production signaling is served same-origin over HTTPS by the SERVE agent.
- `transport.rs` — WebTransport server. 1-byte **kind** prefix on every uni-stream (1=video,
  2=audio). **Cert rotation loop**: rebinds the same UDP port with a fresh cert every ~10 days.

## Audio — how it works (the biggest new piece)
No host audio stack (PulseAudio/PipeWire) is needed. QEMU is launched with
`-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16` **and**
`-display dbus,p2p=on,audiodev=snd0` (the display must reference the audiodev, or the
`org.qemu.Display1.Audio` object is never exported). streamhost calls
`Audio.RegisterOutListener(fd)` on the existing p2p connection and serves an
`AudioOutListener`; QEMU calls `Init(bits,signed,float,freq,ch,...)` then `Write(pcm)`.
We convert to 48 kHz/stereo/i16 (fast-path when QEMU already gives that — validated live),
frame at 20 ms, Opus-encode (Application::LowDelay), and ship one packet per uni-stream
(kind=2, `[2|seq u32|ts_us u32|opus]`) timestamped on the shared clock for A/V sync. Browser:
`AudioDecoder(opus, 48k, 2ch)` -> `AudioContext` scheduled playback.

## Signaling contract (per tile) — what the SERVE agent serves same-origin over HTTPS
`cert.publish()` writes `signaling.json` atomically on every cert (re)generation:

    { "tile":"reactos", "host":"192.0.2.10", "udpPort":54106,
      "certHashB64":"…", "certHashHex":"…",
      "transport":"webtransport-h264-opus", "pointer":"abs",
      "inputBackend":"dbus-abs", "audio":true,
      "updatedAt":"…Z", "notAfter":"…Z" }

The SPA fetches this same-origin at connect time and passes `{host, udpPort, certHashB64}`
to `new WebTransport(url, {serverCertificateHashes:[{algorithm:'sha-256', value:hash}]})`.
**No hardcoded pin, ever** — the hash changes on every ~10-day rotation.

## Per-tile deploy (current procedure)
Every gallery tile runs this stack. A tile is a directory
`/data/vms/streamhost/tiles/<tile>/` holding `tile.env` (SH_* env for
`streamhost@<tile>.service`), `qemu-streamhost.sh` (the QEMU launcher — dbus
display + audio + input + QMP socket + pidfile), and `ROLLBACK.md`. Those files
are emitted by `scripts/streamhost-tile.sh`; the authoritative per-tile flag
ledger — one exact emit invocation per tile — is **`tiles-manifest.sh`**
(`--install` also drops `deploy/streamhost@.service`). Neither starts anything:
**`bring-up-all.sh`** does the ordered cold boot (install unit → emit all tiles →
per-tile launch QEMU by pidfile, wait for its QMP socket, `systemctl start
streamhost@<tile>` → finally the :8443 HTTPS serve plane from
`/data/vms/streamhost/serve/`, mirrored from the repo's `scripts/serve/`).

Daemon code changes are built with the repo-root
`scripts/dev/build-deploy.sh`. A bare legacy invocation targets only `helenos`;
fleet fan-out requires `--all`, and `--fast` is a build-only incremental profile.
After the one-time supervised systemd migration, releases are immutable
`streamhost-<gitsha>` artifacts selected through per-tile symlinks: use
`--canary <tile>`, framebuffer/stream-verify it, then `--promote`. See
[`deploy/VERSIONED-INSTALL.md`](deploy/VERSIONED-INSTALL.md) for migration,
bounded waves, and instant per-tile rollback. Do not copy the versioned service
template over a running legacy fleet by hand.

On the SPA side the tile's binding uses the `streamhost` transport
(`spa/src/three/archetypeRegistry.ts`) — the committed default for the gallery
tiles. Win11, RISC OS, and macOS are showcase posters. Signaling is served
same-origin at `/signal/<osId>.json`.

## Build (Linux)

Install a Rust toolchain plus the native Debian/Ubuntu dependencies a fresh
reader needs:

```bash
sudo apt-get install libx264-dev libopus-dev libclang-dev pkg-config
# libx264-dev -> x264-sys (in-process H.264 encoder; libclang-dev for its bindgen)
# libopus-dev -> the opus crate
cargo build --release          # in this directory (workspace root)
target/release/streamhost --version   # --help is also side-effect-free
```

On the lab box the tree is mirrored to `/data/vms/streamhost/build/` and built
there with a box-local CARGO_HOME and a shared target cache — don't do that by
hand; use the repo-root `scripts/dev/build-deploy.sh` from the workstation.

## Throwaway validation guest (namespaced, isolated; kill only by pidfile)
    run/launch_tile.sh 952 --audio on --pointer abs      # boots TinyCore, dbus display+audio+tablet
    SH_TILE=smoke952 SH_QMP=/data/vms/streamhost/run952/qmp952.sock SH_PORT=4952 SH_AUDIO=on \
      target/release/streamhost                          # capture+cert+signaling+audio+UDP

## Standalone reference client
`web/client.html` — WebCodecs H.264 + Opus, wheel + touch input, single-clock latency harness.
Serve on localhost (secure context) via `run/serve_client.sh`. The real SPA client is the SERVE
agent's job; this page is the wire-protocol reference + A/B probe.

## Docs
`docs/DESIGN.md` (architecture), `docs/CONFIG.md` (every `SH_*` env knob),
`docs/BRIDGE.md` (emulator-bridge tiles), `docs/IDLE-PAUSE.md` (idle auto-pause:
unwatched guests freeze, resume on visit), `docs/CAPTURE-FASTPOLL.md` (pve-qemu
display fast-poll patch, as deployed), `docs/LATENCY-NOTES.md` +
`../docs/history/ENCODER-INPROCESS-FINDINGS.md` (latency investigation notebooks).

## Notes / invariants
- `InputBackend::DbusAbs` type-1 input needs a guest that binds a tablet
  (virtio-tablet / usb-tablet). Relative-only guests use type 4 through the
  bounded `InputBackend::DbusRel` path. Backend selection is per-tile config.
- Keep the listener p2p connections (video **and** audio) alive for the whole session or QEMU
  stops pushing updates.
- Chromium + Firefox are both supported clients (WebTransport + WebCodecs;
  Firefox since the 2026-07-13 3-bug fix). Safari untested. WebTransport remains
  the default low-latency transport; browsers without `VideoDecoder` use the
  one-service platform WebRTC fallback described in `../docs/WEBRTC-PLATFORM.md`.

# streamhost configuration reference — every `SH_*` knob

*As of 2026-07-16 (unified input backend; post relfix/input-streams removal).*

One streamhost process serves exactly one QEMU tile. Most config-backed knobs are
settable as a CLI flag **or** an `SH_*` env var (systemd/compose friendly); the
flag wins when both are given. Env-only exceptions are identified below.
Positional arg 0 is the QMP socket
(prototype back-compat, same as `SH_QMP`). Source of truth:
`../streamhost/src/config.rs` (parse + clamps) plus the five debug flags read
directly in their modules.

Note: `SH_DBUS_TAP` is **not** a daemon knob — it belongs to the `bootrec-tap`
boot-video capture binary (`../streamhost/src/bin/bootrec-tap.rs`, driven by
`scripts/coldboot/`). Likewise `SH_DBUS_UPDATE_MS`/`SH_DBUS_TRACE` are read by
the patched QEMU, not by streamhost (see CAPTURE-FASTPOLL.md).

## Core / per-tile identity

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_QMP` | positional arg 0 | `/data/vms/streamhost/run951/qmp951.sock` | QMP unix socket of the tile's QEMU (also anchors the rss-guard pidfile lookup) | config, capture |
| `SH_STATION` | `--tile` | `dev951` | Logical tile id; derives default paths under `/data/vms/streamhost/stations/<tile>/` | config |
| `SH_PORT` | `--port` | `4433` | WebTransport/QUIC UDP port for this tile | transport |
| `SH_FPS` | `--fps` | `60` | Capture→encode fps cap (feed spacing, not a pacing clock) | encode |
| `SH_KEYFRAME_MS` | `--keyframe-ms` | `2500` (clamp 100–10000) | Wall-clock IDR heartbeat while watched; joiners are primed from the cached last IDR, so this only bounds datagram-loss recovery | encode |
| `SH_HOST_IP` | `--host-ip` | `192.0.2.10` | Host IPv4 written into `signaling.json` | cert |
| `SH_ADVERTISE_HOST` | `--advertise-host` | = host-ip | Hostname the browser dials (differs from host-ip behind NAT/DNS) | cert |

## Pointer / input

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_INPUT_BACKEND` | `--input-backend` | derived from legacy `SH_POINTER`, otherwise `dbus-abs` | Unified pointer backend: `dbus-abs` (QEMU tablet), `dbus-rel` (bounded/paced QEMU PS/2), `warpd` (frozen in-guest agent), `gallery-hid` (Solaris/QNX-only native sink), `x11test` (XTEST motion + Lua-agent buttons, pairs with `SH_CAPTURE=x11`; the `SH_X11TEST_*` knobs below extend it to absolute motion, XTEST buttons and an XTEST keyboard for any unpatched SDL emulator under Xvfb), or `mamecmd` (every event down the Lua agent's command file, pairs with `SH_CAPTURE=shm` where there is no window to XTEST into) | config, input, realtime_input, x11_input, mame_input |
| `SH_POINTER` | `--pointer` | `abs` | **Legacy parse-only compatibility:** `abs`→`dbus-abs`, `rel`→`dbus-rel`, `warpd`→`warpd` when the unified knob is absent. Old `SH_INPUT_BACKEND=dbus` still combines with `abs`/`rel`; old explicit `warpd`/`gallery-hid` overrides still parse. New station.env files should use `SH_INPUT_BACKEND` | config |
| `SH_CURSOR_OFF_X` | `--cursor-off-x` | `0` | Absolute-client origin calibration X (guest px), applied before either `dbus-abs` injection or the `dbus-rel` PS/2 bridge | input |
| `SH_CURSOR_OFF_Y` | `--cursor-off-y` | `0` | Absolute-client origin calibration Y (guest px), applied before either dbus path | input |
| `SH_CURSOR_SCALE` | `--cursor-scale` | `1.0` | Absolute-client scale applied before the offset and before either dbus path; non-identity `dbus-rel` values calibrate a relative guest's pointer gain | input |
| `SH_WARPD_ADDR` | `--warpd-addr` | `127.0.0.1:7790` | host:port or Unix socket of the frozen in-guest warpd agent, used by backend `warpd` | warpd |
| `SH_WARPD_BUTTONS` | `--warpd-buttons` | `agent` | `qemu` routes mouse BUTTONS through the real QEMU device (true WM semantics on e.g. Win3.11); motion stays on the agent | input |
| `SH_WARPD_WHEEL` | `--warpd-wheel` | `auto` | `agent` or `qemu`; `auto` follows `SH_WARPD_BUTTONS` (OS/2 uses agent wheel with QEMU buttons) | input |
| `SH_WARPD_PACE_MS` | `--warpd-pace-ms` | `8` (max 50) | Min ms between writes to the warpd agent | warpd |
| `SH_WARPD_BUTTON_DELAY_MS` | `--warpd-button-delay-ms` | `0` (max 250) | Hybrid-buttons race guard: hold a qemu-routed button this long after the last warpd motion (slow serial agents) | input |
| `SH_GHID_SOCKET` | — | `<tile dir>/gallery-hid.sock` | QEMU gallery-hid chardev socket; used only by explicit `gallery-hid` | realtime_input |
| `SH_INPUT_BENCH_ADDR` | — | unset | Loopback-only Stage-D measurement ingress; feeds the production router and does not select a backend | realtime_input |
| `SH_LEGACY_KBD` | `--legacy-kbd` | `off` | Pre-1986 keypad-scancode quirk: remap the browser's 0xE0-extended cursor/nav scancodes to bare numeric-keypad codes for guests whose keyboard driver predates the 101-key Enhanced layout (Windows 1.x/2.x); live on msdoswin1 | input |
| `SH_KEY_REMAP` | — | empty | Per-tile key REMAP: comma-separated `from:to` XT set1 wire codes (hex `0x…` or decimal, extended keys in the browser's `0xE0xx` form), rewritten before all other keyboard handling — composes with `SH_LEGACY_KBD` and covers the physical keyboard and the SPA on-screen keyboard alike. For emulated machines missing a key the browser has; live on mpf2 as `0x0e:0xe04b` (the MPF-II matrix has no Backspace — LEFT ARROW is its rubout key) | input |
| `SH_KEY_MIN_HOLD_MS` | — | `0` (off) | Minimum key hold in ms (capped at 250). An emulator samples its input ports once per emulated frame (~16.7 ms at 60 Hz), so a press+release completing inside one frame is never observed and the keystroke is lost — what fast typing produces. Defers the Release, and SERIALIZES key events while on, so out-typing the hold queues rather than drops and two keys cannot interleave into a stuck key. Keyboard sibling of `SH_ABS_PACE_MS`/`SH_WARPD_PACE_MS`; live on mpf2 at `32` (2 frames). For the `x11test` XTEST keyboard the SAME env applies but UNSET means `40` there (an explicit value, `0` included, wins) — see `SH_X11TEST_KEYS` | input, x11_keys |
| `SH_KEY_MIN_GAP_MS` | — | `0` (off) | Minimum GAP in ms between one key's Release and the next key's Press (capped at 250). The hold above makes each key visible for long enough; this makes the SPACE between two keys visible. Sustained typing — the SPA's `typeText` paste path — emits press/release pairs back to back, so the next Press can follow the previous Release by microseconds and a once-per-frame emulator reads one long chord instead of two characters (observed on amstradcpc/cap32: `10 MODE 1` arriving as `ODE 11IN 67 BE`). Only a Press that FOLLOWS a Release waits, so the Shift chord `typeText` synthesizes for uppercase/symbols is never split. Shares the hold's serializing gate: over-typing queues in order, never drops. For the `x11test` XTEST keyboard the SAME env applies but UNSET means `40` there (an explicit value, `0` included, wins) — see `SH_X11TEST_KEYS` | input, x11_keys |
| ~~`SH_INPUT_STREAMS`~~ | ~~`--input-streams`~~ | — | **Removed 2026-07-14**: the per-type input-stream router (Moonlight-style HOL avoidance) is now always on; the knob only ever disabled the server half and desynced from the SPA. The legacy single-bidi loop also always runs for back-compat | transport |

The bounded-relative sender is part of the shared `dbus-rel` path. Absolute
client samples sent to that backend are calibrated first, then differenced
against the prior calibrated target; the default scale/offset are identity, so
existing relative tiles retain their byte-for-byte deltas. The removed
fork binary/drop-ins had no remaining tuning surface: there is no relfix-only
`SH_INPUT_*` knob or deploy path. `SH_INPUT_STREAMS` remains removed; do not add
another per-tile router fork.

## Frame source (capture backend)

`SH_CAPTURE` selects where frames come from. The default is `qemu` and every
production QEMU tile leaves it alone — the other two backends exist for the
IRIX/MAME tile (issue #20), whose emulator kernel-panics under a KVM vCPU and so
runs on the bare-metal CPU with no QEMU, no QMP socket and no dbus display. On
both non-QEMU backends `Capture.main_conn` is `None`, which disables dbus audio
(`SH_AUDIO_SOURCE=fifo` is the audio path that works there — see Audio) and QMP
idle auto-pause; input must be given an out-of-band backend
(`x11test` / `mamecmd`).

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_CAPTURE` | — | `qemu` | `qemu` (dbus-display shm scanout + v1 copy fallback), `x11`/`xvfb` (XDamage-gated `GetImage` of an X root window), or `shm` (a file-backed framebuffer the emulator publishes itself) | config, capture |
| `SH_X11_DISPLAY` | — | `:0` | X display for `SH_CAPTURE=x11` and for the `x11test` input backend | capture, x11_input |
| `SH_X11_CMD_FILE` | — | `/tmp/irix_cmd` | Command file the in-emulator MAME Lua agent (`irixagent.lua`) consumes. `x11test` appends buttons/keys to it (motion goes over XTEST); `mamecmd` appends motion too | x11_input, mame_input |
| `SH_X11TEST_ABS` | — | `off` | `x11test` backend: pointer MOTION as TRUE ABSOLUTE XTEST (root window plus root coordinates — the injection `xdotool mousemove` performs), for an unpatched SDL emulator that follows the host X cursor 1:1 (FS-UAE `--mouse_integration=1`, proven on the amigaos35 rig). No homing slam, no dead reckoning, no delta chunking. `off` keeps the historical relative+homing path byte for byte (the captured-MAME-window case) | config, x11_input |
| `SH_X11TEST_BUTTONS` | — | `cmdfile` | `x11test` backend button route. `cmdfile` (default) appends `DOWNn`/`UPn` lines for the MAME Lua agent, exactly as before. `xtest` sends XTEST ButtonPress/ButtonRelease instead (wire L/M/R → X buttons 1/2/3; wheel → one paced 4/5 — and 6/7 horizontal — click per event), for an agentless SDL emulator. Any other value panics at startup — on an agentless station a silent cmd-file fallback is a black hole for every click | config, x11_input, x11_keys |
| `SH_BTN_MIN_HOLD_MS` | — | `60` (capped at 250) | `SH_X11TEST_BUTTONS=xtest` dwell floor, BOTH directions: minimum press-to-release hold AND minimum release-to-next-press gap per button. A browser click's down/up pair arrives ~0 ms apart, and an XTEST press immediately followed by its release is NEVER seen by an emulator sampling at 50 Hz (measured on FS-UAE: xdotool's instant click never lands, a 150–200 ms hold always does) — so the pair is stretched, never dropped. 60 = three 50 Hz frames | config, x11_input, x11_keys |
| `SH_X11TEST_KEYS` | — | `off` | `x11test` backend: implement the keyboard as XTEST KeyPress/KeyRelease (with the flag off, x11test stations have no key route at all, exactly as before). Scancode → keysym via the embedded generated US-layout table (the same `stations/vice-native/us-layout.keysyms` the vicesock plane deploys; XT `0xe05b`/`0xe05c` → `Super_L`/`Super_R`, which FS-UAE maps to Left/Right Amiga); keysym → keycode resolved ONCE at startup from the display's own keyboard mapping. An unmapped key is rejected+counted (`[x11test] unmapped scancode …`), never guessed. Paced by `SH_KEY_MIN_HOLD_MS`/`SH_KEY_MIN_GAP_MS`, whose defaults are **40/40 for this sink** (see their rows: unset must not turn the floor off for a 50 Hz guest; an explicit `0` still wins). Per-key dwell only — one key's stretched dwell never delays or reorders another key's edges (the ctlsock `drain_keys()` non-exclusive semantics; see `x11_keys.rs`) | config, input, x11_input, x11_keys |
| `SH_X11TEST_KEYMAP` | — | unset (embedded US table) | Optional replacement scancode→keysym table for `SH_X11TEST_KEYS`, same generated format as `SH_VICESOCK_KEYMAP` (only the PLAIN column is used: XTEST presses physical keys and the X server applies the shift level from the browser's real Shift edges). Fail-closed like the other keymap knobs: a declared-but-broken file disables the keyboard loudly rather than falling back | x11_keys |
| `SH_X11TEST_MOTION` | — | `xtest` | `x11test` backend: where pointer MOTION goes. `xtest` injects into the host display as before (absolute or relative per `SH_X11TEST_ABS`). `warp` sends NO XTEST motion at all and instead drives the GUEST's own X server through an inner `x11warp` sink (`SH_X11WARP_DISPLAY`, e.g. `127.0.0.1:72` — the launcher's loopback-only slirp redirect to guest `:6000`): XWarpPointer to the absolute target, XQueryPointer readback. Buttons and keys keep riding XTEST into the host display, and the pacer holds every BUTTON edge on the warp sink's gate until the guest confirmed the pointer is at the target, then signals `edge_done()` — the sunos414 confirm→inject→done exclusion with the edge on XTEST instead of D-Bus. For a guest whose OS drives the emulated mouse hardware itself (amix: the UAE mousehack is an AmigaOS trap AMIX never registers, so any XTEST motion is relative+accelerated there). Any other value panics at startup | config, x11_input, x11_warp |
| `SH_MAMECMD_ABS` | — | `on` | `mamecmd` backend: emit closed-loop `MOVEA x y` targets (the agent converges against the Newport VC2 hardware-cursor registers, so dead-reckoning drift is impossible); `0` restores the dead-reckoned MOVEP path (rollback) | config, mame_input |
| `SH_MAMESOCK_PTR_GRID` | — | unset | `mamesock` backend, for a guest with NO hardware cursor for the module to close its MOVEA loop against: state pointer targets in guest mouse COUNTS instead of surface pixels, as `left,top,right,bottom,cols,rows` — the surface rectangle the guest pointer can reach and how many discrete positions span it. Set `MAME_CTL_SCREEN` to the same `<cols>x<rows>`. Unset (irix, every other tile) leaves the pixel path byte-identical. Measure it with `scripts/debridge-spike/armB-ptr-grid.py`; see `ptr_grid.rs` for why a quadrature-encoder pointer needs it | ptr_grid, mame_sock |
| `SH_SHM_PATH` | — | `/tmp/irix_fb.shm` | Path of the mapping the emulator publishes for `SH_CAPTURE=shm`; must equal the producer's `IRIX_SHM_PATH` | capture |
| `SH_SHM_POLL_MS` | — | `2` (clamp 1–100) | How often the shm capture thread reads the mapping's sequence word. The mapping carries no wakeup primitive, so this bounds added capture latency; the poll itself is one atomic load | capture |
| `SH_SHM_DAMAGE` | — | `on` | Recover a sub-frame damage bbox by diffing each changed frame against the previous one. The producer's header only reports whole-frame-or-nothing, so `off` forces a full BGRA→I420 conversion on every changed frame (the A/B control) | capture |

The `shm` backend exists because the `x11` one was measured at 32–43% of host
time for this tile: MAME rasterises the Newport framebuffer, uploads it to an SDL
texture, blits that through Mesa llvmpipe into an X window, and streamhost reads
the same pixels back — one frame software-rasterised twice and pushed through X
in between. With `-video none` MAME has no window at all, so pointer input must
move to `SH_INPUT_BACKEND=mamecmd` as well (XTEST has nothing to inject into).
It is also a fidelity fix: MAME's X window was 1272x954 on a 1280x1024 Xvfb and
scaled with the display, whereas the mapping carries the exact emulated
framebuffer (**1288x1024** once IRIX programs the VC2).

## Audio

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_AUDIO` | `--audio` | `off` | Capture+Opus-encode guest audio from the selected source | audio |
| `SH_AUDIO_SOURCE` | — | `dbus` | Where the PCM comes from: `dbus` (the QEMU dbus-display audio interface; needs the qemu capture backend's p2p connection) or `fifo` (a named pipe the emulator writes S16LE 2 ch 48 kHz into — no dbus needed, so `SH_AUDIO=on` now works on the `SH_CAPTURE=shm`/`x11` tiles too) | config (backends), audio |
| `SH_AUDIO_FIFO` | — | `<tile dir>/audio.fifo` | The FIFO for `SH_AUDIO_SOURCE=fifo`. The IRIX launcher reads THIS variable for its producer-side path, so the two ends cannot disagree | audio |
| `SH_AUDIO_SILENCE_THRESH` | — | `4` (max 32767) | `fifo` silence-gate threshold: a 20 ms frame whose max\|sample\| stays at or under this counts as silent (default 4 covers MAME's ±1–2 idle dither and is −78 dBFS) | config (backends), audio |
| `SH_AUDIO_BITRATE` | `--audio-bitrate` | `96000` | Opus bitrate, bps | audio |

The `fifo` source exists for the IRIX/MAME tile: MAME runs `-sound sdl
-audiodriver disk` with `SDL_DISKAUDIOFILE` pointed at the FIFO and
`SDL_DISKAUDIODELAY=0`, i.e. SDL just write()s its mixed PCM as fast as the
pipe accepts it. **The daemon is the clock**: it reads exactly 192,000 B/s
(S16LE 2 ch 48 kHz — 3840 bytes per 20 ms deadline tick), so the pipe's
backpressure paces SDL's writer; the FIFO is shrunk to 16 KiB
(`F_SETPIPE_SZ`), bounding buffered audio — and therefore added latency — at
~85 ms. A reader stall of more than 250 ms resnaps the pacing schedule to now
instead of bursting the backlog through the encoder. A silence gate stops
pushing audio packets after >=500 ms of digital silence (max|sample| at or
under `SH_AUDIO_SILENCE_THRESH`); any louder frame unmutes instantly, so an
idle desktop costs no audio bandwidth. EOF (the producer restarted) re-opens the
FIFO in a loop, and every (re)open starts with a non-blocking drain of stale
PCM. The samples feed the same Opus encode loop the dbus source uses, so the
wire is unchanged (48 k stereo, packet kind 2) and the SPA needs nothing.

Producer-side resilience is the launcher's job (see
`streamhost/stations/irix/x11-runtime.sh` `audio_up()`): MAME inherits SIGPIPE
ignored and an O_RDWR reader-of-last-resort fd on the FIFO, so with the daemon
dead or restarting the pipe simply fills (~85 ms) and SDL's audio thread blocks
while emulation continues — the exhibit itself is never at risk.

## Cert / signaling

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_HASH_FILE` | `--hash-file` | `<tile dir>/cert_hash_b64.txt` | Bare base64 cert hash (prototype back-compat) | cert |
| `SH_SIGNALING_JSON` | `--signaling-json` | `<tile dir>/signaling.json` | Atomic `{host,udpPort,certHashB64,…}` for the SERVE agent | cert |
| `SH_CERT_ROTATE_DAYS` | `--cert-rotate-days` | `10` (min 1) | Self-signed cert regeneration period (validity is <14 days by WebTransport rule) | cert |
| `SH_LOCAL_HTTP` | `--local-http` | unset | Optional built-in plain-HTTP signaling port (testing/A-B only) | signaling |

## Encoder / quality / ABR

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_ENCODER_PRESET` (`SH_PRESET` legacy fallback) | `--preset` | `ultrafast` | x264 preset (`ultrafast`…`veryslow`; invalid → ultrafast). **The registry no longer sets this per tile** — the fleet runs the default, and this knob exists for one-off experiments on a single tile. | encode |
| `SH_PROFILE` | `--profile` | `high` | H.264 profile `baseline`\|`main`\|`high` | encode |
| `SH_TUNE` | `--tune` | `zerolatency` | x264 tune | encode |
| `SH_CRF` | `--crf` | `10` (clamp 10–40) | Tier 0: CONSTANT QP (CQP kills the idle "dancing" — static screens code as bit-exact SKIP); ABR tiers ≥1: CRF anchor (+3/+6 per tier) with VBV | encode |
| `SH_MAXRATE_KBPS` | `--maxrate` | `0` = auto | Tier-0 maxrate/bufsize cap in kbps (auto = per-resolution table) | encode |
| `SH_BUFSIZE_RATIO` | `--bufsize-ratio` | daemon `1.0`, but **every emitted station.env carries `0.5`** (the fleet value, declared in `registry/registry-v1.json` `fleetEncoder.bufsizeRatio` and pinned to the emitter default by `stations-registry.py validate`) | VBV bufsize = ratio × maxrate. ABR tiers ≥1 apply `min(ratio, 0.5)` (WAN burst cap; tier 0 is CQP/no-VBV, so LAN is unaffected). Congested-tier maxrate is also clamped: T1 12 Mbps / T2 8 Mbps / T3 5 Mbps | encode |
| `SH_ABR` | `--abr` | `on` | Adaptive-bitrate controller (off pins tier 0) | abr |
| `SH_ABR_MIN_RESTART_MS` | `--abr-min-restart-ms` | `25000` (clamp 2000–30000) | DWELL: min ms between any two tier changes (anti-oscillation) | abr |
| `SH_ABR_FLOOR_HEIGHT` | `--abr-floor-height` | `480` (min 240) | Tier-3 resolution floor height, px | abr |
| `SH_ENC_THREADS` | `--enc-threads` | `0` = auto (min(4, cores), max 16) | libx264 SLICED threads — parallelism within a frame, no added frame latency | encode |
| `SH_ENC_NICE` | `--enc-nice` | `off` = inherit | Re-nice the dedicated encode thread (clamp −20…19) before `x264_encoder_open` so the sliced-thread pool inherits it; `off`/empty = no syscall | encode |
| `SH_DAMAGE_CONV` | `--damage-conv` | `on` | Scope native-resolution BGRA snapshot + I420 conversion to the even-padded union of D-Bus damage rectangles; `off` is the immediate full-frame fallback/rollback knob | capture, encode |
| `SH_DAMAGE_FULL_PCT` | `--damage-full-pct` | `35` (clamp 1–100) | Fall back to a full snapshot/conversion when either the damage bounding box or the accumulated area of damage events since the previous snapshot reaches this percentage of frame area; first frames, resolution changes, key requests, and downscaled ABR frames are always full | capture, encode |

## Transport / egress (env-only, no CLI flag)

| Env | Default | Effect | Module |
|---|---|---|---|
| `SH_SEND_MAX_BACKLOG` | `6` (frames; `0` = legacy unbounded relay) | Bounded per-session egress backlog: while a session is more than the effective bound — `max(N, fps/4)`, since the acked pointer sawtooths up to fps x the ~100 ms report cadence even on a healthy LAN — ahead of the client's acked consumption pointer (T_STATS `last_frame_id`, broadcast-queue-depth fallback), non-key AUs are dropped (latest wins) and the session resumes on a clean IDR (skip-triggered re-keys rate-limited to 1/500 ms/session). Bounds glass-to-glass lag at ~250 ms + RTT under bufferbloat; healthy LAN sessions stay under the bound and relay byte-identically | transport |
| `SH_CC` | `bbr` (`cubic` = quinn default, rollback) | QUIC congestion controller for the video path. BBR paces the send rate to the measured delivery rate, so a bufferbloated WAN queue is never filled to the loss point — video RTT stays near the unloaded floor and the ABR rtt-excess signal stays honest | transport |

## Idle auto-pause

| Env | Flag | Default | Effect | Module |
|---|---|---|---|---|
| `SH_IDLE_PAUSE_SECS` | `--idle-pause-secs` | `60` (`0` = off; nonzero clamped ≥5) | Freeze the guest after this many seconds with ZERO WebTransport sessions; the next accepted session thaws it + forces a keyframe, so the visitor sees the live screen sub-second. Pause ≠ loadvm (guest RAM/state untouched — safe on cold-boot-only tiles). Guest clocks freeze while paused. A reconciler re-asserts the pause every 60 s (heals external resumes, e.g. `labctl`, which auto-resumes before driving) and resumes a paused guest whenever a session is active. Per-tile opt-out: `SH_IDLE_PAUSE_SECS=0` in `station.env`. See `IDLE-PAUSE.md`. | idle, transport |
| `SH_IDLE_PAUSE_PIDFILE` | — | unset | Pidfile of the process to freeze on a NON-QEMU tile, where there is no QMP monitor to `stop`: the daemon `SIGSTOP`/`SIGCONT`s that process instead (`irix`, whose MAME otherwise runs flat out unwatched). Unset on a non-QEMU tile = no auto-pause; ignored on QEMU tiles. Re-read on every stop/cont, so a watchdog relaunch is followed. | idle |
| `SH_IDLE_PAUSE_PROC_MATCH` | — | unset (no check) | Substring that must appear in the pid's `/proc/<pid>/cmdline` before `SH_IDLE_PAUSE_PIDFILE`'s pid is signalled, so a stale pidfile whose pid the kernel recycled cannot freeze an unrelated process. `irix` uses `indy_4610`. | idle |
| `SH_IDLE_PAUSE_WARMUP_SECS` | — | `0` (off) | Withhold the FIRST freeze this long after daemon start, for a tile whose own health machinery needs the guest RUNNING to vet it. `irix` uses `780`: its livewatch waits 600 s before its first pointer probe, and that probe is the only thing that clears the instant-restore budget, so freezing at 60 s would leave an unvisited tile's budget to ratchet up until every launch fell back to the 390 s cold boot. Resumes are never withheld — only the freeze waits. | idle |

## Guards / debug flags (env-only, no CLI flag)

All trace flags gate on the value being exactly `1` (`config::env_flag`) —
`SH_VIDEO_TRACE=0` is OFF, not on.

| Env | Default | Effect | Module |
|---|---|---|---|
| `SH_QEMU_RSS_GUARD_MB` | `2048`, `0` = off | Recycle the capture listener when QEMU RSS grows this much above its low-water mark (bounds display-backlog growth; sub-second capture gap instead of a cgroup OOM kill) | capture |
| `SH_CAP_TRACE` | off (`1` enables) | Per-2s listener dispatch counters | capture |
| `SH_ENC_PROFILE` | off (`1` enables) | Fine-grained per-component encode-latency profiling (thread-CPU vs wall, queue span) | encode |
| `SH_VIDEO_TRACE` | off (`1` enables) | Per-AU video-path diagnostics (canary use only — eprintln at frame rate) | transport |
| `SH_DEBUG_INPUT` | off (`1`/`on` enables) | Log absolute pointer samples for per-guest tablet-origin calibration | input |

## Launcher-only vars (NOT read by the daemon)

`station.env` files also carry `SH_GOLDEN_SNAPSHOT` and `SH_RESET_MODE` — those are
consumed by the tile launcher/reset tooling (`loadvm golden` fixture), never by
the streamhost binary. They share the `SH_` prefix for station.env convenience only.

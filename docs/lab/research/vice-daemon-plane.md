# The VICE daemon plane — what streamhost needs before vic20 converts

**Status 2026-08-16: built, green, deployed nowhere.** The three research spikes
([video](vice-video-plane.md), [input](vice-input-plane.md),
[audio/checkpoint/survey](vice-audio-checkpoint-survey.md)) proved all four
planes on a patched VICE. What did not exist was the **daemon** half. This
document records what was added, the two open questions it answers from the
code, and the fixture/launcher shape the first conversion (vic20) will need.

No live station was touched. Nothing was deployed. The branch builds, its tests
pass, and every gate the change touches is green (§6).

---

## 1. What was added

| Artifact | What it is |
|---|---|
| `scripts/dev/vice-keymap.py` | the ONE hand-written home of the shared scancode -> keysym table, plus `--check` (drift + SPA-vocabulary parity) |
| `streamhost/stations/vice-native/us-layout.keysyms` | its generated output, 103 keys; deployed per station as `SH_VICESOCK_KEYMAP` |
| `streamhost/streamhost/src/vice_keymap.rs` | the loader (fail-closed) |
| `streamhost/streamhost/src/vice_sock.rs` | the `vicectl/1` input sink |
| `SH_INPUT_BACKEND=vicesock` | new backend value; `SH_VICECTL_SOCK` names the socket (default `<station-dir>/ctl.sock`) |
| `streamhost/stations/vice-native/x11-runtime.sh` | the SHARED launcher, committed but referenced by no station yet |
| `scripts/check-generated-drift.sh` | one extra step: the keysym table's drift check |

**Pure addition.** No existing station's behaviour changes: `vicesock` is never
inferred, only named; every new env var is unset on the fleet; the only edits to
shared code are one new enum arm, one new `Config` field, and one backend name
added to the key-routing filter in `input.rs`. The nine converted MAME stations
and the IRIX station keep byte-identical routing.

---

## 2. The scancode -> keysym decision

**The vocabulary, read out of the code, not assumed.** The browser sends **XT
set1 scancodes as `u16`, with the extended cluster encoded as `0xE0xx`** — the
QEMU number-keycode convention. Its one hand-written home is
`CODE_TO_SCANCODE` in `spa/src/three/guestQuirks.ts` (103 entries:
`Escape`..`F12`, the whole numpad, `NumLock`/`ScrollLock`/`PrintScreen`, the
extended nav cluster, `Meta*`, `ContextMenu`). `useStreamControl.ts` puts that
value on the wire verbatim; `input.rs` record type 3 reads it as a `u16` after
`SH_KEY_REMAP`. The MAME path consumes exactly the same vocabulary, which is
why `mame-keymap.py`'s `XT_KEYS` is keyed on it.

**The table is `scancode -> (plain keysym, shifted keysym)`, US layout, ONE file
for all seven stations.** Not per station, because VICE's `KEY` verb carries a
keysym and VICE resolves it through the machine's own `.vkm` — so virtual shift,
deshift, shift-lock and the C128 alternate set are the emulator's job, exactly as
they were in the bridged kiosk. The host layout has to be applied *before* the
wire (measured in the input spike: keysym `at` gives `@`; `Shift_L` held plus
keysym `2` gives `"`), because the bridged station's X server applied US before
VICE saw anything. So the sink **substitutes** the shift level for character
keys and **forwards** `Shift_L`/`Shift_R` as themselves, keeping `.vkm` entries
flagged `MAP_MOD_SHIFT` working.

Two details that are load-bearing rather than cosmetic:

- **A release repeats the keysym its press went out with.** The visitor can let
  Shift go before the character; resolving the release afresh would send
  `KEY 0 50` for a key pressed as `KEY 1 64` and leave the emulated matrix
  holding it down forever. The sink remembers per scancode.
- **Shift state is read from ROUTER truth** (`KeyEvent.modifiers` bits 0/1,
  `modifier_bit()` in `realtime_input.rs`), not tracked a second time in the
  sink, so the level and the edge cannot disagree.

**Where it lives.** Generated file `streamhost/stations/vice-native/us-layout.keysyms`,
never hand-edited, single source `scripts/dev/vice-keymap.py` — the repo's rule,
and the same shape as `mame-keymap.py` with one deliberate difference: the MAME
generator dumps from a *running machine* because the answer is per machine; this
one is a static host-layout fact, so it is generated offline and **committed**,
and `scripts/check-generated-drift.sh` re-runs `--check` on every branch.
`--check` also fails when the SPA's `CODE_TO_SCANCODE` grows a key the table has
no keysym for — a new key must not become a silently dead key on an exhibit.

Wire form: `KEY <0|1> <keysym-decimal>` — the exact value
`keyboard_key_pressed()` takes, no prefix to parse. The file carries hex plus a
`#` legend column (`0x0003  0x0032  0x0040  # 2 at`) so it can be read against
`data/*/gtk3_sym.vkm` by eye.

**Not implemented on purpose:** `--validate <ctl.sock>` against a machine's own
`KEYDUMP` (the input spike's §5 validator role). The fork's `KEYDUMP` reply
format is not frozen; guessing a wire format is the failure this pipeline exists
to end. It belongs in the same script, the day the fork lands.

---

## 3. `vice_sock.rs` — the sink

`mame_sock.rs`'s state machine, minus the pointer:

- `try_lock`-and-offer on the browser path; connect / banner / write / ack-read /
  reconnect in one background task; bounded ordered queue (64); health
  Starting/Healthy/Down; 50 ms..1 s reconnect backoff.
- **Banner**: `vicectl/1 …`, with or without a `HELLO ` prefix, within 1 s, else
  the peer is not a compatible module.
- **Ack budget**: 5 s base + 200 ms per outstanding paced verb. Every `KEY` is
  paced, because pacing lives in the EMULATOR on this path (the daemon's
  `SH_KEY_MIN_*` gate only runs on the QEMU/dbus path) and the guest's own
  ceiling is ~8.5 keys/s.
- **Unmapped scancodes** are counted AND logged per edge, `mame_sock.rs`'s
  hard-won rule: a silent unmapped reject was the one loss the 2026-08-12 typing
  investigation could not see in any counter. Counters line every 10 s:
  `accepted / dropped / overflow / backend-down / unmapped`.
- **Reconnect resync is `KEYCLEAR` + FORGET.** A held key is never re-pressed
  across a reconnect: these guests scan their own matrix and generate their own
  auto-repeat from a held bit, so a re-press whose release was lost with the old
  connection types forever. (The MAME sink re-presses held *buttons*; a button
  has no auto-repeat, a key does.)
- **Keyboard only.** Pointer records are rejected (logged once), not turned into
  invented joyport motion. All seven stations are `pointer: none`; `c64`'s GEOS
  1351 pointer is the wave's last station and earns its verb when measured.
- **Fail-closed keymap**: `SH_VICESOCK_KEYMAP` unset, unreadable or malformed all
  yield an empty map that rejects every key, loudly. There is no compiled-in
  fallback — a substituted table is the failure mode this ends.
- `SH_VICESOCK_TRACE=1` gives one line per ingress/tx/ack, mirroring
  `SH_MAMESOCK_TRACE`.

Tests (all green): the wire contract including shift substitution and
release-what-you-pressed; reconnect resync with no replay; the keymap loader's
refusals; and the SHIPPED table loading and resolving — so a regenerated table
that broke the format would fail `cargo test`, not an exhibit.

---

## 4. Open question (a) — VICE surfaces are native-size. Where does streamhost scale?

**Answer: it does not, and nothing needs to change for these seven.**

The chain, from the code:

1. `capture/shm.rs` maps the producer's file and takes `width`/`height` **from
   the mapping's own header**. It re-`mmap`s when the geometry changes; that path
   already exists because IRIX reprograms its VC2 mid-run.
2. `encode/run.rs` waits for the first frame, learns `(w, h)` from capture state,
   and opens x264 at that size. A mid-stream geometry change is detected per
   snapshot (`fw != w || fh != h`) and re-opens the encoder — the VICE producer
   re-`ftruncate`s on a chip/size change, so this is the path that catches it.
3. The ONLY downscale in the daemon is the ABR ladder in
   `encode/params.rs::resolve_tier`: tier 3 steps ~0.75× height (16-aligned,
   never below `SH_ABR_FLOOR_HEIGHT`, min 240), tier 2 steps ~6/7 only when
   `SH_ABR_RES_LADDER` is on. Tiers 0-1 are native. A LAN session never leaves
   tier 0, so on the gallery floor the encoder is always at native size.
4. There is **no upscale anywhere**. The browser scales the video element; the
   surface is the exhibit's true pixels.

So a VICE station publishing 768×544 (`x64sc` at 2×), 768×576 (`xplus4`),
896×568 (`xvic`) or 704×528 (`xcbm2` native) is handled by the same code that
handles MAME's `MAME_NATIVE_GEOM`. Consequences worth stating rather than
rediscovering:

- **`MAME_NATIVE_GEOM` has no VICE equivalent and must not be invented.** MAME
  lets a station letterbox its machine inside an arbitrary published surface;
  VICE's surface *is* the emulated screen × the integer `<CHIP>DoubleSize` (and
  `<CHIP>Filter`). The knobs that decide geometry are those two resources, set
  per station in `VICE_NATIVE_ARGS`, and the published size follows.
- **Odd geometry is safe.** `encode/convert.rs` handles odd width/height
  (`div_ceil` chroma planes, an odd-edge fallback that is bit-identical to the
  naive oracle), so a 789-wide surface encodes correctly. Prefer an even size
  anyway — chroma on an odd edge is a half-resolution guess, not a crash.
- **The CRT filter at 2× costs ~11 % of a core** (measured: 5.01 → 7.18 CPU-s per
  20 emulated s) while publishing itself costs ~0.7 %. That is a per-exhibit
  choice, not something to inherit.
- Each station's real geometry must be **measured after the first launch** (the
  bridged tables are window sizes inside a kiosk, not producer sizes) and written
  into its fixture description, exactly as the MAME wave did.

## 5. Open question (b) — x128 has two canvases

**Answer: the daemon needs nothing; the FORK needs a selector, and the station
must state which canvas it is.**

The publisher claims the mapping on **first canvas to refresh** (video-plane
spike §2), which on `x128` observed as canvas 0 = the **VDC** — correct for
`c128`, whose whole exhibit is the 80-column screen (`x128 -pal -80col`). But
"correct by first-refresh order" is a race dressed as a default: it is a
property of which chip happens to refresh first in a given build, not a
statement of intent. Three facts follow:

1. **`c128` must declare it.** The fixture carries `-80col`, and the station's
   `SH_FIXTURE_DESC` must say the published surface is the VDC. The input
   spike's `SHOT` verb has the same canvas-0 behaviour, so a checkpoint's ACCEPT
   frame is the same canvas — consistent, and worth asserting rather than
   assuming.
2. **`VICE_SHM_CHIP` is the fix, and it is fork work, not daemon work.** The
   video spike already names it. Until it exists, `c128`'s conversion must prove
   the canvas from the framebuffer (an 80-column `COMMODORE BASIC V7.0` banner is
   unambiguous against the VIC-II's 40-column one) and fail the bake if the
   wrong one is published.
3. **`GO64` still cannot ship**, for the same reason it could not on the bridge:
   C64 mode paints the VIC-II while the published canvas is the VDC, and two
   screendumps 10 s apart were byte-identical. This is a property of the machine,
   not of the transport, and it survives de-bridging unchanged.

Nothing in `capture/shm.rs` needs a canvas concept: it consumes ONE mapping with
one producer, which is exactly what first-canvas-wins guarantees. The risk is
not tearing, it is publishing the *wrong* screen silently.

---

## 6. Green

Run in this worktree, on a workstation checkout (`CARGO_TARGET_DIR` overridden;
the repo's `.cargo/config.toml` points at the box's shared target tree):

| Gate | Result |
|---|---|
| `cargo fmt --all --check` | OK |
| `cargo clippy --all-targets -- -D warnings` | OK |
| `cargo test` | 152 passed, 2 ignored |
| `ruff check scripts && ruff format --check scripts` | OK |
| `node scripts/check-file-size.mjs --strict` | OK, 0 hard, 0 stale |
| `shellcheck` + `shfmt -d` over `scripts/lint/shell-sources.sh` | OK |
| `scripts/check-generated-drift.sh` | OK (incl. the new keysym-table step) |

Two notes on the gate itself:

- `cargo fmt` reformatted **one pre-existing line in `mame_sock.rs`** that was
  already red before this branch (a newer stable rustfmt splits a chained
  `fetch_add`). Whitespace only, no behaviour, and it is what made
  `cargo fmt --all --check` green.
- `vice_sock.rs` was split at birth: the keymap loader lives in
  `vice_keymap.rs`, because the combined file was over the 800-line Rust hard
  cap. **No `size-exclusions.json` entry was added.** `config/mod.rs` sat at
  797/800 and is now at exactly 800 — the next field added there forces a split,
  which is the gate working as designed.

---

## 7. The fixture and launcher a converted VICE station needs (SKETCH)

Following the nine converted MAME fixtures. This is `vic20`, the wave's
template; the per-station delta for four of the seven is a binary name, a model
flag and a readiness predicate.

```sh
# ---- HOST-NATIVE STATION (de-bridged, VICE wave) ----
# VICE xvic runs ON THE HOST: no QEMU, no guest Debian, no X. Frames:
# the headless shm publisher -> SH_CAPTURE=shm (same IFB1 wire format as
# drawshm). Keys: vicectl + the ONE shared generated keysym table. Audio:
# -sounddev wav -> named FIFO, the daemon is the clock. Launcher: the shared
# stations/vice-native/x11-runtime.sh; VICE_NATIVE_* are its knobs.
SH_RESET_MODE=relaunch
SH_FIXTURE_DESC=Commodore VIC-20 (PAL) ROM BASIC power-on screen … <measured geometry>
VICE_NATIVE_BIN=/data/vms/streamhost/assets/vic20/vice-native/bin/xvic
VICE_NATIVE_DATA=/data/vms/streamhost/assets/vic20/vice-native/share/vice
VICE_NATIVE_ARGS=-pal -VICdsize -VICborders 0
SH_VICECTL_SOCK=/data/vms/streamhost/stations/vic20/ctl.sock
SH_VICESOCK_KEYMAP=/data/vms/streamhost/stations/vic20/us-layout.keysyms
SH_AUDIO_SOURCE=fifo
SH_AUDIO_FIFO=/data/vms/streamhost/stations/vic20/audio.fifo

# ---- STANDBY (instant-ready) ----
SH_IDLE_PAUSE_SECS=60
SH_IDLE_PAUSE_PIDFILE=/data/vms/streamhost/stations/vic20/vice.pid
SH_IDLE_PAUSE_PROC_MATCH=assets/vic20/vice-native
VICE_NATIVE_STANDBY_DELAY_S=8

# ---- KEYBOARD PACING ----
# RE-BISECT, do not inherit: the bridged 80/80 was measured against QEMU
# send-key through an SDL kiosk, not against this engine. The module derives
# its per-key dwell floors from these two.
SH_KEY_MIN_HOLD_MS=80
SH_KEY_MIN_GAP_MS=80
```

Emit line, mirroring the MAME nine (the shared keysym table rides `--aux-file`,
which copies by basename into the station dir):

```
emit vic20 --tile vic20 --udp <port> --x11 --x11-display :NN --capture shm \
  --pointer none --input-backend vicesock --audio on --fps 50 \
  --x11-runtime-file "$T/vice-native/x11-runtime.sh" \
  --aux-file "$T/vice-native/us-layout.keysyms" \
  --env-append-file "$T/vic20/station.env.fixture"
```

The launcher is committed at `streamhost/stations/vice-native/x11-runtime.sh`
and referenced by nothing yet. Its three non-obvious parts:

- **Audio is NOT the MAME recipe.** `-sounddev wav -soundarg <fifo> -soundrate
  48000 -soundoutput 2`, plus the resident `O_RDWR` holder fd. Copying the
  `mame-native`/`irix` `-sound sdl -audiodriver disk` stanza is the single most
  likely way this wave ships a station running at **24 % speed** with
  correct-looking audio: VICE's `sdl` device is flagged `is_timing_source`, so
  the pipe becomes the emulator's clock. `-soundoutput 3` is a hard parse error.
  Without the holder fd, EPIPE kills audio silently and unlogged.
- **`VICE_CTL_KEY_EXCL=1` is exported unconditionally.** Not a tuning knob: the
  same 36-edge burst without it printed `N ''N`.
- **Restore is `-moncommands` + `-initbreak ready`** (VICE has no
  `-loadsnapshot`), writing a one-command playback file — the first `x` ends
  playback. `VICE_NATIVE_CHECKPOINT=0` cold-boots instead. Unlike MAME there is
  no `MACHINE_SUPPORTS_SAVE` lottery: `snapshot.c` gates on machine name and
  per-module version and fails loudly.

---

## 8. What still blocks vic20

Daemon-side, nothing. What remains is fork and build work:

1. **The fork does not exist yet as a submodule.** `third_party/vice-kernel-hive`
   at the pinned `v3.10.0`, with both spike branches (`kernel-hive/shmfb`,
   `kernel-hive-vicectl`) rebased onto it. Both spikes were developed on the
   mirror's moving `main`.
2. **`KEY`'s argument form must be frozen in the module** as a decimal numeric
   keysym (this sink's wire form). The spike documents the verb as
   `KEY <0|1> <keysym>`; if the module ends up accepting keysym NAMES only, the
   one-line change is here, and the generated table already carries the names in
   its legend column.
3. **`KEYDUMP`'s reply format** must be frozen before `--validate` can be
   written, and with it the acceptance check "every key the exhibit offers is a
   key this machine names".
4. **Pacing must be re-bisected** against this engine
   (`scripts/dev/emu-key-pacing-bisect.py`), not inherited from the bridged
   40/60/80.
5. **A builder + `native.d` stanza**, the registry conversion
   (`registry-to-native.py` learns `vicesock`/`vice-native`), and `dos2unix` +
   `xa65` on the build host.
6. **Geometry must be measured**, not copied from the kiosk window tables.

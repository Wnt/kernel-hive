# De-bridging `indyr4400` — Iris host-native, fork brief

**Status: PLAN (2026-09-09). Nothing built, nothing on the box.** Produced by an
Opus discovery agent, read-only, from the sources cited on every line below.
Rule 13 work: the last SGI Indy in the lineup that still runs inside a Debian
kiosk.

This file is the **design record and the results record** for the conversion —
the FS-UAE convention ([`FSUAE-NATIVE-BRIEF.md`](FSUAE-NATIVE-BRIEF.md)). §§1–6
are the plan as discovered; [§7](#7-landing-record) is the empty ledger the
streams fill with what they measure. It is a living document: when a stream
disproves something here, **rewrite the paragraph**, do not append a
contradicting annex. Stream E owns it.

**The number that starts this.** Measured 2026-09-09 on three sparse clones of
the station's own overlay ([`docs/guests/indyr4400.md`](../guests/indyr4400.md)
§*Upstream bump 2026-09-09*, carried on branch `irisup` at `5ec1e3b4`):

| | Iris `1e05210` (live) | Iris `0540991` interp | Iris `0540991` jitv2 | MAME `irix` host-native |
|---|---|---|---|---|
| one pointer move → framebuffer, median of 5 | 361 ms | 285 ms | 383 ms | **68 ms** |
| pointer stream, lag after last event | 216 ms | 224 ms | 397 ms | ~0 ms |
| fixed CPU work, host wall clock | 8.4 s | 8.1–10.2 s | **1.95 s** | 1.60 s |

The wave's own conclusion: *"The pointer lag is not the emulator core. Every
Iris build sits at 250–400 ms and MAME at ~70 ms, because this station is a
bridge: QEMU PS/2 → guest X → winit → Iris → llvmpipe → dbus capture, versus
MAME's host-native `mamesock` → ioport → shm. The mouse gets fixed by
converting the station to a host-native runtime (rule 13), not by any Iris
commit."* This brief is that conversion.

---

## 1. The pattern, from every conversion the lab has already done

Read for this brief:
[`DEBRIDGE-HANDOVER.md`](DEBRIDGE-HANDOVER.md),
[`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md),
[`FSUAE-NATIVE-BRIEF.md`](FSUAE-NATIVE-BRIEF.md),
[`MEDLEY-NSPAWN-WAVE.md`](MEDLEY-NSPAWN-WAVE.md),
[`docs/guests/nextstep.md`](../guests/nextstep.md),
[`docs/guests/medley.md`](../guests/medley.md),
[`docs/guests/lisa.md`](../guests/lisa.md),
[`docs/guests/irix.md`](../guests/irix.md).

| Wave | Capture | Input | Reset | Containment | The trap that cost the time |
|---|---|---|---|---|---|
| **9 MAME kiosks** (2026-08-12) | `-video shm` drawshm → `SH_CAPTURE=shm`, IFB1 | ctlsock `KEY <0\|1> <port> <field>` + generated keymap; keyboard-only | `relaunch` + `SAVEST golden`, cold boot where the driver lacks `MACHINE_SUPPORTS_SAVE` | none (emulated machine, root) | `MAME_CTL_KEY_EXCL`: these guests scan their own matrix and the browser sends a line as ONE burst — every converted station must set it (handover §Lessons 2) |
| **7 VICE stations** (2026-08-16/17) | `VICE_SHM_PATH`, same IFB1 wire | vicectl `KEY <0\|1> <keysym>`, one shared `us-layout.keysyms` | `relaunch` + `-moncommands` restoring `golden.vsf` | none | audio device is a timing source: `-sounddev fifo`, **never** sdl+disk, or the pipe becomes the clock (24 % speed). And `SAVEST` wrote stale CPU registers (handover §The restore bug) |
| **`nextstep`** (2026-08-25) — *the closest precedent* | fork `Wnt/previous`, `PREVIOUS_SHM_PATH` → `SH_CAPTURE=shm`, **`SH_SHM_DAMAGE=0`** (fork publishes a real dirty rect) | fork's socket speaks **`mamectl/1` verbatim** → `SH_INPUT_BACKEND=mamesock` + `SH_MAMESOCK_KEYMAP`; abs pointer via the guest's own tablet | **CRIU restore** of the emulator process, 2.8–3.0 s vs 135 s cold | unprivileged account `nsexhibit` (required: criu cannot dump a chr-dev fd) | four things that pass a smoke test while broken — `AF_PACKET` undumpable, veth must be `--external`, the publisher's private shadow drifts from the mapping so a restore serves a stale page forever (`FBSYNC` verb), a CONNECTED client blocks the dump ([`nextstep.md`](../guests/nextstep.md) §5) |
| **FS-UAE `a1000`/`a3000`** (2026-09-09) | fork `Wnt/fs-uae`, second frontend registering `amiga_set_render_function` → IFB1 shm, no libfsemu, no GL | `FSUAE_NATIVE_CTL_SOCK` → `SH_INPUT_BACKEND=mamesock`; abs mouse via `uae_mousehack_helper` | `relaunch` (in-process `uae_reset` on the fork) | none | `getgfxoffset` is *renderer* state — headless it is uninitialised and the pointer transform is garbage; and `amix` **rolled back** because its buttons/keys rode XTEST while its pointer warped into the guest's X: **the daemon runs one input backend per station and does not compose x11warp motion with ctlsock edges** |
| **`medley`** (2026-09-09, incident) | `SH_CAPTURE=x11` on a pinned Xvfb | `SH_INPUT_BACKEND=x11test`, `SH_X11TEST_ABS=1` | `relaunch`, wipe `work/` | **systemd-nspawn**, private PID/mount/net/IPC/UTS/user ns, `--volatile=overlay`, `--private-users=1966080:65536`, CAP_SYS_ADMIN dropped, `--system-call-filter='~@mount'`, `--as-pid2`, `--keep-unit` | a *host application* as a guest ran as root in the host namespaces; operator deactivated the station. `nsenter` alone over-approximates what the payload can do — drop to its bounding set with `setpriv` before calling a mount test a proof |
| **`lisa`** (2026-09-09) | `SH_CAPTURE=x11`, Xvfb pinned to the emulated 720x498 | `x11test` abs; `SH_BTN_MIN_HOLD_MS=150` (an instant press never registered) | `relaunch` + a fresh copy of the golden ProFile; LisaEm has no savestate | nspawn, same shape as medley | only a **negative Y** window move is safe — a negative X made GDK drop every button event while motion still worked |

Two corrections to the folklore, checked this session: **`sculpt` is not an
nspawn or x11warp station** — it is an ordinary QEMU station with
`SH_INPUT_BACKEND=dbus-rel` and `SH_RESET_MODE=loadvm` (useful as a
checkpoint/rel-bridge template, not a containment one); and
**`streamhost/stations/domainos/` does not exist** — that wave was stopped by
operator order before landing, so there is nothing to copy from it and its
claims (slot 192, `10.99.0.40`, display `:92`, …) are still held.

**What every one of them has in common** — the reusable pattern:

1. **Three planes, published by the emulator itself, consumed by env alone.**
   `frames = IFB1 shm`, `input = mamectl/1 on a unix socket`,
   `audio = s16le/48k stereo into a FIFO`. `nextstep` wrote **zero** streamhost
   code ([`nextstep.md:33`](../guests/nextstep.md)); that is the bar.
2. **`SH_STATION_RUNTIME=x11` is the marker, and there is no X.**
   `streamhost/scripts/ensure-station-qemu.sh:21-23` dispatches on it and execs
   `$BASE/x11-runtime.sh` by that fixed name. `runtime.x11` in the registry means
   "non-QEMU emulator managed by a tracked launcher"
   ([`DEBRIDGE-HANDOVER.md:56`](DEBRIDGE-HANDOVER.md)).
3. **The fork, not a rewrite, and not a different core.** Rule 6: golden +
   binary + device set are ONE combination, so swapping emulators orphans every
   checkpoint. FS-UAE chose the fork over libretro-uae for exactly this
   ([`FSUAE-NATIVE-BRIEF.md`](FSUAE-NATIVE-BRIEF.md) Part 3 reason 1).
4. **Every fork commit is knob-gated**, so with the knob unset the binary is
   byte-behaviourally identical and the live station keeps running off the same
   source until cutover.
5. **A non-QEMU station gets idle auto-pause only if its env names the
   emulator's pidfile** — `SH_IDLE_PAUSE_PIDFILE` + `SH_IDLE_PAUSE_PROC_MATCH`
   scoped to the station's own asset path. Without it it burns a core forever
   (handover §Lessons 6; `idle.rs` never infers a freezer).
6. **`systemctl restart` does not kill the previous emulator.** `readlink -f
   /proc/<pid>/exe` on a REPLACED binary yields `"<path> (deleted)"`, and a
   SIGSTOPped standby never runs to handle SIGTERM: **SIGCONT, then TERM, then
   KILL**, sweep `/proc` scoped to the asset dir, and refuse to start if
   anything survives (handover §Lessons 7 — this produced two emulators into one
   mapping on three live stations).
7. **Key pacing lives in the emulator module on this path.** The daemon's
   `SH_KEY_MIN_*` gate only runs on the QEMU/dbus path; the launcher must derive
   the module's floors from it. Repro with a **pipelined** sender at zero spacing
   (`scripts/dev/key-replay.py`) — an acking test client paces the edges for you
   and hides the bug perfectly.

---

## 2. What Iris actually offers — and the ranked recommendation

Source read for this brief: a read-only scratch clone of `techomancer/iris` at
`0540991` (upstream `main` on 2026-09-09). Every `src/...` line number below is
that commit's; re-resolve them against the fork's own tree before trusting one.

### The findings that decide the design

**(a) `--headless` is the wrong flag and is a dead end.** `src/machine.rs:516`:
`let rex3: Option<Arc<Rex3>> = if cfg.headless || cfg.graphics.board != Newport`
— headless *omits REX3 entirely*, and `src/main.rs:127-128` prints
`"iris: running headless (no REX3, no window)"`. There is no framebuffer at all.
`src/config.rs:1299` says so outright: *"Run headless: no window, no REX3
graphics"*.

**(b) `--ci` without `--ci-display` is ALREADY a no-window, REX3-alive mode.**
`src/main.rs:125`: `let show_window = !headless && !(ci_enabled && !ci_display);`
and `:130` `"iris: --ci mode (REX3 rendering to offscreen buffer, no window)"`.
`src/config.rs:1449`: *"NB: `--ci` does NOT imply `--headless`. REX3 stays alive
so screenshots work; main.rs simply skips the host window."* The winit/glutin
event loop (`src/ui.rs`) is never entered. **No X server is needed at run
time** (though the binary still links against one — see (d0)). `--ci` also starts a JSON-lines control socket
(`iris::ci::start_server`, `src/main.rs:73`, default `/tmp/iris.sock`,
overridable with `--ci-socket`) holding a `*mut Machine`.

**(c) The frame publisher and the input seam are already written.**

- **Frames.** `iris-gui/src/framebuffer.rs:56` `pub struct CaptureRenderer` —
  a `Renderer` (`src/rex3.rs:18`) implementation driving the CPU `SwCompositor`
  and packing the composited frame into a shared slot with `width`, `height`,
  tightly-packed pixels, a `seq` counter **and a `dirty_y`/`dirty_h` scanline
  band** (`:27-30`). The compositor composites the **hardware cursor** in
  (`src/compositor.rs:120-129`), which is what makes the pointer visible in the
  published frame and readable by `scripts/dev/cursor-locate.py`.
  **Pixel format — derive this, do not trust the comments.** The compositor's
  final store is `src/compositor.rs:237`:
  `buf[out_idx] = 0xFF000000 | (r_out << 16) | (g_out << 8) | b_out;`
  with `r_in = (final_color >> 16) & 0xFF` at `:230-236`, and the Newport source
  word is documented at `src/rex3.rs:4405` as `bits[7:0]=B, [15:8]=G,
  [23:16]=R`. So the buffer word is **`0xFFRRGGBB`, i.e. B,G,R,X in
  little-endian memory — byte-identical to IFB1/BGRA, zero per-pixel
  conversion**, exactly as MAME's `bitmap_rgb32`
  (`streamhost/streamhost/src/capture/shm.rs:35-39`). That is a real saving: at
  1280x1024 a swap pass would be 1.3 M pixels every frame.
  Two things in the tree contradict that and are **wrong**, not evidence:
  `src/disp.rs:773`'s comment (*"`rgba` uses 0xFFBBGGRR (GL-native); swap R↔B
  when writing PNG"*) and `save_screenshot` beneath it, which pushes
  `px & 0xFF` — the BLUE byte — as the PNG's red channel. **The RCtrl+PrintScreen
  screenshot has its red and blue swapped; `ci.rs:585-590` is the correct
  encoder.** Prove the orientation on the first published frame anyway (IRIX's
  4Dwm desktop is teal — a swap turns it orange, unmissable) rather than
  believing this paragraph.
  The one hole — and it is the whole of the fork's video work: `rex3.renderer`
  (`src/rex3.rs:1221`, `Mutex<Option<Box<dyn Renderer>>>`, initialised `None` at
  `:1361`) is installed at **exactly one place in `iris` proper**, `src/ui.rs:839`,
  on the windowed path only. Under `--ci` it stays `None`, `present()` is never
  called (`src/rex3.rs:4055-4110` guards on `if let Some(ref mut r)`), and
  `screen.rgba` stays zeroed — **so the `--ci` banner's "REX3 rendering to
  offscreen buffer" is false at HEAD and `iris-ci screenshot` writes a black
  PNG.** The REX3 refresh thread itself *does* run (`src/rex3.rs:4507-4521`
  spawns `REX3-Processor` and `REX3-Refresh` unconditionally) and
  `screen.refresh()` still copies FB/VC2/CMAP state and sets width/height — only
  compose+present is missing.
  `iris-gui` already closes it, at `iris-gui/src/handle.rs:386-398`:
  ```rust
  if let Some(rex3) = m.get_rex3() {
      *rex3.renderer.lock() = Some(new_capture_renderer(sink_for_machine));
  }
  ```
  with the comment at `:370-375` that is this brief's plan in one sentence:
  *"We do NOT force `headless = true` here — iris-gui needs REX3 alive so it can
  capture the framebuffer. Iris itself never opens a winit window unless
  `main.rs` calls `Ui::run`; we don't, so there's no event-loop conflict."*
  **The fork's job: install that renderer on the `!show_window` branch and have
  its `present()` write IFB1 instead of a `FrameSink`.**

  Two facts that decide the geometry question: the framebuffer is
  **2048x1024 words, stride 2048**, with the visible sub-rect decoded from VC2
  timings (`src/disp.rs:299`, `src/rex3.rs:1299-1300`) — `1282` is a decoded
  value, not a literal — and **Iris's 16-row status HUD is a SEPARATE
  2048x16 GL texture** (`src/disp.rs:415,427`) composited as its own pass
  (`src/ui.rs:632-634`), *not* part of `screen.rgba`. `iris-gui` ignores it
  outright (`iris-gui/src/framebuffer.rs:91-97`). **So host-native the HUD
  simply does not exist in the published frame, and the X-root clipping hack the
  bridge needed disappears.**
- **Input.** `src/ps2.rs:413` `pub fn push_kb(&self, key: KeyCode, pressed: bool)`
  and `src/ps2.rs:814` `pub fn push_mouse_input(&self, buttons: u8, dx: i32,
  dy: i32, dz: i32)`. Both public, both reachable from `machine.get_ps2()`.
  `iris-gui/src/input.rs:193,213` already drives exactly these two from a
  non-winit event source (egui) — proof the seam works without the window.
  Key encoding is `winit::keyboard::KeyCode` passed straight through with no
  layout translation (`src/ui.rs:923`; the guest applies its own `keybd=`
  layout), so a per-station keymap in the `nextstep.keymap` shape (port `kbd`,
  field = a KeyCode name) is the whole keyboard story.
  **Both functions silently drop input behind guest-state gates** — `push_kb`
  returns early unless `running && scanning_enabled && !(config & 0x10)`
  (`src/ps2.rs:414-417`), `push_mouse_input` unless
  `running && mouse_enabled && !(config & 0x20)` (`:815-817`); those CTR bits are
  the i8042 AUX/KBD port toggles added by `bc9de1d`, which Linux and IRIX both
  probe. A backend that injects before the guest has enabled the port sees
  nothing happen and no error — check with the monitor's `ps2 status`. Deltas
  clamp to ±256 per packet with the overflow bits set (`:819-821`) and packets
  coalesce into the tail once 8 are pending (`:832-872`), so a burst of small
  moves can merge: the closed loop must read back, not count what it sent. `--features` has a documented `WindowEvent::CursorMoved`
  variant *"useful for testing absolute cursor position tracking"*
  (`Cargo.toml`, above the `chd` block).
- **Reset.** `CHANGELOG.md:68-105`: a complete snapshot/rollback stack —
  `save_snapshot` / `load_snapshot` / `ci_restore` / `ci_rollback` on `Machine`,
  capturing *CPU, MC, IOC, HPC3, … and the REX3 framebuffer chunks*
  (`src/snapshot.rs:379`) plus the SCSI COW overlay, with reflink capture on
  btrfs/xfs, a CAS chunk store, a `snapshot.toml` manifest with a `parent`
  chain, and a **determinism validator**. `ci_rollback` replays a cached
  in-memory `RollbackCheckpoint` and is **measured at ~42 ms**
  (`CHANGELOG.md:74-76`). Exposed on the ci socket already as
  `save`/`restore`/`rollback`/`list`/`info`/`delete` (`src/ci.rs:257-262`).
- **What the ci socket does NOT have: any pointer or keyboard verb.** The
  dispatch table is complete at `src/ci.rs:252-282` — 27 commands
  (`ping quit start save restore rollback list info delete serial-send
  serial-read wait-serial screenshot scratch-* validate gc diff tree pull push
  rtc-save cdrom-eject cdrom-load chd-sync`). The only guest input is
  `serial-send`. `screenshot` is file-mediated (writes a PNG to disk, not an
  in-band pixel channel) and is dead until a renderer exists.
- **The monitor console (TCP `127.0.0.1:8888`, hardcoded, always started — even
  in ci mode, `src/machine.rs:993-996`) has keyboard injection but no mouse.**
  `ps2 type <ascii>` / `ps2 enter` / `ps2 status` (`src/ps2.rs:919-966`,
  printable ASCII only, press+release with no held state), `save <name>` /
  `load <name>` / `machine-stop` / `machine-start` / `reset`
  (`src/machine.rs:2060-2100`), `rex fbdump [DIR]` (raw 2048x1024 VRAM planes +
  PNG previews, 18 MB per call — debugging only, not a frame channel;
  commit `9c7721a`), and `rtc save`. **`rollback` is CI-socket-only.** There is
  no central command table: each device registers its verbs
  (`src/monitor.rs:109-141`). `src/iris_mcp.py` is a FastMCP wrapper over this
  same socket with a `run_command` passthrough.

**(d0) winit/glutin/glow/cpal/rfd are UNCONDITIONAL dependencies.**
`Cargo.toml` marks none of them `optional`, `src/lib.rs:209-215` declares
`pub mod ui; … gl_compositor; headless_gl;` with no `#[cfg]`, and
`--no-default-features` removes only `tlbvmap`. The binary therefore always
*links* X11/Wayland/libxkbcommon/GL/ALSA/D-Bus even though it opens none of them
unless `Ui::run` is reached. A truly display-free build is real surgery —
`SwCompositor` still imports `glow::HasContext` for its texture upload, and
`disp::StatusBarTexture` is GL-touched (`src/disp.rs:3,427-461`) — so **do not
put a `no-ui` feature on the critical path**: run the stock link with no
`DISPLAY`, and treat cutting the dependency as an optional later commit.

**(d) `ultra64` is not a frame channel.** `Cargo.toml`: *"N64 development board
(Ultra64) — GIO slot 0 + shm IPC"*, `ultra64 = ["dep:shared_memory",
"dep:raw_sync"]`. It is an emulated GIO expansion board talking to an external
N64 process. Irrelevant here.

**(e) Two `--ci` side effects that must be handled, not inherited.**
`src/machine.rs:472`: with `ci_enabled` a non-cdrom device with `overlay = true`
gets its COW file redirected to `/tmp/iris-ci-<pid>-scsiN.overlay` — a
throwaway per-pid overlay. And `src/machine.rs:321,328`: `Ioc::new_ci` replaces
the SCC serial backends, so **the telnet exec channel on `127.0.0.1:8880/8881`
that [`streamhost/guest-agents/irix-iris/README.md`](../../streamhost/guest-agents/irix-iris/README.md)
documents disappears in ci mode** (replaced by `serial-send`/`wait-serial` on
the ci socket — which is strictly better, and unwedges the single-client telnet
trap the perf wave hit). The fork should gate the frame/input planes on their
own env knobs rather than on `--ci`, and reuse only `--ci`'s no-window branch.

### Ranked architectures

| Rank | Architecture | Exists today | Must be written | Latency expectation | Reset |
|---|---|---|---|---|---|
| **1 — RECOMMENDED** | **`Wnt/iris` fork: no-window mode + a `Renderer` publishing IFB1 to `IRIS_SHM_PATH`, + a `mamectl/1` listener on `IRIS_CTL_SOCK` calling `Ps2::push_*`, + `ci_rollback` as reset.** `SH_CAPTURE=shm`, `SH_INPUT_BACKEND=mamesock`, no X, no QEMU, no kiosk. | the no-window branch (`main.rs:125`), `CaptureRenderer` (`iris-gui/src/framebuffer.rs:56`), `Ps2::push_kb`/`push_mouse_input`, the whole snapshot stack, a ci server already holding `*mut Machine` | ~4 gated commits: install the renderer when there is no window; IFB1 publisher + seqlock; `mamectl/1` listener + keymap; reset/`FBSYNC` verbs | **the `irix`/`nextstep` class, ~68 ms** — the same shm+socket path, with every layer the measurement blamed removed | **`ci_rollback`, ~42 ms in-process** — better than every other station in the fleet; `restore <name>` as the bounded fallback, cold boot (~7 min) as the loud last resort |
| 2 — fallback / first milestone | Iris unpatched under Xvfb **inside an nspawn container**, `SH_CAPTURE=x11` + `SH_INPUT_BACKEND=x11test` (the `medley`/`lisa` shape) | everything — no fork at all; ~1 day | a launcher + `nspawn-inner.sh` + rootfs, copied from `medley` | keeps llvmpipe + the X round trip; strictly better than QEMU+dbus but **nowhere near 68 ms**, and the `irix` station measured the x11 path at **+41 %** over shm ([`irix` `station.env.fixture`](../../streamhost/stations/irix/station.env.fixture) §CAPTURE MODE) | `relaunch` (7 min cold boot) unless the ci socket is also armed | 
| 3 — REJECTED | `--headless` + ci socket + its own frame dump | — | — | — | **`--headless` removes REX3 (`machine.rs:516`): there is no framebuffer to dump.** And the ci socket has no input verb (`ci.rs:254-269`). Dead by inspection. |
| 4 — REJECTED | Swap Iris for another Indy emulator | — | — | — | Rule 6: the golden, the binary and the device set are one combination. MAME's Indy is already the `irix` station and this one exists *because* it is the other emulator ([`indyr4400.md`](../guests/indyr4400.md) §identity table). |

**Recommendation in three sentences.** Fork Iris to `Wnt/iris` and give it the
same three-plane contract `Wnt/previous` already has — IFB1 shm frames,
a `mamectl/1` unix socket, and reset verbs — because `--ci`'s no-window branch,
`iris-gui`'s `CaptureRenderer`, and the public `Ps2::push_kb` /
`push_mouse_input` mean the seams are already cut and streamhost needs **zero**
new code, only env. Take the pointer absolute with a closed loop against Iris's
VC2 hardware-cursor registers, which is the mechanism the sibling `irix` station
already runs against the same IRIX 6.5 X server. And make reset `ci_rollback`
(~42 ms), retiring `loadvm golden` and with it the whole QEMU overlay.

### Pointer: absolute, closed loop, against VC2 — and why that is safe

The station is `rel` today ([`indyr4400.json`](../../registry/stations/indyr4400.json)
`stream.pointer.transport = "rel"`, `spa.pointerRel = true`) because Iris takes
`DeviceEvent::MouseMotion` deltas behind a `CursorGrabMode::Locked` grab. Host-
native, the fork can do better, and the sibling proves the mechanism:

- Iris emulates the VC2 cursor registers: `src/vc2.rs:10` `VC2_REG_CURRENT_CURSOR_X`,
  `:19` `VC2_REG_WORKING_CURSOR_Y`, latched at VBLANK in the refresh loop
  (`src/rex3.rs:4082-4083`).
- `src/compositor.rs:128-129` computes
  `cursor_x_hot = cursor_x_reg - 31 + cursor_x_adjust`,
  `cursor_y_hot = cursor_y_reg - 31` — **the identical `pointer + 31 - hotspot`
  arithmetic** the `irix` station's `mame-vc2-cursor-swap.patch` exploits
  (`MAME_CTL_SWAP_ITEMS=:vc2/0/m_cs_seq,m_cs_dx,m_cs_dy` in
  [`stations/irix/station.env.fixture`](../../streamhost/stations/irix/station.env.fixture)).
- So `MOVEA x y` becomes: read the register, compute the delta, emit paced
  relative counts, re-read, converge — with `MAME_CTL_DEADBAND=1`, the value the
  `irix` station runs *because IRIX's pointer acceleration is 1:1 near zero*.
  That last fact is the reason the loop converges at all; the open-loop warning
  in [`indyr4400.md`](../guests/indyr4400.md) §trap 3 (~3.5x/~3.3x acceleration,
  history-dependent) applies only to open-loop positioning.

**`x11warp` is NOT available here**, and this must not be re-litigated mid-wave:
`streamhost/streamhost/src/x11_warp.rs:15-21` — the sink carries motion only and
declares `EdgeDischarge::VerifiedWarp`; buttons and keys ride a *different*
channel, which on a bridge is QEMU D-Bus PS/2 and on a host-native station does
not exist. That is exactly why `amix` was rolled back to Xvfb on 2026-09-09
([`FSUAE-NATIVE-BRIEF.md`](FSUAE-NATIVE-BRIEF.md) station table). If the VC2
loop fails to converge, the fallback is **stay `rel`** (today's shipped
behaviour, which the browser already drives through Pointer Lock) — not x11warp.

### Two gaps this conversion can close for free

- **Networking.** `src/config.rs:314-320`: `[network] mac = "08:00:69:…"` is
  **backdoor-injected into the emulated NVRAM before boot** precisely so the
  guest needs no `setenv`. That closes
  [`indyr4400.md`](../guests/indyr4400.md) §*Known gaps* — "networking is
  parked… the fix is a one-time PROM step… attempted and **not** landed" —
  with one config line and no PROM keystroke race. `[network] mode = "pcap"`
  (`Cargo.toml` `pcap = ["dep:pcap"]`) bridges the guest's raw frames onto a
  host interface, i.e. the station's retronet tap. **Out of scope for this
  conversion**; note it in the guest doc as the follow-on that makes
  `indyr4400` retronet-capable like its `irix` sibling.
- **Exec channel.** `serial-send` / `wait-serial` / `serial-read` on the ci
  socket (`src/ci.rs:263-265`) replace the two-hop
  ssh-into-kiosk-then-telnet-`iexec.py` path that
  [`guest-agents/irix-iris/README.md`](../../streamhost/guest-agents/irix-iris/README.md)
  itself labels *"NOT durable and NOT wired"*, and sidesteps the single-client
  telnet wedge the perf wave documented.

### Containment: what the operator's rule actually requires here

Iris is an **emulated machine**, not a stock host application: a visitor reaches
an emulated MIPS R4400, not a host process. That puts it in the `nextstep` /
`irix` class, not the `medley` / `lisa` class, and the floor is `nextstep`'s:
**run as an unprivileged account**, which that station needed for a hard reason
(`nextstep.md:49-56`).

Recommended default nevertheless: **nspawn, the `medley`/`lisa` shape**, because
it is a landed 30-minute pattern (`MEDLEY-NSPAWN-WAVE.md` timeline: rootfs at
minute 6, contained and proven by minute 21) and Iris is third-party code that
opens loopback TCP listeners of its own. **The tradeoff to decide before
building it** (see §5): `--private-network` also hides Iris's ci socket peers
and its own NAT gateway from the host — the ci socket is a *unix* socket and
travels fine over a bind, but any TCP-facing plane (the monitor console on
`127.0.0.1:8888`, a future retronet `pcap` bridge) needs the netns designed for
it rather than bolted on later.

---

## 3. Workstreams — five independent streams, each its own `wt.sh` stack

Each stream: `scripts/dev/wt.sh new <name>` (worktree + sandbox + build +
staging slot + claim, AGENTS.md rule 3), work in `/data/vms/sandbox/<name>/repo`,
report a branch, never a merge. Fork work rides **plane branches** merged into
`kernel-hive/integrated` once each is proven on the framebuffer — the
[`FSUAE-NATIVE-BRIEF.md`](FSUAE-NATIVE-BRIEF.md) shape, which is what makes
streams A, C and D independent despite all three touching the fork.

**Walls are raced, not bisected** (rule 14): a stream that hits an unknown
failure spawns one cheap agent per theory on its own
`scripts/dev/rig-clone.sh new indyr4400 <theory>` clone, waits with
`scripts/dev/fb-wait.py --settle/--change` and never `sleep N`, and `keep`s the
winner.

### Shared values — the allocation ledger

**`indyr4400` is an EXISTING live station and keeps every number it has.** No
`wave.sh alloc` is needed for the station identity:

| Value | Held today | Conversion changes it? |
|---|---|---|
| slot / UDP | 136 / 54136 | **no** (`registry/stations/indyr4400.json` `stream.slot`, `udpPort`) |
| VMID label | 239 | **no** — becomes inert bookkeeping (no QEMU) |
| ssh/exec port | 5839 | **retired** — the kiosk it forwarded to is gone; `operator.labctl.exec_kind` becomes the ci socket |
| `SH_X11_DISPLAY` | — | a value is written but **inert** on a `shm` station (`DEBRIDGE-HANDOVER.md:56`). Allocate one only if stream B ships architecture 2 (Xvfb): `scripts/dev/wave.sh alloc indyr4400 --x11warp` |
| rnip / tap / UIN | none | **not in scope** (see §5) |
| container uid base | — | pick a fresh multiple of 2¹⁶ if nspawn ships; `medley` = 1966080, `lisa` = 200000 |

What each stream *does* need, and must claim through `kh-claim`/`$KH_SESSION`
(rule 7): its `wt.sh` **sandbox name** (auto), and — only if it runs a rig — the
rig's own dirs. `rig-clone.sh` clones need **no** claims by design (no UDP port,
no VMID, no display; see its header). The landing window is one lock:
`scripts/dev/wave.sh land begin indyr4400` → … → `land end indyr4400`.

---

### Stream A — fork + build + the frame plane

**Owns:** `github.com/Wnt/iris` branch `kernel-hive/native-video`;
`scripts/build-guests/emulators/build-iris-native.sh` (new);
`registry/release-notes/sources.json` (the fork declaration).

**Do:**
1. Fork `techomancer/iris` @ `0540991` to `Wnt/iris`, branch
   `kernel-hive/native-video` (BSD-3; `LICENSE`).
2. **Trixie host build.** `scripts/build-guests/tiles/indyr4400.sh:215`
   `build_iris_native()` already builds on the host with the host cargo when the
   suite is trixie — reuse it, do **not** reuse `build_iris_chroot`. Trap:
   `rust-toolchain.toml` pins `channel = "nightly"` while labhost has stable
   1.97.0, so the builder must fetch the nightly toolchain (the perf wave
   measured ~19 min cold for two feature sets). `unset CARGO_TARGET_DIR` — the
   box sets a shared one. Feature set: `lightning,rex-jit,chd,jitv2` (jitv2 is
   the measured 4x CPU win and boots IRIX; the `43d2715` wedge is gone).
3. **Commit 1 (gated skeleton):** when there is no window and
   `IRIS_SHM_PATH` is set, install a `Renderer` into `rex3.renderer`
   (`src/rex3.rs:1361`) instead of leaving it `None`. Body = `CaptureRenderer`
   (`iris-gui/src/framebuffer.rs:56-113`) lifted into the main crate. With the
   env unset, behaviour is byte-identical.
4. **Commit 2 (IFB1 publisher):** replace the `FrameSink` write with an mmap of
   `IRIS_SHM_PATH` carrying the 64-byte header
   (`streamhost/streamhost/src/capture/shm.rs:21-44`): magic `IFB1`
   `0x3142_4649`, version 1, width, height, stride, bpp 32, **u64 seqlock at
   +24 going ODD before pixels are touched and EVEN after, release ordering
   both times**, dirty rect at 32..47, pixels at 64. Map
   `CaptureRenderer`'s `dirty_y`/`dirty_h` band onto the dirty rect and set
   `SH_SHM_DAMAGE=0` station-side (the `nextstep` precedent — the producer's
   rect is real, so the daemon must not re-derive one). Re-map on any geometry
   change; the daemon already handles that (`shm.rs:258-268`). Unset knob = loud
   failure, never a fallback (the `MAME_SHM_PATH` rule).
5. **Commit 3:** an `FBSYNC`-equivalent that republishes one whole frame
   unconditionally, for stream D to call after every restore.
6. **Two upstream defects to fix while in here** (both worth a PR to
   `techomancer/iris`): `src/disp.rs:774-790` `save_screenshot` — the
   RCtrl+PrintScreen path — writes the blue byte as the PNG's red channel
   (see §2c; `src/ci.rs:585-590` is the correct encoder), and the refresh loop
   sleeps the frame remainder **twice**
   (`src/rex3.rs:4153-4165`), so a nominal 60 Hz
   (`src/rex3.rs:3928` `from_micros(16667)`) delivers ~30 Hz on a fast host.
7. **Know the idle gate before calling a still frame a bug.** The refresh loop
   only composites when `fb_dirty || palette_dirty || topscan changed ||
   screenshot_pending || frames_since_render >= IDLE_HEARTBEAT_FRAMES` (6)
   — `src/rex3.rs:4015-4029`. An idle desktop legitimately publishes at ~10 Hz.
   `screenshot_pending` forces a render, which is a ready-made "capture now"
   lever. When the FB was not copied, `present()` receives `live_fb_rgb`/
   `live_fb_aux` borrows of real VRAM (`screen.fb_borrowed`, `src/disp.rs:60`)
   — pass them through, do not ignore them.

**Acceptance (framebuffer proofs, never logs):**
- `iris` runs with **no `DISPLAY` set and zero X11 fds** (`ls -l /proc/<pid>/fd`),
  and `scripts/dev/fb-wait.py --out` on the shm file renders the Indigo Magic
  Desktop at the exact emulated geometry.
- The published surface is the **machine, not the emulator**. The HUD is a
  separate texture and cannot leak into `screen.rgba` (§2c), so the remaining
  question is width: publish exactly what VC2 decodes and compare against the
  reject list in [`MIGRATION-WAVE-BRIEF.md:89`](MIGRATION-WAVE-BRIEF.md)
  verbatim — a visible `18.5 MIPS … LED:` row or a 1282x1040 frame is a REJECT.
  If VC2 decodes 1282, decide once whether the publisher crops the 2 overscan
  columns or the registry's geometry moves; do not leave it to the daemon.
- The hardware cursor is present in the published frame
  (`scripts/dev/cursor-locate.py` finds it).
- Tearing: the daemon's own `MAX_TEARS` retry never trips over a 60 s run
  (`shm.rs:80`).

**Rollback:** none needed — nothing on the box; the branch is dropped.

---

### Stream B — station runtime, containment, and the registry conversion

**Owns:** `streamhost/stations/indyr4400/x11-runtime.sh` (new),
`streamhost/stations/indyr4400/nspawn-inner.sh` (new, if nspawn),
`streamhost/stations/indyr4400/station.env.fixture`,
`registry/stations/indyr4400.json`,
`scripts/build-guests/tiles/indyr4400.sh` (asset staging, kiosk removal).
**Does not touch the fork.** Develops against `iris-bookworm-0540991-jitv2`
(already staged in `/data/gallery-guests/IrisIndy/`) until stream A hands over a
binary; the launcher shape does not depend on the fork.

**Template:** [`streamhost/stations/nextstep/x11-runtime.sh`](../../streamhost/stations/nextstep/x11-runtime.sh)
is the closest template in the fleet — host-native, forked emulator, three
planes, unprivileged account, pidfile contract, provenance guard, bounded
fallback. Read its first 110 lines before writing a line. `a3000`'s
`station.env` is the closest **env** template (see below).
`streamhost/stations/medley/x11-runtime.sh` is the nspawn template.

**The env to write** (`station.env.fixture` — the single source; the fixture is
what `streamhost-station.sh` emits, never the live file):

```
SH_STATION=indyr4400
SH_STATION_RUNTIME=x11          # the dispatch marker; there is no X
SH_CAPTURE=shm
SH_SHM_PATH=/data/vms/streamhost/stations/indyr4400/fb.shm
SH_SHM_DAMAGE=0                 # the producer publishes a REAL dirty rect
SH_PORT=54136
SH_FPS=30
SH_INPUT_BACKEND=mamesock
SH_MAMECTL_SOCK=/data/vms/streamhost/stations/indyr4400/ctl.sock
SH_MAMESOCK_KEYMAP=/data/vms/streamhost/stations/indyr4400/indy.keymap
SH_POINTER=abs                  # rel until stream C proves the VC2 loop
SH_AUDIO=off                    # HAL2 unexercised; see §5
SH_KEY_MIN_HOLD_MS=40
SH_KEY_MIN_GAP_MS=40
SH_BTN_MIN_HOLD_MS=...          # stream C measures it
SH_RESET_MODE=relaunch          # the launcher's launch IS a rollback (stream D)
SH_IDLE_PAUSE_PIDFILE=/data/vms/streamhost/stations/indyr4400/mame.pid
SH_IDLE_PAUSE_PROC_MATCH=assets/indyr4400/iris
SH_IDLE_PAUSE_WARMUP_SECS=120
# NO SH_IDLE_PAUSE_SECS override: Iris is the most expensive emulator in the
# lineup (~320-360 % CPU). It takes the fleet default. Never copy the
# amiga/gt40/irix SH_IDLE_PAUSE_SECS=0 stanza onto it.
IRIS_BIN=/data/vms/streamhost/assets/indyr4400/iris
IRIS_SHM_PATH=... IRIS_CTL_SOCK=... IRIS_STATE=golden
```

**Registry constraints the validator enforces** (`scripts/stations_registry/`,
`validate_schema.py:99-111` + `validate_rules.py`), each of which fails the gate
if missed: `runtime.qemu` **must be absent** when `runtime.x11` is present;
`runtime.x11` must carry `display`, `geometry`, `launcher`, `resetMode`, and
`resetMode` must be `relaunch` or `criu`; the env must **not** contain `SH_QMP`;
`SH_STATION_RUNTIME` must be `"x11"`; `SH_CAPTURE` must equal
`runtime.x11.capture`; `SH_X11_DISPLAY` must equal `runtime.x11.display`;
`SH_X11_CMD_FILE` is **required even though nothing reads it** and must be
`/data/vms/streamhost/stations/indyr4400/indyr4400_cmd`; `SH_SHM_PATH` must be
exactly `/data/vms/streamhost/stations/indyr4400/fb.shm`; and if
`stream.pointer.backend` is set the env must carry `SH_INPUT_BACKEND` and must
**not** also carry `SH_POINTER`. Also `runtime.vmidLabel` goes away,
`operator.labctl.qmp` becomes `null` and `console` becomes `x11`, and
`runtime.stationEnv` must not duplicate any key the fixture defines.

**Registry:** `scripts/debridge-convert/registry-to-native.py:110-165` is the
exact surgery — drop `runtime.qemu`, write `runtime.stationEnv` with
`SH_STATION_RUNTIME=x11`, add `runtime.x11 {display, geometry, capture,
launcher, resetMode, emitArgs, auxFiles}`. It hard-codes a keyboard-only pointer
model (`transport: "none"`, `device: "ioport-keyboard"`), which is **wrong for
this station** — indyr4400 has a real pointer. Extend the script or hand-write
`stream.pointer` and `spa.pointerRel`; either way run
`make station-registry-check`. Also: `emulator.version` `1e05210` → the fork pin,
`emulator.source` → the new builder, and `reset.resetMode` `loadvm` → `relaunch`.

**Traps to carry across, from the bridge era:**
- **The re-emit exec-bit trap** ([`indyr4400.md`](../guests/indyr4400.md) §trap 4)
  dies with the QEMU launcher, but the aux-file shape replaces it — `medley`'s
  `nspawn-inner.sh` ships as an emit `--aux-file` (root, 0600) and must be
  `install`ed into `work/` with the container's ownership each launch, because
  the mapped root cannot read a root-owned 0600 file.
- **The winit focus trap** (§trap 1) and **the vmport trap** (§trap 2) both
  vanish: no winit window, no QEMU.
- `--volatile=overlay` refuses `--private-users-ownership=chown`; shift the tree
  once in the builder, `ownership=off` at launch. `--private-users` base must be
  a multiple of 2¹⁶ (`MEDLEY-NSPAWN-WAVE.md` §Walls).
- Bind the asset dir **at its host path** so `/proc/<pid>/exe` reads the same
  from the host and `SH_IDLE_PAUSE_PROC_MATCH` still matches (`lisa.md` §Sandbox).
- **The launcher must be named `x11-runtime.sh`** whatever it runs:
  `streamhost/scripts/ensure-station-x11.sh:35-41` execs that exact name and,
  under `SH_CAPTURE=shm`, proves liveness with `[ -s "$SHM" ]` rather than an X
  socket. Getting the name wrong cold-boots the exhibit on every daemon restart.
- The unit template hard-codes the QEMU hooks
  (`streamhost/deploy/streamhost@.service:24-25`); an x11 station gets the
  drop-in that swaps in `ensure-station-x11.sh` / `stop-station-x11.sh`. Check it
  exists for this station before the first start.
- If audio is ever turned on, the launcher must keep a resident
  `sleep infinity 3<>"$AFIFO"` reader-of-last-resort so the producer's open never
  fails and a daemon restart never delivers SIGPIPE.

**Acceptance:**
- `systemctl start` on a **clone**, never the live station (rule 4): the daemon
  logs real geometry from the mapping and `labctl shot` returns the desktop.
- If nspawn: the `medley` proof set on the rig — host-side namespace audit
  (`/proc/<pid>/ns/*` all differ from PID 1's, `CapEff` without `CAP_SYS_ADMIN`,
  `NoNewPrivs 1`), `ip link` = `lo` only, and the mount test run **with the
  payload's bounding set** (`nsenter … setpriv --nnp --bounding-set -sys_admin,…`),
  not a bare `nsenter`.
- Standby proven: SIGSTOP on `mame.pid` → `/proc/<pid>/stat` state `T`, 0 jiffies
  over 5 s; SIGCONT → `R` and the framebuffer moves again.
- Kill-and-restart proven: SIGCONT→TERM→KILL sweep by `/proc/*/exe` scoped to the
  asset dir leaves **zero** survivors, and the launcher refuses to start if one
  remains (handover §Lessons 7).

**Rollback:** keep `qemu-streamhost.sh` as `qemu-streamhost.sh.debridged-bak`
and `overlay.qcow2` as `overlay.qcow2.debridged-bak` until the operator retires
them; `scripts/debridge-convert/` + [`DEBRIDGE-ROLLBACK.md`](DEBRIDGE-ROLLBACK.md)
is the one-move-each-way procedure. **The launcher and its disk are ONE unit**
(rule 6): roll both back together or neither.

---

### Stream C — input: the `mamectl/1` plane, absolute pointer, keyboard pacing

**Owns:** fork branch `kernel-hive/native-input`;
`streamhost/stations/indyr4400/indy.keymap`;
`scripts/dev/iris-keymap.py` (new, modelled on `scripts/dev/mame-keymap.py`).

**Do:**
1. A `mamectl/1` listener on `IRIS_CTL_SOCK`, speaking the wire **verbatim** so
   streamhost needs no code: banner
   `HELLO mamectl/1 <machine> caps=… screen=WxH`, verbs `MOVEA x y`,
   `DOWN1..3`/`UP1..3`, `KEY <0|1> <port> <field>`, per-verb `<seq> OK|ERR`.
   The daemon-side contract is documented at
   `streamhost/streamhost/src/mame_sock.rs:1-48` — read it: **MOVEA acks on
   accept, edges ack when the edge APPLIES**, move-only targets coalesce
   latest-wins, a fresh MOVEA is restated before every button edge, and on
   reconnect the guest is resynchronised (`UP1..UP3`, `MOVEA`, then `DOWNn` for
   held buttons). A reader thread **enqueues only**; every `push_kb` /
   `push_mouse_input` call happens on the emulation thread's drain, so an OK
   means applied.
2. **Keys:** `KEY <0|1> kbd <winit KeyCode name>` → `Ps2::push_kb`
   (`src/ps2.rs:413`). Generate `indy.keymap` in the `nextstep.keymap` shape
   (80 rows, every one driven through the live socket) and prove **every row**.
3. **Pointer:** the closed VC2 loop of §2 — `MOVEA` reads
   `VC2_REG_CURRENT_CURSOR_X` / `VC2_REG_WORKING_CURSOR_Y` (`src/vc2.rs:10,19`),
   emits paced relative counts through `push_mouse_input`, re-reads, converges
   with a 1-count deadband. Hotspot: the cursor-glyph-swap read the `irix`
   station uses; `src/compositor.rs:30` already carries a `cursor_x_adjust`.
4. **Single-injector rule is BINDING** (`mame_sock.rs:31`): the station must not
   also arm any second motion path.
5. **Wire details the daemon will hold you to.** The first line must literally
   begin `HELLO mamectl/1 ` within 1 s of a 1-s connect
   (`mame_sock.rs:542-561`); lines beginning `EV ` are asynchronous events, not
   acks (`:478-511`); the ack deadline is `5 s + 200 ms x outstanding paced
   verbs` (`:66-76`), a breach drops both queues and reconnects with 50 ms..1 s
   backoff, and **unacked motion is never replayed** (`:580-585`). The reconnect
   preamble is `UP1 UP2 UP3`, `MOVEA <cur>`, then `DOWNn` for each held button
   (`:614-628`). Button bits are `bit0→1 (left)`, `bit2→2 (right)`,
   `bit1→3 (middle)` (`:161-174`); the wheel emits no verb but still restates the
   target. `SH_MAMESOCK_PTR_GRID` stays **unset** — this server states targets in
   screen pixels, as `nextstep` does.
6. **Check the guest actually has its ports on.** A verb that returns OK still
   does nothing if `scanning_enabled`/`mouse_enabled` are false or the i8042 CTR
   disable bits are set (§2c). Read `ps2 status` on the monitor console before
   declaring a dead pointer an emulator bug — and note the *acking* rig will look
   perfectly healthy while nothing moves.

**Acceptance:**
- **Pointer:** `scripts/dev/cursor-locate.py` finds the IRIX arrow at the
  commanded pixel for ≥6 targets, **0 px**, including one after a reset — the
  `nextstep` bar (`nextstep.md` §4). A click on the Toolchest highlights it.
- **Keyboard:** a typed line lands byte-perfect, driven by a **PIPELINED sender
  at zero spacing** — `scripts/dev/key-replay.py`, never an acking client. An
  acking rig typed 26 of 26 while a live station lost nine in ten
  (`DEBRIDGE-CONVERSION-BRIEF.md` §non-matrix guest). Sweep the hold/gap floors
  against the guest, and sweep the button gap against IRIX's own double-click
  verdict the way `nextstep` did (240–440 ms score DOUBLE, 450 ms and up do not).
- **Through the real browser**, not only the socket: an `e2e-live` probe in the
  `tests/e2e-live/nextstep-abs-probe.mjs` shape driving real `page.mouse` and
  `page.keyboard` while a poller reads the arrow out of the shm framebuffer.
  This is also what clears the registry's `reset.mouse`/`reset.keyboard`
  `UNVERIFIED` ([`indyr4400.json`](../../registry/stations/indyr4400.json)).

**Rollback:** the knob unset restores winit input exactly; station-side,
`SH_POINTER=rel` with no `MOVEA` is today's shipped behaviour.

---

### Stream D — reset and checkpoint

**Owns:** fork branch `kernel-hive/native-reset`; the launcher's restore path
(hand back to stream B as a patch, or land after B — the two agree the function
name up front); `scripts/build-guests/irix/iris-golden/` (new bake tooling).

**Do:**
1. Expose `ci_rollback` / `ci_restore <name>` / `save_snapshot <name>`
   (`CHANGELOG.md:68-76`, `src/ci.rs:398-425`) on the `mamectl/1` socket as
   `RESET` / `LOADST` / `SAVEST`, so `SH_RESET_MODE=relaunch` → the launcher →
   an in-process restore, the shape the MAME-native stations run (0.4 s, not a
   16 s service restart).
2. **The provenance triple.** `nextstep.md` §5: the golden records the
   emulator binary's md5 and the launcher **refuses** a restore that does not
   match, because a rebuild orphans every image — golden + binary + device set
   are ONE combination (rule 6). Iris's `snapshot.toml` already carries a
   manifest and a `parent` chain (`CHANGELOG.md:126-138`); add the binary md5 to
   the launcher's own guard regardless.
2b. **Iris already carries most of the provenance.** `snapshot.toml`
   (schema v4) records `iris_git_rev`, `host_arch`, `parent`, the `disks` list,
   `cpu_model` and **the cargo `features` list, which must match on restore**
   (`src/snapshot.rs:26-120`). RAM banks and framebuffers live in a
   content-addressable chunk store at `saves/.cas/` (v3+), so a second snapshot
   of an unchanged machine is nearly free. `ci_restore` also captures the COW
   overlay's dirty-sector set so the running session cannot poison its parent
   (`CHANGELOG.md:77-84`); a `scratch = true` volume deliberately survives
   rollback (`iris.toml:70-72`).
3. **The stale-page trap, guaranteed to bite here.** `nextstep.md` §5.3: a
   restored emulator whose publisher shadow believes the reader is already
   showing the baked frame publishes nothing, and **the reader keeps streaming
   the pre-kill picture forever** under a live guest. Call stream A's `FBSYNC`
   after every restore, unconditionally.
4. **Bounded fallback, loudly.** Two restore launches that never get a verb
   acked → the next launch cold-boots. A cold boot is ~7 minutes here (PROM,
   IRIX autoconfig relink, login) and the `.dirty` COW sidecar is only flushed
   on a clean exit ([`indyr4400.md`](../guests/indyr4400.md) §Checkpoint), so a
   killed emulator redoes the autoconfig — say so in the launcher's log.
5. **Decide the COW overlay.** `src/machine.rs:472` redirects a `overlay=true`
   disk to `/tmp/iris-ci-<pid>-scsiN.overlay` under `ci`. Gate the fork's
   no-window mode on its own knob so the station keeps a deliberate,
   station-local overlay path and the 6.3 GB read-only asset is never dirtied
   (the ext4-wrapper reasoning in [`indyr4400.md`](../guests/indyr4400.md)
   §*Why an ext4 wrapper* still holds: `src/scsi.rs` sizes a disk with
   `File::metadata().len()`, which is 0 for a block device).

**Acceptance:**
- **Two captures either side of a dirtying run are byte-identical** and the
  dirtied frame differs — the same md5 proof the bridge checkpoint passed
  ([`indyr4400.md`](../guests/indyr4400.md) §Checkpoint), now taken off the shm
  file instead of `screendump`.
- A `MOVEA`/click is acked **by the emulation thread** immediately after a
  restore (an ack proves the restored MIPS is running its queue, not merely that
  a process exists — `nextstep.md` §5).
- Restore wall-clock measured and recorded against the 7-minute cold boot.
- Declare `resetMode: relaunch`, not `criu`. `criu` is a legal schema value
  (`validate_rules.py:516-517`, requires `reset.snapshot: "golden"`) but **zero
  stations use it** — even `nextstep`, whose reset *is* a CRIU restore, declares
  `relaunch` and hides the restore inside the launcher. Follow that.
- `checkpoint-guard` is **not** extended: `docs/lab/checkpoint-guard.md:262-282`
  covers QEMU vmstate stations only and refuses savestate runtimes loudly by
  design. Say in the guest doc that this station leaves the guard's scope, and
  follow the shape that doc names for savestate paths — *write the new state
  under a temp name, prove it, then `mv` it over the old one*.

**Rollback:** `IRIS_STATE=` (empty) forces a cold boot, exactly as
`IRIX_STATE=` does on the `irix` station.

---

### Stream E — landing, docs, and the fleet surfaces

**Owns:** `docs/guests/indyr4400.md`, `docs/lab/IRIS-DEBRIDGE-BRIEF.md` (this
file, kept as the design record + measured results, the FS-UAE convention),
`registry/bridge-suites.json` `_notes`, `registry/release-notes/facts/<date>/indyr4400.md`,
`README.md` re-render. **Runs last, but its inputs are collected from day one.**

**Do:**
- Rewrite the guest doc as a living document, not an annex: the four bridge
  traps become history, the pointer section is rewritten, the checkpoint section
  is rewritten, `Measured cost` is re-measured host-native. Docs are living —
  rewrite, never append a contradicting annex.
- `registry/bridge-suites.json`: **keep the `.tiles` row, add the `_notes`
  entry.** An earlier draft of this brief said to remove the id from `.tiles`;
  the nine converted MAME kiosks show that is not what a conversion does — all
  nine (`mpf2 kc854 dragon32 bbcmicro armeval zx81 oricatmos zxspectrum
  sinclairql`) are still listed under `.tiles` and each carries a `_notes` line
  reading `HOST-NATIVE (de-bridged …)`. The tier flip does not need the removal:
  `scripts/stations_registry/fleet_table.py:_tier` tests
  `SH_STATION_RUNTIME=x11` **before** the ledger, and says so in its own module
  docstring — *"the ledger still lists the de-bridged stations, so it is not a
  kiosk oracle on its own."* So Tier 2 → Tier 3 follows from stream B's registry
  row alone, and the `_notes` line is the bookkeeping. This also retires one of
  the last bookworm ABI chroot customers (`DEBRIDGE-HANDOVER.md:33`).
- The `/fleet` table needs `emulator{}` + `ui` kind to stay honest
  (`scripts/stations_registry/fleet_table.py`).
- **The poster is untouched.** Identity does not change: same registry id, same
  `stationDir`, same slot, same archetype, same poster, same scene
  (`DEBRIDGE-CONVERSION-BRIEF.md` §1).
- Release-notes facts go to `facts/<end-date>/indyr4400.md`, never the week JSON;
  release notes ship via an **SPA deploy**, not a box-deploy pair row.

**Acceptance:** `make station-registry-check` green; `scripts/dev/stage.sh`
preview of the `/fleet` row and the station page before it is live; the gate for
every language touched (`docs/lab/AGENT-CI-EXIT-RULE.md`) or **BLOCKED** with
the failing command and output.

**Rollback:** documentation only.

---

## 4. Integration order, and the one review

```
        A (fork: build + frames)
        │
   ┌────┴────┬──────────┐
   C (input) D (reset)  B (station runtime + registry)   ← B starts immediately,
   │         │          │                                  against the STAGED
   └────┬────┴──────────┘                                  0540991-jitv2 binary
        ▼
   merge plane branches → Wnt/iris `kernel-hive/integrated`, pin in the builder
        ▼
   ONE review pass (Opus): the merged fork + the launcher + the registry, read
   together — this is the only place the three planes are seen at once
        ▼
   E (landing): scripts/dev/wave.sh land begin indyr4400
                scripts/dev/station-land.sh indyr4400   (--dry-run first)
                scripts/dev/wave.sh land end indyr4400
```

- **A is the only hard prerequisite** — C and D both need a running no-window
  Iris to prove anything on a rig, and A's commit 1 is a day's work. B is
  independent from minute one.
- Streams meet **only** at the fork merge and the single review. No fix-agent,
  no second review pass (right-size the workflow: 3–6 agents, one review).
- **A push is not a deploy** (rule 11): `git push origin main`, then
  `scripts/dev/box-deploy.sh --apply`; the restart is a separate decision, and
  [`FLEET-ROLLOUT.md`](FLEET-ROLLOUT.md) is how the fleet restarts without
  taking the gallery down.
- **Never `box-deploy` while a station agent is mid-flight** — it clobbers live
  agent edits.
- The station is **live and active right now** (`labctl ls`: `indyr4400 … active`),
  so the cutover is a real outage window, not a bring-up. Do it inside the
  landing lock with the rollback pair already parked.

**Model sizing** (rule 12): A, C and D are fork implementation from proven facts
with a real failure surface — **Opus** each, as briefed. B is bounded
implementation copying two proven launchers — **Opus or `sonnet`**. E is prose
in the museum's voice plus mechanical regeneration — **Opus for the guest doc,
`haiku-low` for the re-renders and ledger rows**. Race any wall with cheap
runners on `rig-clone.sh` clones.

---

## 5. Open questions for the operator (4, each with a recommended default)

1. **Containment shape.** Iris is an emulated machine, so `nextstep`'s
   unprivileged account is the floor and the `medley`/`lisa` nspawn rule does not
   strictly bind. nspawn costs ~30 minutes and complicates any future TCP-facing
   plane (`--private-network` hides Iris's own listeners from the host).
   **No landed station does both nspawn and shm** — `medley`/`lisa` are nspawn
   with x11 capture, `nextstep`/`a3000` are shm with no container. This
   combination is new ground: the binds become `$SH_SHM_PATH`,
   `$SH_MAMECTL_SOCK` and `$SH_AUDIO_FIFO` instead of an X socket directory.
   **Recommended default: nspawn**, designed with the netns and those three
   binds up front, on the grounds that Iris is third-party code that opens
   loopback listeners of its own and the container pattern is already landed
   twice — but budget it as a stream-B risk, not a copy-paste.
2. **Pointer target.** Absolute via the closed VC2 loop (matching the `irix`
   sibling, and the only way to clear the `relativePointerOnly` badge), or keep
   `rel` and ship the latency fix alone? Absolute is stream C's whole cost.
   **Recommended default: attempt absolute, ship `rel` if the loop does not
   converge in one bake** — the latency win does not depend on it, and `rel`
   already works.
3. **Retronet.** `[network] mac` + `mode = "pcap"` would give `indyr4400` the web
   plane and an IM client its `irix` sibling already has, closing the station's
   documented "networking is parked" gap. It is a separate device-set change and
   a separate golden.
   **Recommended default: out of scope for this conversion**, recorded in the
   guest doc as the next wave — a conversion that also changes the network is two
   changes sharing one rollback.
4. **Audio.** The station is `--noaudio` today and IRIX HAL2 through Iris is
   untested. The FIFO precedent exists (`SH_AUDIO_SOURCE=fifo`, s16le/48k stereo,
   *the daemon is the clock*, `streamhost/streamhost/src/audio.rs:194-236`) —
   and the VICE wave's lesson is that a blocking audio sink on the emulation
   thread becomes the clock and costs 76 % of the machine's speed.
   **Recommended default: stay `SH_AUDIO=off`.**

---

## 6. What could not be verified in this session

- **Whether `--ci`'s "speed-favoring fidelity shortcuts" are acceptable for an
  exhibit.** `src/config.rs:1376-1379` advertises them; the only two found by
  inspection are the CI serial backend (`src/machine.rs:321,328`) and the
  `/tmp` COW overlay redirect (`:472`). The fork should gate on its own knobs
  rather than on `--ci` — which sidesteps the question — but a reader of
  `Machine::new` should confirm there is no third.
- **Whether `SwCompositor` alone keeps up at 1280x1024 without a GL context.**
  `CaptureRenderer` is `iris-gui`'s *default* path and `GlCaptureRenderer` is
  the opt-in (`IRIS_GUI_GL=1`), which is suggestive but not measured here. If it
  does not, `HeadlessGl` (`src/headless_gl.rs`) provides a hidden 1×1 GL surface
  — but that reintroduces an X/EGL dependency and would need the netns designed
  for it. **Measure this on a rig before committing to the SW path.**
- **The exact emulated width after conversion.** Half of this is now answered:
  the 16-row HUD is a separate GL texture and cannot appear in `screen.rgba`
  (§2c), so only the 2 overscan columns are open — the visible rect is whatever
  VC2 decodes, and `1282x1024` is a decoded value seen in Iris's own logs, not a
  constant. Measure it on a rig and decide the crop once. The reject criteria are
  unchanged and non-negotiable
  ([`MIGRATION-WAVE-BRIEF.md:89`](MIGRATION-WAVE-BRIEF.md)).
- **Host-native CPU cost.** The bridge measured `iris` at ~320 % (interp) /
  ~360 % (jitv2) plus ~150 % for the station QEMU. Deleting QEMU should bank
  roughly that 150 %, in line with the spike's "host-native costs 69 % of a
  kiosk" ([`DEBRIDGE-CONVERSION-BRIEF.md`](DEBRIDGE-CONVERSION-BRIEF.md)), but
  it is an inference here, not a measurement.
- **Whether the box can build the pinned nightly offline.** `rust-toolchain.toml`
  says `channel = "nightly"` with no date pin, so the builder fetches whatever
  nightly is current — a moving input under rule 6, where the binary is half of
  every checkpoint. Stream A should pin a dated nightly on the fork and record
  it, rather than inherit `nightly`.
- **Host-native frame rate.** The double-sleep (§Stream A commit 6) means the
  measured ~30 Hz is an emulator artifact, not a capture limit; whether fixing it
  costs CPU on an already-expensive emulator is unmeasured.

---

## 7. Landing record

Filled 2026-09-10 by the integration pass. Every number below was taken on a rig
under `/data/vms/sandbox/iris-int/`, never on the live station, against the
INTEGRATED binary (`Wnt/iris@kh-native` with the reset plane merged) and the
integrated launcher inside its nspawn container. Frames were read out of the
published IFB1 mapping with the daemon's own reader (`scripts/shmshot.py`);
waits were `fb-wait.py --shm`, never a sleep.

**Where the frames are.** `/data/vms/sandbox/iris-int/rig/proof/` — 41 files, and
the load-bearing ones are `01` (the IRIX autoconfig relink console), `03` (the
visual login panel), `11` (the `demos` session), `21`/`23` (the Toolchest menu,
black), `30`-`34` (the golden scene, dirtied, and the three byte-identical
restores) and `41` (the frame after `kill -9` and a cold start). The rig itself
is torn down; the frames are not committed because the repo is public and they
are 1280x1024 captures of a licensed IRIX install.

### The three planes, as built

| Plane | Contract | Where it landed | Proof |
|---|---|---|---|
| Frames | IFB1 shm at `IRIS_SHM_PATH`, cropped by `IRIS_SHM_GEOMETRY`, producer damage, `SH_SHM_DAMAGE` at the daemon default | `src/shmpub.rs` (stream A) | first frame **19 s** after launch; the IRIX autoconfig console, the visual login panel and the `demos` desktop all published at **1280x1024**, mapping exactly `5 242 944` bytes; `rig/proof/01,03,11` |
| Input | `mamectl/1` on `IRIS_CTL_SOCK`, single injector | `src/ctlsock.rs` (stream C) | **8/8 targets with the glyph on the commanded pixel, 0 px**, on the shipped defaults; 102/102 keymap rows acked through the live socket; `demos` typed pipelined at zero spacing (10 edges, 375 ms) logged in; `DOWN1` opened a Toolchest menu |
| Audio | none — `SH_AUDIO=off` by decision (§5 q4) | — | — |
| Reset | `SAVEST`/`LOADST`/`RESET` on THAT SAME socket | `src/kh_ctl.rs` (stream D), merged into ctlsock 2026-09-10 | three restores **byte-identical** to the captured scene with a dirtied frame between them, input live 5 ms after; `kill -9` + a fresh process restored the same frame with **zero** differing pixels |
| Exec | none — `IRIS_CI_SOCK` empty | — | arming it published **no frame in ten minutes at ~200 % CPU**; see §6 |

### Numbers this conversion claimed, and what it actually got

| | Bridge, measured 2026-09-09 | Host-native, measured 2026-09-10 |
|---|---|---|
| one pointer move → framebuffer, median | 361 ms (`1e05210`), 285 ms (`0540991` interp), 383 ms (jitv2) | **80 ms** (n=12, 76–112) |
| pointer stream (60 events @ 20 ms), lag after last event | 216 / 224 / 397 ms | **60 ms** (n=3, 59–64) |
| absolute pointer accuracy | none — the station shipped `rel` | **8/8 targets at 0 px**, convergence median 246 ms |
| fixed CPU work, host wall clock | 8.4 s / 8.1–10.2 s / 1.95 s | **not re-measured** — the channel that measured it was the kiosk's SCC telnet, which is gone, and the binary and feature set are unchanged from the 1.95 s jitv2 row |
| `iris` CPU, idle desktop | 320 % interp, 360 % jitv2 | **325 %** (RSS 812 MB) |
| station QEMU CPU | ~150 % | **0 — there is no QEMU** |
| reset wall clock | `loadvm golden`, never timed | **387 ms** `RESET`, **536 ms** `LOADST` via rollback, **1 274 ms** from disk, **2 035 ms** `SAVEST`; against a ~5 min cold boot |
| `kill -9` → live restored station | — | **10.9 s** |
| checkpoint on disk | `overlay.qcow2` 702 MB + 1.1 GiB vmstate | **9.2 MB** per snapshot + **124 MB** shared CAS |
| published frame rate | ~30 Hz | **25.7 Hz** under a sweeping cursor, **0.1 Hz** idle |
| emulated width actually published | 1282 decoded, clipped to 1280 by the X root | **1282 decoded** (`cursor_x_adjust=5`), **1280 published** — cropped in the publisher, by `IRIS_SHM_GEOMETRY`, from `IRIS_GEOM` |
| cold boot to the visual login | ~7 min | **~5 min** |
| build | chroot, ~19 min cold for two feature sets | trixie host build, **8 m 00 s** cold / **5 m 05 s** incremental |

Read the pointer row against the goal, which was the `irix`/`nextstep` class at
~68 ms: **80 ms**, a 4.5x improvement on the live station, and the remainder is
the emulator's own ~30 Hz composite cadence rather than anything the conversion
added.

### Decisions taken, with the evidence

| Question (§5) | Decision | Taken by | Evidence |
|---|---|---|---|
| Containment shape | **nspawn**, and it is the lineup's first nspawn + `shm` station | stream B, integration-proven | the namespace audit in [`../guests/indyr4400.md`](../guests/indyr4400.md) §Containment; three writable binds and nothing else |
| Pointer: absolute or `rel` | **absolute**, `iris-vc2-closedloop` | stream C, integration-proven | 8/8 targets at 0 px on the shipped defaults, VC2 register exact at all eight |
| Retronet | out of scope for this conversion | this brief | §5 q3 — a conversion that also changes the network is two changes sharing one rollback |
| Audio | stay `SH_AUDIO=off` | this brief | §5 q4 — the VICE wave's blocking-sink lesson |
| Iris's ci exec socket | **off** | integration | arming it costs the frame plane entirely (measured; §6) |
| One socket or two | **one** — the reset verbs join the input listener | integration | `mame_sock.rs` gives a station exactly one `SH_MAMECTL_SOCK`, and `reset-tile.sh` sends `LOADST golden` down it |

### Walls, raced

| Wall | Theories | How it was settled | Cost |
|---|---|---|---|
| No frame published in 10 minutes at ~200 % CPU on the first integrated launch | (a) the merged fork broke the publisher; (b) `--ci-socket` costs the frame plane even without `--ci`; (c) the container's binds | ONE decisive test rather than a bisect — the only variable that differs from stream B's proven configuration is `IRIS_CI_SOCK`, so it was emptied: **first frame in 19 s**. (b). | ~25 min |
| `0/7` targets and a 655 px bounding box on the first pointer measurement | (a) the pointer really is off; (b) the plate was contaminated | The engine's own `EV MOVEA` reported the commanded pixel every time while the bbox did not, so the frame was the suspect, not the pointer: re-measured against a plate inside a ±48 px window → **8/8 at 0 px**. | ~10 min |
| 6.2 Hz published frame rate, matching the known "cursor-only moves do not mark the framebuffer dirty" suspicion | (a) the refresh gate; (b) the measurement | `Vc2::write_reg` does set the dirty flag and `should_render` consumes it, so the gate was exonerated by reading it; the oscillating ±4 px test was putting the cursor back where it started. Monotonic sweep → **25.7 Hz**. **No change to the refresh gate.** | ~10 min |

### Timeline

Measured from git and box timestamps.

| | |
|---|---|
| fork merge committed (`Wnt/iris@kh-native`) | 8cbb689 |
| first integrated build, trixie | 8 m 00 s |
| rig cold boot → IRIX visual login | ~5 min |
| login → `demos` desktop | ~90 s |
| full proof run (pointer, click, reset, kill -9, latency, CPU, frame rate) | ~50 min of wall clock, most of it IRIX booting |

### What is NOT proven, and is the operator's to close

1. **The golden's CONTENT.** A cold boot reaches the `demos` session's Toolchest
   and a console window and stops there — no icon column, unchanged over ten
   minutes of polling. The fixture and the reject criteria both describe the
   icon column, so the bake step in the cutover runbook needs a person, and
   what the session is waiting on is undiagnosed. Every mechanism here is
   content-agnostic; this is a scene, not a design.
2. **The browser leg.** `reset.mouse` / `reset.keyboard` stay `UNVERIFIED`:
   proven on the framebuffer, not yet through the real SPA.
3. **A 4Dwm popup menu composites black** — Iris's own gap, on the windowed path
   too (same `compose_pixels`), and visitor-visible.

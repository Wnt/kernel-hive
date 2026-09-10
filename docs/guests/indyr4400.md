# SGI Indy, MIPS R4400 — IRIX 6.5 under Iris (`indyr4400` station)

The gallery's **second** SGI Indy, and the only station running
[Iris](https://github.com/techomancer/iris) (BSD-3), a userspace Rust emulator
of the Indy. It is a deliberate pair with the [`irix`](irix.md) station rather
than a duplicate of it — same machine, same install, two independently written
emulators:

| | `irix` | `indyr4400` |
|---|---|---|
| Machine | SGI Indy, **MIPS R4600** @ 100 MHz | SGI Indy, **MIPS R4400** |
| Emulator | MAME `indy_4610` | Iris (`Wnt/iris`, a fork of `techomancer/iris`) |
| Launcher | **x11 launcher, BARE METAL** — MAME's Indy emulation kernel-panics under a KVM vCPU | **x11 launcher, host-native** — Iris is pure userspace and never had that constraint either |
| Capture | `SH_CAPTURE=shm`, 1288x1024 emulated framebuffer | `SH_CAPTURE=shm`, IFB1 published by Iris itself |
| Input | `mamesock` → MAME ioport | `mamesock` → Iris `Ps2::push_kb` / `push_mouse_input` |
| Reset | `relaunch` (+ a captured MAME savestate) | `relaunch` (+ Iris's in-process `ci_rollback`) |

Both run the same IRIX 6.5.22 install — this station's disk is literally derived
from the `irix` station's seed CHD (see *Media* below). What differs is the chip
and the emulator, which is the exhibit.

Until 2026-09 the two were also a **tier**-contrast pair: `irix` host-native,
`indyr4400` inside a Debian kiosk. That difference is gone; the conversion and
the measurement that forced it are in
[`../lab/IRIS-DEBRIDGE-BRIEF.md`](../lab/IRIS-DEBRIDGE-BRIEF.md) and in
*The measurement that started the conversion* below.

## Status

**Live production station** (added 2026-08-10, converted to host-native 2026-09).
Slot 136, UDP 54136, archetype `beige-tower-crt`. VMID label 239 survives as
inert bookkeeping — there is no QEMU. The ssh/exec port 5839 is **retired**: it
forwarded into the kiosk, and the kiosk is gone.

> **Reading this before the conversion lands?** The host-native design below is
> what the station becomes; `scripts/dev/box-deploy.sh --status` and
> `ssh lab 'labctl ls'` are the authority on what is running right now. The
> bridge-era facts that stayed true are kept in place below rather than in an
> annex — [§*What the bridge era cost*](#what-the-bridge-era-cost).

## Acceptance criteria

- Iris fork `Wnt/iris`, branch pinned in the builder, features
  `lightning,rex-jit,chd,jitv2`, BSD-3. The upstream base is `0540991`.
- IRIX 6.5.22, MIPS R4400, 256 MB (`banks = [128, 128, 0, 0]`), XL 24-bit.
- **No QEMU, no QMP, no guest Debian, no X server.** `iris` runs on the host
  with no `DISPLAY` set and zero X11 fds (`ls -l /proc/<pid>/fd`) — the same
  proof the nine converted MAME kiosks pass.
- Framebuffer proof: the Indigo Magic Desktop (4Dwm) with the Toolchest docked
  top-left and the `demos` icons down the right edge, **and no Iris HUD**.
- Reset: `SH_RESET_MODE=relaunch`, resolved inside the launcher to Iris's own
  in-process rollback.
- Pointer: **absolute** if stream C's closed VC2 loop converges, **relative**
  (Pointer Lock) if it does not — `rel` is today's shipped behaviour and a
  legitimate landing state, not a failure.
- Login: `demos`, no password (see also `root`, empty password, from the
  `irix` station — the same install).

## Media and provenance

The IRIX disk is **not** a new download. It is this lab's own
`irix65-apps.chd` (the `irix` station's seed) extracted with
`chdman extracthd` from a **copy**, then wrapped in a read-only ext4 image so
Iris can open it as a regular file:

```
/data/gallery-guests/IrisIndy/irix65-r4400-disk.ext4   6500 MiB apparent, ~500 MiB allocated
  └── disk.raw   6,291,456,000 bytes
       sha256 b8214c34a2983ce9f2b0781ef56a7a71971da2e3dbcb87cc7f1f990f822b1c61
```

Preservation-class; **never committed** (the repo is public). Staged and
verified by `streamhost/stations/indyr4400/fetch-assets.sh`; recorded in
[`../lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md).

### Why an ext4 wrapper and not the bare raw disk

This reason **survives the conversion** and is why the wrapper is still there
with no VM around it. Iris sizes a SCSI disk with `File::metadata().len()`
(`src/scsi.rs`), which is **0 for a block device**, so it cannot be pointed at a
device node — the read-only asset has to present a regular FILE. Host-native the
wrapper is mounted read-only on the host and `disk.raw` inside it is Iris's
`[disk]` path; Iris runs with `overlay = true`, so its copy-on-write file and
its `.dirty` sidecar land in a **station-local** overlay path, and the 6.3 GB
asset can never be dirtied.

One trap to carry forward: under `--ci`, `src/machine.rs` redirects an
`overlay = true` device's COW file to `/tmp/iris-ci-<pid>-scsiN.overlay`, a
throwaway per-pid path. The fork gates its no-window frame and input planes on
their own knobs precisely so the station is **not** in `--ci` mode and keeps a
deliberate, station-local, surviving overlay.

## Build

`scripts/build-guests/tiles/indyr4400.sh` stages the asset and installs the
binary. There is no overlay to build.

### The binary is a host build now, not a chroot build

The bookworm ABI chroot is gone. Host and target are both labhost, both Debian
13 (trixie, glibc 2.41), so the builder uses the host cargo — the tile script's
`build_iris_native()` path, never `build_iris_chroot()`.

Two traps that outlived the chroot:

- Iris's `rust-toolchain.toml` pins `channel = "nightly"` with **no date**, and
  labhost's stable is 1.97.0. The builder fetches the nightly toolchain. A
  floating nightly is a moving input under rule 6, where the binary is half of
  every checkpoint, so **the fork pins a dated nightly and records it**.
- **`CARGO_TARGET_DIR` must be SET, not unset** — and this is backwards from
  what it looks like. `/root/.cargo/config.toml` on the box puts `[build]
  target-dir` in the shared streamhost tree, and a config value applies
  precisely when the env var is ABSENT. So `unset CARGO_TARGET_DIR` hands the
  build to the shared tree and then installs from `./target/release/iris`, a
  path that does not exist. The builder sets it to its own work dir.

Measured build cost, on labhost (trixie, `nice -n 19 cargo build --release -j 4`,
features `lightning,rex-jit,chd,jitv2`, toolchain already resident): **8 m 00 s**
cold, **5 m 05 s** for an incremental rebuild after a source change (2026-09-10).
For scale, the bridge-era chroot build was 6 m 30 s for one feature set plus a
debootstrap, and the 2026-09-09 perf wave paid ~19 min cold for two feature sets
including the toolchain fetch. The chroot is gone with the kiosk.

## Design: the three planes

The station is the `nextstep` shape — a forked emulator that publishes frames,
speaks `mamectl/1`, and resets in-process. streamhost gets **no new code**; the
whole station is env.

### Frames — IFB1 shared memory, published by Iris

Iris already had every piece: `--ci` (without `--ci-display`) is a no-window
mode that keeps REX3 alive, and `iris-gui` already carries a `CaptureRenderer`
driving the CPU `SwCompositor`. The one hole upstream is that
`rex3.renderer` is installed at exactly one place — the windowed path — so under
`--ci` it stays `None` and `iris-ci screenshot` writes a black PNG. The fork
installs the renderer on the no-window branch and has its `present()` write the
IFB1 header and pixels directly.

Two consequences worth knowing before you read a frame:

- **The pixel format needs no conversion.** The compositor's final store is
  `0xFFRRGGBB`, i.e. B,G,R,X in little-endian memory — byte-identical to
  IFB1/BGRA, the same as MAME's `bitmap_rgb32`. At 1280x1024 that saves a
  1.3 M-pixel swap pass every frame. Two things in Iris's tree contradict this
  and are **wrong, not evidence**: `src/disp.rs`'s `rgba` comment and
  `save_screenshot` beneath it, which pushes the blue byte as the PNG's red
  channel. The RCtrl+PrintScreen screenshot has red and blue swapped;
  `src/ci.rs`'s encoder is the correct one. IRIX's 4Dwm desktop is teal, so a
  swap turns it orange — unmissable on the first published frame.
- **An idle desktop legitimately publishes at ~10 Hz.** The refresh loop
  composites only on `fb_dirty || palette_dirty || topscan changed ||
  screenshot_pending || frames_since_render >= 6`. A still frame is the idle
  gate, not a bug.

**The HUD problem is gone.** Iris's 16-row status bar (`18.5 MIPS … LED:`) is a
**separate 2048x16 texture** composited as its own pass, not part of
`screen.rgba`. Host-native it simply does not exist in the published frame — so
the bridge's X-root clipping hack, which pinned the root to 1280x1024+0+0 to
crop the HUD off, has nothing left to do and is deleted. The reject criteria in
[`../lab/MIGRATION-WAVE-BRIEF.md`](../lab/MIGRATION-WAVE-BRIEF.md) are unchanged
and still non-negotiable: a visible HUD row means the visitor is looking at the
emulator instead of the machine.

Geometry: the framebuffer is 2048x1024 words, stride 2048, with the visible
sub-rect decoded from VC2 timings — `1282` is a **decoded value, not a
literal**. Measured on the integration rig 2026-09-10, from Iris's own log:

```
Rex3: Resolution changed to 1282x1024 cursor_x_adjust=5
iris: shm first geometry 1280x1024 (stride 5120)
```

**Published geometry is 1280x1024, pinned, and the crop is decided in the
publisher.** `IRIS_SHM_GEOMETRY=1280x1024` — set by the launcher from
`IRIS_GEOM`, never separately — drops the 2 columns VC2 decodes beyond the
nominal width. They are real right-edge overscan, not black padding. The
consumer has no crop knob, so the decision cannot live on the daemon's side; and
because the same `IRIS_GEOM` also feeds `IRIS_CTL_SCREEN`, the rectangle the
publisher writes, the surface the browser clamps a pointer to and the geometry
the registry declares cannot drift apart. The mapping is `64 + 1280*1024*4 =
5 242 944` bytes, which is the check: a station publishing 1282 would be
5 251 136.

### Input — `mamectl/1`, spoken verbatim

The fork opens a unix socket and speaks the same wire the MAME and Previous
stations speak, so `SH_INPUT_BACKEND=mamesock` is the whole station-side story:
`MOVEA x y`, `DOWN1..3`/`UP1..3`, `KEY <0|1> <port> <field>`, per-verb
`<seq> OK|ERR`. Verbs land on `Ps2::push_kb` and `Ps2::push_mouse_input`, both
already public and already driven from a non-winit event source in `iris-gui`.

Keys are `winit::keyboard::KeyCode` names passed straight through with no layout
translation — the guest applies its own `keybd=` layout — so
`streamhost/stations/indyr4400/indy.keymap` (port `kbd`, field = a KeyCode name)
is the whole keyboard mapping.

**Both push functions drop input silently behind guest-state gates.** `push_kb`
returns early unless `running && scanning_enabled && !(config & 0x10)`;
`push_mouse_input` unless `running && mouse_enabled && !(config & 0x20)`. Those
are the i8042 AUX/KBD port toggles, and IRIX probes them. A backend injecting
before the guest has enabled the port sees nothing happen **and no error** — and
an acking test rig looks perfectly healthy the whole time. Read `ps2 status` on
the monitor console before calling a dead pointer an emulator bug.

Deltas clamp to ±256 per packet and packets coalesce into the tail once 8 are
pending, so a burst of small moves can merge: any closed loop must **read back,
not count what it sent**.

Pacing floors: `SH_KEY_MIN_HOLD_MS` / `SH_KEY_MIN_GAP_MS` are 40/40 in the
fixture, and on this path the daemon's own gate does not run — the launcher
derives the emulator module's floors from them. Measured floors against IRIX,
and `SH_BTN_MIN_HOLD_MS`: 40/40 holds. Measured on the integration rig
2026-09-10 with a **pipelined** sender — one `write()` of every edge at zero
spacing, never an acking client, which paces the edges for you and hides the bug
perfectly. `demos` typed at the IRIX visual login: **10 edges, 10 acked, 375 ms**
(= 5 characters x 40/40), and the login went through. All **102 keymap rows
driven through the live socket, 0 rejected**. `SH_BTN_MIN_HOLD_MS=60` is still a
floor rather than a measurement — no double-click sweep against IRIX's own
verdict has been taken.

**Do not sweep the keymap into a live desktop.** Driving all 102 rows as real
press/release pairs at the 4Dwm desktop logged the `demos` session out on the
integration rig — 102 rows include Escape, the function keys and every modifier,
and a desktop is a program that reacts to them. Sweep at the login panel, or use
`KEYDUMP`, which needs no guest at all and is why the generator can verify the
map before the machine boots.

## Pointer

The bridge shipped **relative by design**: Iris took `DeviceEvent::MouseMotion`
deltas behind a `CursorGrabMode::Locked` grab, Right-Ctrl released it, and the
SPA drove it through Pointer Lock. Host-native there is no winit window and no
grab, so the transport is a decision rather than a constraint.

**The target is absolute, via a closed loop against Iris's VC2 cursor
registers** — the same mechanism the `irix` sibling already runs against the
same IRIX 6.5 X server. Iris emulates `VC2_REG_CURRENT_CURSOR_X` /
`VC2_REG_WORKING_CURSOR_Y`, latched at VBLANK, and its compositor computes
`cursor_x_hot = cursor_x_reg - 31 + cursor_x_adjust` — the identical
`pointer + 31 - hotspot` arithmetic the `irix` station's VC2 cursor-swap patch
exploits. So `MOVEA x y` reads the register, emits paced relative counts,
re-reads and converges with a 1-count deadband, which works **because IRIX's
pointer acceleration is 1:1 near zero**.

That last fact is also the boundary of the old warning: IRIX's ~3.5x horizontal
/ ~3.3x vertical acceleration is history-dependent and does **not** converge
open-loop. That applies to open-loop positioning only, and is why the loop is
closed.

**`x11warp` is not available here and this must not be re-litigated.** The
x11warp sink carries motion only and declares `EdgeDischarge::VerifiedWarp`;
buttons and keys ride a different channel, which on a host-native station does
not exist. The daemon runs **one** input backend per station and does not
compose x11warp motion with ctlsock edges — that is exactly why `amix` was
rolled back on 2026-09-09. If the VC2 loop does not converge, the fallback is
**stay `rel`**, not x11warp.

**Landed: absolute, and it converges on the shipped defaults.** Measured on the
integration rig 2026-09-10, at the `demos` session's 4Dwm desktop, with no hand
offsets anywhere — `IRIS_CTL_CAL_X/_Y = -31`, deadband 1, and the compositor's
own `cursor_x_adjust = 5` read once and cached:

| target | glyph origin in the published frame | delta | rounds |
|---|---|---|---|
| 300,200 | 300,200 | **0,0** | 8 |
| 980,760 | 980,760 | **0,0** | 16 |
| 64,900 | 64,900 | **0,0** | 6 |
| 640,512 | 640,512 | **0,0** | 5 |
| 1200,140 | 1200,140 | **0,0** | 5 |
| 500,500 | 500,500 | **0,0** | 6 |
| 880,300 | 880,300 | **0,0** | 4 |
| 120,60 | 120,60 | **0,0** | 6 |

**8 of 8 at 0 px**, and the VC2 register read back the commanded pixel exactly at
all eight. Convergence median 246 ms, max 653 ms. The glyph was located by
differencing each frame against a plate inside a ±48 px window around the
commanded pixel, which is what makes the answer immune to the rest of the screen
repainting — the first attempt at this measurement was ruined by a desktop that
was still painting, and reported 0/7 with a bounding box 655 px wide.

Button edges land too: `DOWN1` on the Toolchest's *System* entry raised it and
opened its menu pane (47 713 pixels changed), and `UP1` closed it.

**Still open:** the same proof driven from a real browser through `page.mouse`,
which is what clears the registry's `reset.mouse` / `reset.keyboard`
`UNVERIFIED`. Nothing about the mechanism is in doubt; the browser leg has not
been run.

## Reset and checkpoint

`SH_RESET_MODE=relaunch`, resolved inside the launcher to Iris's **in-process
rollback** — the shape the MAME-native stations run, where "relaunch" is a
launcher-internal restore rather than a service restart.

Iris arrived with the whole stack already written: `save_snapshot` /
`load_snapshot` / `ci_restore` / `ci_rollback` capture CPU, MC, IOC, HPC3 and
the REX3 framebuffer chunks plus the SCSI COW overlay, with a CAS chunk store, a
`snapshot.toml` manifest with a `parent` chain, and a determinism validator.
`ci_rollback` replays a cached in-memory checkpoint.

**Provenance is a triple and the launcher enforces it.** `snapshot.toml`
(schema v4) already records `iris_git_rev`, `host_arch`, `parent`, the `disks`
list, `cpu_model` and **the cargo `features` list, which must match on
restore**. The launcher adds the emulator binary's md5 on top and **refuses** a
restore that does not match: golden + binary + device set are ONE combination
(rule 6), and a rebuild orphans every image.

**Two traps that are guaranteed to bite:**

- **The stale-page trap.** A restored emulator whose publisher shadow believes
  the reader already sees the baked frame publishes nothing, and the reader
  keeps streaming the **pre-reset picture forever** under a live guest. The
  launcher calls the fork's `FBSYNC` — one unconditional whole-frame
  republish — after **every** restore.
- **A bounded, loud fallback.** Two restore launches that never get a verb acked
  → the next launch cold-boots. A cold boot here is **~7 minutes** (PROM, IRIX
  autoconfig relink, login) and the COW `.dirty` sidecar is only flushed on a
  clean exit, so a killed emulator redoes the autoconfig. The launcher says so
  in its log rather than sitting silent for seven minutes.

**This station is outside `checkpoint-guard`'s scope, deliberately.**
[`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md) covers QEMU vmstate
stations and refuses savestate runtimes loudly by design. A recapture here
follows the shape that doc names for savestate paths: **write the new state
under a temp name, prove it restores, then `mv` it over the old one** — never
delete the old golden first.

**Restore wall clock, and the byte-identical proof.** Measured on the
integration rig 2026-09-10, every verb sent down the station's ONE `mamectl/1`
socket and every frame read out of the published IFB1 mapping with the daemon's
own reader (`scripts/shmshot.py`):

| | |
|---|---|
| `SAVEST golden` (256 MB RAM + the COW overlay) | **2 035 ms** |
| `LOADST golden`, from disk | **1 274 ms** |
| `LOADST golden`, via the in-memory rollback checkpoint | **536 ms** |
| `RESET` (rollback) | **387 ms** |
| `kill -9` → a cold start with a live restored guest | **10.9 s** |
| checkpoint on disk | **9.2 MB** per snapshot + **124 MB** shared CAS chunk store |

The frames, by md5 of the published RGB:

* scene at `SAVEST` time `6870865dce1489d143f52087ce4a56be`
* dirtied (menu opened) `a0538fb71bca963f13bd0d1c9c3b03ff` — different, as it must be
* after `LOADST` from disk `6870865d…` — **byte-identical to the scene**
* after `LOADST` via rollback `6870865d…` — byte-identical
* after `RESET` `6870865d…` — byte-identical
* after `kill -9` and a **fresh process** restoring at startup `6870865d…` —
  byte-identical, and `ImageChops.difference` against the saved scene returns a
  bounding box of `None`, i.e. not one pixel differs

**Input is live immediately after a restore**, which is the whole reason the
i8042 interrupt-edge fix exists: a `MOVEA` acked 5 ms after the restore and
`CUR` read back the restored cursor position. The startup restore waited on a
real milestone rather than a clock — *"guest reached VC2 mode decode in
4 695 ms — restoring 'golden'"* — and the failure ledger cleared itself one
second later, when the checkpoint plane acked a verb.

`.dirty` is **not** a carrier: after `kill -9` there was no
`disk.raw.overlay.dirty` at all, and the restore was still exact — the snapshot
carries the overlay and its dirty-sector set inside itself.

## Containment

Iris is an **emulated machine**, not a stock host application: a visitor reaches
an emulated MIPS R4400, not a host process. That puts it in the `nextstep` /
`irix` class rather than the `medley` / `lisa` class, so the floor is
`nextstep`'s — **run as an unprivileged account**, never as root in the host
namespaces.

Whether it also gets a `systemd-nspawn` container is an operator decision
recorded in [`../lab/IRIS-DEBRIDGE-BRIEF.md`](../lab/IRIS-DEBRIDGE-BRIEF.md) §5,
with nspawn as the recommended default on the grounds that Iris is third-party
code opening loopback TCP listeners of its own. It is new ground either way: no
landed station combines nspawn with `shm` capture, and `--private-network` hides
Iris's own listeners — the monitor console, a future retronet `pcap` bridge —
from the host, so the netns has to be designed rather than bolted on.

**Landed: nspawn, and it is the first station in the lineup that combines a
container with `shm` capture.** The namespace audit, read off the live payload:
private `pid mnt net ipc uts user`; `uid_map = 0 <base> 65536`; `CapBnd`
without `CAP_SYS_ADMIN`; `NoNewPrivs 1`; `Seccomp 2`. At the payload's own
bounding set: `mount` → permission denied, `/root` and the IRIX disk →
read-only filesystem, `ip link` → `lo` only, `ps -e` → `sd-stubinit` and `iris`
only, `/work` → writable.

The netns was designed rather than bolted on, and the two things that fall out
of it are worth stating: Iris's monitor console (`IRIS_MONITOR_ADDR`, upstream a
hardcoded `127.0.0.1:8888` singleton) is reachable only from inside — `nsenter
-t $(cat …/mame.pid) -n` — which is a feature; and there are exactly three
things bound read-write, `run/` for the sockets and the mapping, `work/` for the
per-launch scratch, and `state/` for the checkpoints.

## Idle auto-pause

Iris is the most expensive emulator in the lineup, so this station deliberately
**does not** override `SH_IDLE_PAUSE_SECS`: it takes the fleet default. Do not
copy the `amiga`/`gt40`/`irix` `SH_IDLE_PAUSE_SECS=0` stanza onto it.

Host-native, auto-pause is **not automatic** — `idle.rs` never infers a freezer
for a non-QEMU station. The station only gets it because its env names the
emulator's pidfile: `SH_IDLE_PAUSE_PIDFILE` plus `SH_IDLE_PAUSE_PROC_MATCH`
scoped to the station's own asset path. Without those two lines it burns a core
forever, silently.

## Measured cost

| | |
|---|---|
| `iris` on the host | **325 % CPU**, RSS **812 MB**, at a settled desktop with nothing driving it — measured over a 60 s window from `/proc/<pid>/stat`, 2026-09-10 |
| station QEMU | **none** — the bridge's QEMU cost ~150 % CPU and ~1.15 GB RSS, and deleting it is the conversion's structural saving |
| golden / snapshot store | **9.2 MB** per snapshot + **124 MB** shared CAS chunk store — against the bridge's `overlay.qcow2` at 702 MB with a 1.1 GiB vmstate inside it |
| asset | 6.4 GB apparent / ~500 MB allocated (sparse) — unchanged |
| published frames | **25.7 Hz** while the cursor sweeps; **0.1 Hz** at a settled desktop |

**The saving is the QEMU, and it is now a measurement rather than an
inference.** The emulator itself did not get cheaper — 325 % host-native against
the bridge's 320 % (interpreter) / 360 % (jitv2) in-guest is the same machine
doing the same work — but the ~150 % the station's QEMU cost is simply gone,
along with its 1.15 GB. The station went from roughly 510 % to 325 % for a
better exhibit.

The frame numbers are worth reading together with that. An idle Indy publishes
**one frame every ten seconds**, because the publisher compares each composited
row against its own shadow and writes nothing when nothing moved — so a station
nobody is looking at costs the encoder nothing at all. Under a moving pointer it
publishes at the emulator's own cadence.

**A frame-rate measurement that lied, and why.** Driving the pointer +4/-4 px
alternately reported 6.2 Hz and looked like a stuck refresh gate — the very
symptom of a known suspicion, that a cursor-only move does not mark the
framebuffer dirty and therefore rides the 6-frame idle heartbeat. It is not
true on this build: `Vc2::write_reg` sets the VC2 dirty flag on every cursor
register write and `should_render` consumes it as `palette_dirty`. The 6.2 Hz
was the *publisher being right*: an oscillating cursor is usually back where it
started by the time the next composite runs, so there is genuinely nothing to
publish. A monotonic sweep over the same interval measures **25.7 Hz**. No
change to the refresh gate is needed, and none was made.

## The measurement that started the conversion (2026-09-09)

The question was whether Iris had got faster since the station was built,
because the exhibit's pointer felt laggy next to the MAME `irix` station.
Upstream `main` was 134 commits ahead of the station's `1e05210` pin (old JIT
removed, jitv2 matured, CPU model a runtime setting, PS/2 toggles, timer fixes).
There were **no local patches to rebase**: the station had always run an
unmodified upstream binary.

Both feature sets were built in the (then still bookworm) chroot and run on
three sparse clones of the station's own overlay under `/data/vms/sandbox/`, one
at a time with the others QMP-stopped, box load 12–17. Each new binary was
swapped into its clone's kiosk, cold-booted IRIX (autoconfig relink + reboot,
~7 min), and logged in as `demos` on the framebuffer. The MAME `irix` station
was measured live through `ctl.sock` and `fb.shm`.

| | Iris `1e05210` (then live) | Iris `0540991` interp | Iris `0540991` jitv2 | MAME `irix` (R4600, DRC, throttled) |
|---|---|---|---|---|
| boots IRIX to the desktop | yes | yes | **yes** (the `43d2715` jitv2 wedge is gone) | yes |
| fixed CPU work, HOST wall-clock (100 k-iteration awk loop, 3 runs) | 8.4 s | 8.1–10.2 s | **1.95–2.04 s** | 1.60 s |
| single pointer move → framebuffer, median of 5 | 361 ms | 285 ms | 383 ms | **68 ms** |
| pointer stream (60 events @ 20 ms), lag after the last event | 216 ms | 224 ms | 397 ms | ~0 ms (settled before the last ack) |
| `iris` CPU at idle desktop | 320 % | 320 % | 360 % | — |

Three conclusions:

- **The interpreter did not get faster.** A like-for-like bump is neutral on CPU
  and on the pointer.
- **jitv2 is now usable and is a 4x CPU win** — level with MAME, whose DRC is
  throttled to real-Indy speed. It costs a continuously busy compile thread and
  ~360 MB more RSS.
- **The pointer lag is not the emulator core.** Every Iris build sat at
  250–400 ms and MAME at ~70 ms, because the station was a **bridge**: QEMU PS/2
  → guest X → winit → Iris → llvmpipe → dbus capture, versus MAME's host-native
  `mamesock` → ioport → shm. The mouse gets fixed by converting the station to a
  host-native runtime (rule 13), not by any Iris commit. **That verdict is this
  conversion's whole reason for existing.**

Two things the measurement itself taught, and both still apply:

- **Never time Iris with the guest's clock.** Under `1e05210` IRIX's `/bin/time`
  reported the same loop at **0.86–0.92 s** while the host clock said 8.4 s: the
  old pin's IRIX clock stands nearly still through CPU-bound work (a timer-tick
  starvation whose other symptom was that Iris's own `MIPS` HUD figure was a
  liar). `0540991` keeps guest time honest. The numbers above are host
  wall-clock.
- **The SCC telnet channel is single-client and wedges.** A timed-out command
  leaves a shell (or a running `awk`) on the getty and every later login fails;
  root's `.login` also asks `TERM = (vt100)` and swallows the next line as the
  answer. Host-native this channel is replaced outright by `serial-send` /
  `wait-serial` / `serial-read` on Iris's own control socket, which is
  single-purpose and does not wedge.

The harness lives in `scripts/build-guests/irix/iris-perf/` (`measure.py` for an
Iris clone over QMP + ssh, `hosttime.py` inside the kiosk, `mame-measure.py` for
the MAME station). It is **bridge-era tooling**: `measure.py` and `hosttime.py`
both assume a kiosk and a QMP socket, so re-measuring host-native means the
`mame-measure.py` shape (control socket + shm), not the other two.

## What the bridge era cost

Kept because two of these still bite, and because a rollback puts the kiosk
back. The bridge ran a Debian kiosk under KVM — `pc-i440fx-11.0,vmport=off`,
`-vga std`, `-display dbus,p2p=on`, an IDE overlay plus the read-only virtio
asset, `e1000` with an ssh hostfwd — with Iris as the single full-screen X
client.

**Dead with the kiosk:**

1. **No window manager ⇒ no X input focus ⇒ a silently dead keyboard.** The
   kiosk ran a bare X root with no WM, so nothing called `XSetInputFocus` and
   focus stayed `PointerRoot`; winit drops `WindowEvent::KeyboardInput` for a
   window it does not consider focused. The symptom was asymmetric and nasty —
   the **pointer kept working** (winit takes it from XI2 `RawMotion`, which
   ignores focus), so the exhibit looked alive while nothing typed ever arrived,
   and the keys did reach the guest (the i8042 IRQ 1 counter incremented) and
   were discarded one layer above. `launch.sh` fixed it with an `xdotool
   windowfocus` retry loop. **Host-native there is no window and no winit event
   loop**, so the trap and its workaround are both gone.
2. **QEMU's VMware backdoor ate the relative pointer.** With `vmport=auto`,
   Linux's `psmouse` negotiated VMMouse absolute and the guest enumerated two
   `VirtualPS/2 VMware VMMouse` devices; the relative PS/2 packets reached the
   kernel (IRQ 12 counted up) and never moved the X pointer. Pinned off in the
   device set. **No QEMU, no backdoor.**
3. **Re-emitting stripped the launcher's exec bit.** `--launcher-file` copied
   the tracked launcher onto itself, errored with `cp: … are the same file`, and
   left it non-executable; the unit then restart-looped while `/signal/` kept
   answering 200. **The QEMU launcher is gone**, but the shape has a successor:
   an nspawn `nspawn-inner.sh` ships as an emit `--aux-file` (root, 0600) and
   must be `install`ed into the container's work dir with the container's
   ownership on each launch, because the mapped root cannot read a root-owned
   0600 file.

**Still true, in a new place:**

4. **Bursts of unpaced input overflow the guest's PS/2 queue.** An unpaced burst
   of 37 relative events moved the IRIX cursor by 6 px — which looks exactly
   like a dead axis. This was QEMU's queue then; it is Iris's own ±256 clamp and
   8-packet coalescing now, and the conclusion is unchanged: **pace, and read
   back rather than counting what you sent.**

The bridge's checkpoint was `resetMode: loadvm`, snapshot `golden`, captured at
the Indigo Magic Desktop, and proved by sampling at a fixed machine instant so a
blinking cursor could not make two captures of the same state differ —
`stop ; loadvm golden ; stop ; screendump out.ppm ; cont`. Two such captures
either side of a dirtying pointer run were byte-identical
(`c7ce2397c12dc6e99bdd85918f0ffa31`) while the dirtied frame differed
(`9759f8a191e8323e5933ed47d6197927`). **The proof shape survives the
conversion**; only its source changes, from `screendump` to the shm file.

Rollback keeps `qemu-streamhost.sh` as `qemu-streamhost.sh.debridged-bak` and
`overlay.qcow2` as `overlay.qcow2.debridged-bak` until the operator retires
them — see [`../lab/DEBRIDGE-ROLLBACK.md`](../lab/DEBRIDGE-ROLLBACK.md). **The
launcher and its disk are ONE unit** (rule 6): roll both back together or
neither.

## Known gaps

- **Networking is parked — but the conversion makes the fix trivial, and did
  not take it.** IRIX reports `ec0: machine has bad ethernet address
  00:00:00:00:00:00` and falls back to standalone mode. On the bridge the fix
  was a one-time PROM step (`setenv -f eaddr 08:00:69:xx:xx:xx`, then `rtc save`
  from Iris's monitor console) and it was attempted and **not** landed:
  interrupting the PROM countdown needed keys delivered before the X focus fix
  existed in a cold boot, and 60 s of `Esc` through QMP never caught the window.
  Iris's own `[network] mac` config key is **backdoor-injected into the emulated
  NVRAM before boot** precisely so the guest needs no `setenv` — one config
  line, no keystroke race. With `[network] mode = "pcap"` bridging the guest's
  raw frames onto a station tap, that is the retronet web plane and an IM client
  the `irix` sibling already has. **Deliberately out of scope for this
  conversion**: it is a separate device-set change and a separate golden, and a
  conversion that also changes the network is two changes sharing one rollback.
  It is the next wave.
- **Audio is off** (`SH_AUDIO=off`). IRIX HAL2 through Iris is untested. The
  FIFO precedent exists (`SH_AUDIO_SOURCE=fifo`, s16le/48k stereo, *the daemon
  is the clock*), but the VICE wave's lesson is that a blocking audio sink on
  the emulation thread becomes the clock and cost 76 % of the machine's speed —
  on the lineup's most expensive emulator that is not a cheap experiment.
- **A cold boot does not reach the full Indigo Magic Desktop, and the golden
  must be baked at one that does.** On the integration rig, `demos` logs in, the
  Toolchest docks upper-left and a console window opens bottom-left — and there
  it stops, with 4Dwm's busy cursor and **no icon column down the right edge**,
  unchanged for ten minutes of framebuffer polling. The fixture text and the
  MIGRATION-WAVE reject criteria both describe the icon column, so *this scene is
  not the exhibit*. It does not block the conversion — every mechanism below was
  proven against it, and a checkpoint is content-agnostic — but the operator's
  golden recapture has to reach the real desktop first, and what the session is
  waiting on is **not yet diagnosed**. The obvious next step is a theory race
  (rule 14) on `rig-clone.sh` clones: a `demos` session start script blocking on
  a name lookup with no network is the first theory, the fresh COW overlay
  losing per-user desktop state the second.
- **A 4Dwm popup menu composites BLACK.** Pressing the Toolchest's *System*
  entry opens its pane and 4Dwm tracks the pointer into it correctly — and the
  pane's pixels are black in the published frame, after 6 s and after a hover.
  This is **not** a conversion regression: `shmpub` calls the same
  `SwCompositor::compose_pixels` as the windowed path in
  `iris-gui/src/framebuffer.rs`, and that function does handle the popup plane
  (`compositor.rs`, "Priority: cursor → popup → overlay → main pixel"), so the
  gap is in what Iris puts in that plane, on both paths equally. It is still
  visitor-visible and it is the first thing to fix after the cutover.
- **Iris's own `--ci-socket` costs the frame plane, so the exec channel is off.**
  Measured 2026-09-10 on the integration rig: with the ci socket armed, the Indy
  ran **ten minutes at ~200 % CPU and published no frame at all**; with it empty,
  the first frame landed **19 s** after launch. The cause is not `--ci` the mode
  — the fork already un-welded those — it is that the ci SCC backend and
  `Ioc::new_ci` travel with the *socket*, and one of them is what REX3 does not
  survive. The station therefore ships with `IRIS_CI_SOCK` empty and has no
  serial exec channel; `labctl exec` has nothing to offer here. Everything an
  operator needs is on the `mamectl/1` socket instead. Narrowing which of the
  two it is, is a bounded next task.
- **`reset.mouse` / `reset.keyboard` are `UNVERIFIED` in the registry**: proven
  by framebuffer, not yet through the real UI in a browser. Stream C's
  `e2e-live` probe is what clears them.
- **Two upstream defects found while reading Iris**, both worth a PR to
  `techomancer/iris`: `save_screenshot` writes the blue byte as the PNG's red
  channel, and the refresh loop sleeps the frame remainder **twice**, so a
  nominal 60 Hz delivers ~30 Hz on a fast host.

## Rollback

The station is self-contained. `systemctl stop streamhost@indyr4400`, then the
kill sweep the converted stations use: **SIGCONT, then TERM, then KILL**,
resolving processes by `/proc/<pid>/exe` scoped to the asset dir — never a
cmdline grep, and never assuming a SIGSTOPped standby will run to handle
SIGTERM. Nothing it touches is shared except the `irix` station's CHD, which is
only ever read via a copy at asset-build time.

Full de-bridge rollback (kiosk back, one move each way):
[`../lab/DEBRIDGE-ROLLBACK.md`](../lab/DEBRIDGE-ROLLBACK.md) and
`scripts/debridge-convert/`.

## Cutover runbook

The station is **live and active**. This is a scheduled outage, not a bring-up,
and it is one command away: everything below is landed, proven on a rig, and
deployed by `box-deploy`. Run it inside the landing lock
(`scripts/dev/wave.sh land begin indyr4400`), and never while another wave has
uncommitted live edits on the box.

**Expected outage: 12–20 minutes**, almost all of it the golden bake. The
mechanical part is under two minutes.

### What the visitor sees, step by step

| step | the exhibit |
|---|---|
| 1 stop | the tile goes offline; the SPA shows the station as unavailable |
| 2 deploy | still offline (nothing is running) |
| 3 assets | still offline; the 6.3 GB disk is unwrapped once, ~1 min |
| 4 start, cold | **live within ~20 s**, and it is the IRIX boot: PROM, then the autoconfig relink console, then the visual login. ~5 minutes of a machine visibly booting — degraded, but honest, and the log says so |
| 5 bake | a visitor sees the `demos` session come up and a desktop being reached |
| 6 SAVEST | no visible change; the checkpoint is captured under the live scene |
| 7 restart | **~11 s offline**, then the baked desktop, and every reset from here is 0.2–1.6 s |

### The commands

```sh
# 0. take the landing window, and park the rollback pair first
scripts/dev/wave.sh land begin indyr4400
ssh lab 'cd /data/vms/streamhost/stations/indyr4400 && \
  cp -a qemu-streamhost.sh qemu-streamhost.sh.debridged-bak 2>/dev/null; ls -la *.debridged-bak'

# 1. stop the bridge
ssh lab 'systemctl stop streamhost@indyr4400 && labctl ls | grep indyr4400'

# 2. deploy the pushed commit (a push is NOT a deploy — rule 11)
scripts/dev/box-deploy.sh                 # read the plan first
scripts/dev/box-deploy.sh --apply

# 3. stage the assets: the host-native binary, the container rootfs skeleton,
#    and the plain raw IRIX disk the kiosk's ext4 wrapper used to hold
ssh lab 'bash /data/kernel-hive/scripts/build-guests/tiles/indyr4400.sh'
ssh lab 'bash /data/vms/streamhost/stations/indyr4400/fetch-assets.sh --convert'

# 4. first start is a COLD BOOT on purpose: there is no golden yet, and the
#    launcher's ledger will say so. ~5 min to the visual login.
ssh lab 'sed -i "s/^IRIS_STATE=.*/IRIS_STATE=/" /data/vms/streamhost/stations/indyr4400/station.env'
ssh lab 'systemctl start streamhost@indyr4400'
ssh lab 'python3 /data/kernel-hive/scripts/dev/fb-wait.py \
  --shm /data/vms/streamhost/stations/indyr4400/run/fb.shm \
  --change --settle 25 --timeout 900'          # the IRIX visual login panel

# 5. bake the scene: log in as `demos`, and REACH THE REAL DESKTOP — Toolchest
#    upper-left, the camera/Start Demos/buttonfly/fsn icon column down the right
#    edge, nothing else open. See "Known gaps": a cold boot has NOT been seen to
#    get there on its own, so this step is the one that needs a person.
#    ctl.py --type is PIPELINED at zero spacing — the browser's shape, and the
#    only kind of typing claim that is evidence. $'...\n' so the shell, not the
#    client, makes the real newline: ctl.py interprets no escapes.
ssh lab "python3 /data/vms/streamhost/stations/indyr4400/ctl.py \
  /data/vms/streamhost/stations/indyr4400/run/ctl.sock --type \$'demos\n'"
#    ... then drive the pointer with the same client until the scene is right:
#      ctl.py <sock> 'MOVEA 640 512' DOWN1 UP1

# 6. capture the golden, through the station's own control socket. This IS the
#    documented equivalent of `checkpoint-guard recapture` for this runtime:
#    the guard covers QEMU vmstate and refuses savestate runtimes by design, and
#    SAVEST implements the shape it names — write under a temp name, rename over
#    the old one, keep `golden.prev`. It never deletes the old golden first.
#    ONE VERB PER CALL with mctl.py — it takes a single verb line and silently
#    folds anything after it into that verb's arguments, so `SAVEST golden CKPT
#    golden` runs SAVEST and never CKPT. Use --stdin for a sequence.
ssh lab 'printf "SAVEST golden\nCKPT golden\n" | \
  python3 /root/mctl.py /data/vms/streamhost/stations/indyr4400/run/ctl.sock \
  --timeout 120 --stdin'
#    CKPT must answer `present=1 prov=ok`. Then PROVE the restore before trusting
#    it — dirty the screen, restore, and compare the frames:
ssh lab 'python3 /root/mctl.py /data/vms/streamhost/stations/indyr4400/run/ctl.sock \
  --timeout 120 --stdin <<< "LOADST golden"'

# 7. arm the restore path and restart onto it
ssh lab 'sed -i "s/^IRIS_STATE=$/IRIS_STATE=golden/" /data/vms/streamhost/stations/indyr4400/station.env'
ssh lab 'systemctl restart streamhost@indyr4400'
ssh lab 'grep KH-RESET /data/vms/streamhost/stations/indyr4400/iris.log | tail -3'

# 8. release the window
scripts/dev/wave.sh land end indyr4400
```

### Checks that say it worked

```sh
ssh lab 'ls -l /data/vms/streamhost/stations/indyr4400/run/fb.shm'   # 5242944 bytes = 1280x1024x32 + header
ssh lab 'printf "PING\nSTAT\nCKPT golden\n" | python3 /root/mctl.py .../run/ctl.sock --timeout 10 --stdin'
ssh lab 'readlink /proc/$(cat /data/vms/streamhost/stations/indyr4400/mame.pid)/exe'
ssh lab 'ls -l /proc/$(cat .../mame.pid)/fd | grep -c X11'           # must be 0
```

and the one that actually matters: open `/os/indyr4400`, move the pointer, and
watch the arrow land where you put it.

### Rolling back

The bridge is one move each way and **the launcher and the disk roll back
together or not at all**: put `qemu-streamhost.sh` back from
`qemu-streamhost.sh.debridged-bak`, restore the registry row, `box-deploy.sh
--apply`, `systemctl restart streamhost@indyr4400`. The kiosk overlay is kept as
`overlay.qcow2.debridged-bak` until the operator retires it. Full procedure:
[`../lab/DEBRIDGE-ROLLBACK.md`](../lab/DEBRIDGE-ROLLBACK.md).

**Do not roll the binary back under a golden baked by the other one.** The
checkpoint refuses it (`KH_PROVENANCE=strict` compares the binary's BLAKE3 and
says so), which is the guard working — golden + binary + device set are ONE
combination.

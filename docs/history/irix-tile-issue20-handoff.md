> **Historical snapshot.** This document describes the system as it stood around 2026-07-30. It is kept for historical context and is not a description of the current system.

# SGI IRIX 6.5 tile (issue #20) — handoff / resume doc

Status as of 2026-07-30. This captures a long investigation so a fresh session can
continue without re-deriving anything.

## TL;DR

- **IRIX 6.5 emulation works.** MAME 0.288 (git master) boots the prebuilt IRIX
  6.5.22 CHD all the way to the **4Dwm Indigo Magic desktop** (root / empty
  password). Screenshots captured this session.
- **The blocker is the runtime substrate, and it is now solved in principle.**
  MAME's SGI Indy emulation **panics under a KVM vCPU** (the existing graphical-
  bridge kiosk is a QEMU/KVM VM) but runs **perfectly on the bare-metal CPU**.
  A **systemd-nspawn LXC container (bare-metal CPU) boots IRIX cleanly** — VALIDATED.
- **Decision taken:** build the IRIX tile on **LXC**, not the KVM bridge. That
  needs a new streamhost capture/input/reset path (see "Next steps").
- **Current step (in progress):** build the streamhost container capture/input
  backend directly (no x11vnc/noVNC detour — the gallery uses streamhost's
  WebTransport/H.264 pipeline + SPA tiles, so build that, not a VNC viewer).

## The core finding (do NOT re-litigate)

Same MAME 0.288 binary + same known-good CHD:
- **bare-metal labhost (Supermicro, `systemd-detect-virt=none`): boots to desktop.**
- **inside the KVM kiosk (`systemd-detect-virt=kvm`): deterministic `indy` GIO2/UTLB
  kernel panic** — `Exception PC 0x88007488`, `Local I/O interrupt register 1: 0x80
  <VR/GIO2>`, "PANIC: Unexpected exception".

Ruled out (all tested, all still panic under KVM): compiler (gcc-14 host build AND
gcc-12 bookworm build both panic in KVM); CHD corruption (known-good b1ac93e3 copy
panics); the warning-dismiss mouse click; and **every QEMU CPU tuning** (`+invtsc`,
`migratable=off`, `-nothrottle`). It is the virtualized vCPU (CPUID/feature exposure
differs; the guest drops ~30 non-migratable flags) breaking MAME's DRC/emulation.

**LXC container = host kernel + CPU directly (no vCPU) → emulation identical to bare
metal → boots.** That is why the tile must move off KVM. Native-x86 OS tiles
(win95, solaris, …) are unaffected — they need KVM and stay there. Only the ~6
emulator-bridge tiles are candidates for LXC (IRIX *requires* it; the others
tolerate KVM but would benefit).

## What works — the proven recipe

MAME invocation that boots IRIX to the desktop (run on bare metal or in a container):

```
sgi indy_4610 -bios b10 -rompath <roms> -gio64_gfx xl24 \
  -hard1 irix65.chd -diff_directory <writable-dir> -nvram_directory <nvram> \
  -inipath <dir-with-ui.ini> -skip_gameinfo -video soft -sound none [-mouse]
```

- **MAME must be 0.288+** (0.276 in Debian has a *different* fatal GIO2 emulation
  panic, unrelated to KVM — fixed in mainline by 0.288).
- **`ui.ini` must contain `skip_warnings 1`** AND the binary must carry the
  one-line patch `scripts/build-guests/patches/mame-irix-skip-warnings.patch` (makes
  `-skip_warnings` skip the startup warning unconditionally). Without it the
  warning needs a keypress; dismissing it with a **mouse click** trips the GIO2
  panic during early boot, and keyboard dismissal in a WM-less kiosk is unreliable.
- **PROM NVRAM must have `eaddr` set** (`setenv -f eaddr 08:00:69:12:34:56`,
  `setenv monitor h`, `date ...`) or IRIX loops on "bad ethernet address:
  00:00:00:00:00:00" and never reaches login. See `setup_irix.sh` (drives the PROM
  menu via a controlled-rate XTEST injector `relmove.c` — SGI menu items need
  press-hold-release, not a click; MAME's slow emulated keyboard needs ~150 ms key
  holds). A ready nvram dir is staged at `/data/vms/soltest/irix-mame/nvram/`.
- **Login:** user `root`, empty password → 4Dwm desktop. (No auto-login yet;
  golden/reset should snapshot the logged-in desktop, or configure IRIX autologin.)
- **Disk:** the CHD's write-diff grows during first-boot postinst; give the host
  ≥ ~4 GB free for it. (The KVM overlay needed resizing 6→20 GiB.)
- **Perf:** ~63% real-time single-thread at 2.5 GHz all-core; **~75% at 3.0 GHz
  turbo when the box is quiesced** (see box state below). Intrinsic MIPS-in-software
  ceiling — Track B (profile+patch MAME) is the lever.

## Artifacts on the box (all under /data/vms/soltest)

- `irix-mame/` — media: `irix65.chd` (currently b1ac93e3 = post-postinst, boots to
  login fast; original download md5 189f95fb), `roms/indy_4610/`
  (`ip24prom.070-9101-011.bin` bios b10 + natural.bin + 72x8455.zm82), `nvram/`
  (eaddr set), plus `setup_irix.sh`, `relmove.c`/`relmove`, evidence PNGs.
  Media source: archive.org item `irix65.7z` (bundles `indy_4610.7z` PROM + CHD).
- `mame-build/mame/` — **trixie gcc-14 MAME source + `sgi` binary, PATCHED
  (skip_warnings). THIS IS THE PROVEN-WORKING BINARY.** Runs natively in a trixie
  container; on bookworm it needs the glibc bundle below. Commit 8f21e978.
- `trixie-chroot/` — **the MAME build chroot** (fresh debootstrap trixie,
  2026-08-04): gcc-14 + the no-Qt dep set (build-essential git python3
  libsdl2-dev libsdl2-ttf-dev libfontconfig-dev libpulse-dev pkg-config
  ca-certificates), pinned tree at `/build/mame` (8f21e978, kept git-clean;
  apply the stack per build, restore pristine after — the gitignored `build/`
  + `sgi` stay as the warm cache). Chroot and box are both trixie/gcc-14, so
  chroot builds are representative of shipping builds. `NOWERROR=1` is retired
  with it: that flag only papered over a gcc-12 -Wrestrict false positive in
  mips3.cpp, and the 2026-08-04 cold build here passed -Werror clean without it.
- `bookworm-chroot/` — the gcc-12 chroot. Superseded by `trixie-chroot/` for
  the IRIX build, but **do not delete it**:
  `scripts/build-guests/emulators/build-mame-mpf2.sh` builds there deliberately, to match
  the glibc/libstdc++ ABI of the frozen Debian 12 bridge base. Its gcc-12 MAME
  build panics under KVM like all builds; a clang-16 rebuild attempt failed to
  compile. Also used as an nspawn rootfs earlier (its /dev got polluted; prefer
  the trixie container).
- `irix-glibc-bundle/` — trixie glibc 2.41 + libstdc++ etc., to run the trixie
  binary on a bookworm rootfs via `ld-linux ... --library-path`. **Retired
  2026-08-07 — off the launch path entirely.** The box is trixie (glibc 2.41,
  libstdc++ 3.4.33) and the shipped `sgi` needs at most `GLIBC_2.38` /
  `GLIBCXX_3.4.32`, so the bundle was loading a copy of the libc already in use.
  MAME is now exec'd directly by `streamhost/tiles/irix/x11-runtime.sh`, the
  `irix-apps` launcher and the park/serial/slowstate/bench rigs. Both bundle
  copies (here and `assets/irix/glibc/`) are kept unreferenced for one rollback
  cycle, then deletable.
- `trixie-ct/` — **the validated LXC rootfs**: debootstrap trixie + xvfb +
  imagemagick + libsdl2 + libfontconfig + libpulse + **x11vnc**. `nspawn-run*.sh`
  drivers show how to run MAME+IRIX in it. This is where the tile build continues.
- `irix/` — the abandoned KVM graphical-bridge overlay (vmid 99920, ssh 5820). Kept
  for reference; it panics. Its launcher `-cpu` was edited during CPU-tuning tests.
- `irix-payload/` — MAME binary staged for the (abandoned) graphical-bridge builder.

## Repo changes this session (see git log / this branch)

- `scripts/build-guests/irix/irix-bridge-install.sh`, `irix-bridge-launch.sh` — the
  KVM-bridge install/launch scripts. **Superseded by the LXC approach** but kept
  (document the media staging, ui.ini, diff_directory, matchbox, the bundled-glibc
  launch, and the GIO2/skip_warnings rationale). Do not wire these to the registry.
- `scripts/build-guests/patches/mame-irix-skip-warnings.patch` — the MAME patch (apply to
  any MAME build used for this tile).
- `docs/lab/irix-tile-issue20-handoff.md` — this doc.

## Spike PROVEN (2026-07-30) — x11rb capture + XTEST 1:1

Before touching the production binary, both load-bearing unknowns were validated
in isolation with a throwaway `x11rb` spike (`/data/vms/soltest/x11spike`, binary
in the shared `…/streamhost/build/target/release/x11spike`) against a live
MAME/IRIX on host `DISPLAY=:99` (1280x1024x24):

- **Capture works and is FAST.** Full-frame `GetImage(Z_PIXMAP)` of the 1280x1024
  root = **3.2 ms/grab (1636 MB/s, ~300 fps headroom)** — plain socket GetImage,
  **SHM not even required** for the target framerate. Pixels are **BGRX depth-24**
  (byte order matches `FrameState.fb`'s BGRA copy-path directly; alpha byte = X).
  Captured PNG is color-correct (SGI-blue IRIX boot console).
- **XTEST gives an exact 1:1 absolute pointer.** `xtest_fake_input(MotionNotify,
  root, x, y)` then `QueryPointer` returns the SAME coords at center/corner/
  arbitrary points — issue #20's hard pointer requirement, met.
- **Deps are trivial.** `x11rb = "0.13"` (0.13.2), features `shm,damage,xtest,randr`,
  **pure-Rust backend, ZERO C libraries**, compiles on the box in ~16 s. The
  container/host only needs `libxcb.so.1` at the socket layer (already present).
- Extensions confirmed on Xvfb: DAMAGE, MIT-SHM, XFIXES, XTEST all present.

So the streamhost X11 backend is de-risked: fill `FrameState.fb` from `GetImage`
(or SHM+XDamage for lower CPU), inject via `xtest_fake_input`. Spike source:
`main.rs` shows the exact x11rb 0.13 API calls used.

## Next steps (the LXC tile build)

> Decision: do **NOT** build an x11vnc/noVNC path — it doesn't integrate with the
> gallery (SPA tiles consume streamhost's WebTransport/H.264 stream). Build the
> streamhost container backend directly.

1. **streamhost container capture/input backend — ✅ DONE + on main (fa7daac).**
   `SH_CAPTURE=x11` → `capture::connect_x11` (x11rb GetImage + XDamage into
   `FrameState.fb`); `SH_INPUT_BACKEND=x11test` → `X11TestSink` (XTEST 1:1 abs
   pointer + buttons/wheel, `src/x11_input.rs`). `Capture.main_conn` is now
   `Option` (None for X11); the QEMU fleet is byte-identical (SH_CAPTURE default
   qemu). Full CI gate green. Validated end-to-end against live IRIX on `:99`:
   `[x11cap] first frame 1280x1024` → encoder ~44 fps, p50 3.0 ms / p95 3.7 ms →
   `LISTENING udp/4599`, x11test sink Healthy. Run recipe (host, MAME already on
   `:99`): `SH_CAPTURE=x11 SH_X11_DISPLAY=:99 SH_INPUT_BACKEND=x11test streamhost`.
   Remaining sub-steps below (2→5) complete the tile.
2. **Clean IRIX runtime + registry tile (get it VISIBLE in the gallery UI — the
   user's stated gate before tracks A/B):** stand up a persistent Xvfb + MAME with
   the eaddr-set nvram so it reaches the 4Dwm desktop (the `:99` smoke used the
   no-eaddr nvram and only reached the boot console); run streamhost x11 against
   it as a service; add `registry/tiles/irix.json` (§4). Needs a container-tile
   lifecycle (the launcher/service model assumes a QEMU VM; an LXC/scope + Xvfb +
   streamhost triplet is new).
3. **CRIU reset validation (highest-risk piece):** `indy_4610` MAME save-states are
   `unsupported`, so reset can't use MAME loadstate. Use **CRIU checkpoint/restore
   of the whole container** (Xvfb+MAME at the desktop) for instant warm-desktop
   reset. Validate `criu` / `lxc-checkpoint` / `podman container checkpoint` works
   with the threaded X/SDL process tree. Fallback if CRIU is unworkable: a fresh
   `-hard1` diff overlay + reboot IRIX (slow ~5–7 min — only acceptable with a
   boot-video replay in front, see `[[osgallery-bootvideo-replay]]`).
3. **Registry tile:** once streaming works, add `registry/tiles/irix.json`
   (model on `amiga.json` + the `streamhost/docs/GRAPHICAL-BRIDGE.md` blueprint;
   archetype `beige-tower-crt`, teal SGI accent), `make tile-registry-generate`,
   CI green. Note: the tile's runtime is an LXC container, not a QEMU VM — the
   registry/launcher model needs a new lifecycle path for container tiles.
4. **Two follow-on tracks** (tasks #10/#11): install all guide apps/demos into the
   CHD; profile+patch MAME for Indy speed.

## Runtime enablement findings (2026-07-30, in progress)

Driving IRIX-in-MAME on a headless Xvfb is the current focus (a background agent
is grinding it). Hard-won facts:

- **MAME must be windowed** (`-video soft`, no fullscreen): SDL **fullscreen FAILS
  on Xvfb** (MAME exits). Add `-background_input` so MAME processes input without
  UI focus.
- **Pointer MOTION reaches the guest** via XTest relative motion (`relmove.c` =
  `XTestFakeRelativeMotionEvent`, 1px steps); IRIX applies ~**1.28x pointer accel**
  (so NOT 1:1 until accel disabled in-guest via `xset m 0 0` or SGI equivalent).
- **Keyboard + mouse BUTTONS do NOT reach the guest** on a WM-less windowed Xvfb
  (only motion does) — an X input-focus / SDL-grab problem. A real WM (matchbox/
  openbox) for focus and/or `SDL_GRAB_KEYBOARD=1` and/or MAME Lua
  `-autoboot_script` (drives `manager.machine.ioport` directly, bypassing host
  input) are the avenues. THIS is the critical unblocker for an interactive tile.
- `Scroll Lock` = MAME's **uimodekey** (Indy has a keyboard, so MAME's UI keys are
  off by default; Scroll Lock toggles). MAME menu = Scroll Lock then Tab.
- Login = click the **root** account, **no password** → 4Dwm desktop (per the
  official guide https://sgi.neocities.org/installguide).
- **File injection into the guest = `genisoimage` → ISO → attach as CD → mount in
  IRIX** (no networking needed). This is the channel for the golden config AND
  Track A app installs.
- The **red band + black borders** at the login are a suspected **resolution
  mismatch** (PROM `monitor` var not set to `h`=1280x1024; the nvram eeprom has an
  unset MAC too → "bad ethernet 00:00:00" + slow boot). Fixing the 256-byte
  `nvram/indy_4610/eeprom` (eaddr + monitor=h) offline — or via MAME Lua at the
  PROM — should give a clean full-screen render.
- **CRIU 4.1.1 works** on the box for a basic process (dump freezes+checkpoints,
  restore resumes) — the reset primitive is viable; checkpoint the {Xvfb+MAME}
  tree at the golden desktop.
- Cold boot to login is ~3-4 min at ~44% realtime — minimize reboots.
- Prototype launcher: `/data/vms/soltest/irix-mame/irix-run.sh`.

## x11 tile-runtime integration design (for the post-enablement pass)

The IRIX tile is the first NON-QEMU streamhost tile. Every management path
assumes QMP/QEMU (see the Explore map in git history). Minimal backward-compatible
plan — mirror the existing `SH_QEMU_MODE=pve` early-branch pattern:

1. **tile.env** (x11 tile): `SH_CAPTURE=x11`, `SH_X11_DISPLAY=:<n>`,
   `SH_INPUT_BACKEND=x11test`, a `SH_TILE_RUNTIME=x11` marker, and NO `SH_QMP`.
2. **Service hooks** `ensure-tile-qemu.sh` / `stop-tile-qemu.sh`: add an
   `[ "${SH_TILE_RUNTIME:-}" = x11 ] && exec ensure-tile-x11.sh/stop-tile-x11.sh`
   early-branch. `ensure-tile-x11.sh` starts Xvfb + MAME (idempotent on an x11
   pidfile, no QMP wait); `stop-tile-x11.sh` tears them down by pidfile.
3. **`bring-up-all.sh`**: x11 tiles skip `wait_qmp`, launch the x11 runtime.
4. **`streamhost-tile.sh` emit**: new `x11` mode — emit tile.env without SH_QMP,
   copy a tracked `x11-runtime.sh` launcher (like verbatim tiles), no
   qemu-streamhost.sh.
5. **`scripts/tiles-registry.py` + `registry/schema/tile-v1.schema.json`**: add a
   runtime kind for x11 (relax the `runtime.qemu` binary/accel/vga/deviceSet
   requirements; add a `runtime.x11` block: display, geometry, launcher,
   resetMode=criu). `validate_schema_shape` (tiles-registry.py:234-263) currently
   hard-requires `runtime.qemu` for streamhost tiles — extend it.
6. **`gen_tiles_json.py`**: x11 tiles skip `probe_golden` (no QMP); `reset_mode`
   = a new `criu`; `console` = `x11`. **labctl**: `shot` for x11 grabs via x11
   (x11spike) not QMP screendump; `reset` via CRIU; `type`/`key`/`sh`/`health`
   are QMP-bound → mark unsupported or route via the x11 path.
7. **`registry/tiles/irix.json`**: model museum/spa/render on `amiga.json`;
   archetype `beige-tower-crt`, teal SGI accent `#8CA0B4`/indigo; runtime kind
   x11. Then `make tile-registry-generate`; CI green.

## Box state / cleanup owed

- **30 streamhost production tiles are STOPPED** (`systemctl stop 'streamhost@*'`)
  to give MAME 3.0 GHz turbo. **The gallery is effectively down.** RESTORE with
  `systemctl start streamhost@<tile>` per tile or `streamhost/bring-up-all.sh`
  (task #7). CT950 (dev box) + the SPA HTTPS server are still up.
- Host packages added for this work (removable): mame/mame-data were purged;
  xvfb, matchbox-window-manager, xdotool, imagemagick, p7zip-full, debootstrap,
  systemd-container remain on the Proxmox host.
- The `irix` KVM overlay QEMU may still be running with a modified `-cpu`.

## Production asset promotion + 256 MB RAM (2026-07-31)

The live tile used to read its emulator, glibc bundle and media straight out of
`/data/vms/soltest/` — the clone/experiment scratch area — i.e. a live exhibit
resting on paths other agents rebuild and delete underneath it (one did exactly
that, mid-session). Everything is now copied into the production tree
**`/data/vms/streamhost/assets/irix/`** (`irix65.chd`, `roms/`, `nvram/`,
`uicfg/`, `mame/sgi`, `glibc/`; 769 MB) and `x11-runtime.sh` /
`fetch-assets.sh` default there. The soltest copies stay put as the build stage.

- **The golden CHD was being mutated in place, and `chmod 444` never stopped
  it.** `irix65.chd` is an *uncompressed* CHD: MAME opens such an image `O_RDWR`
  and never creates a `-diff_directory` overlay (the tile's `diff/` had been
  empty for its whole life). MAME runs as root, and root ignores the mode bits.
  Evidence: `/proc/<mame>/fd` flags `0100002` on the golden, and three distinct
  md5s in one morning (`fc344aba` → `430bf0ba` while merely being observed).
- `chattr +i` *does* stop it (works on this ZFS), but MAME has **no read-only
  fallback** — it dies with `Unable to load image ...: Operation not permitted`.
- Shipped fix: golden is `444` + `chattr +i`, and `x11-runtime.sh` re-copies it
  to a throwaway per-launch `disk.chd` in the tile dir (~2 s). Verified: the
  golden md5 is byte-stable across four launches.
- **RAM: 16 MB → 256 MB**, via `scripts/build-guests/patches/mame-indy-256mb-ram.patch`
  (banks A+B `4x32M`). Offline check on any binary:
  `sgi -listxml indy_4610` → `4x32M default="yes"` for banks A and B. Live proof
  is a framebuffer screenshot of `hinv -c memory` → `Main memory size: 256
  Mbytes` (`/data/vms/streamhost/assets/irix/evidence-hinv-256mb-2026-07-31.png`).
  `registry/tiles/irix.json` `museum.ramMB` is now 256.
- Cold boot from the golden reaches the **iconlogin screen in ~5.5 min** with
  MAME pinned to one physical core (`taskset -c 2,10`); the 4Dwm desktop follows
  ~1 min after logging in as `root` (empty password). A relaunch always lands on
  the login screen — there is no autologin.
- Driving the desktop: pointer motion is XTest *relative* with IRIX
  acceleration, so use a closed loop (slam to a corner, then locate the red
  cursor in a framebuffer grab and correct; measured gain ~2.5). 4Dwm is
  pointer-focus — park the cursor over the target window before typing.

## Key gotchas learned

- `-skip_warnings` is a **UI option** (ui.ini / `-inipath`), NOT a CLI flag —
  passing it on the command line makes MAME exit with "unknown option".
- The host's Xvfb `import -window root` capture is flaky (returns 295-byte blanks,
  and sometimes MAME has no visible X window without a WM). The **kiosk/container
  QMP or in-container `import` is more reliable**; use matchbox for MAME to hold
  focus if you must send keys.
- MAME's DRC generates identical code across host/guest (SIMD flags present); the
  KVM break is NOT a missing SIMD feature and NOT fixable via `-cpu` flags tried.
- IRIX first boot runs a slow postinst; the `b1ac93e3` CHD is already past it.

## Black-screen cold-boot hang — investigation 2026-07-31

**Shipped: a boot watchdog** (see `docs/guests/irix.md` for the operator-facing
description). `x11-runtime.sh` backgrounds `x11-runtime.sh --bootwatch`, which
samples the real framebuffer every 15 s and, after 90 s of continuous black,
kills MAME by pidfile and relaunches it on the existing Xvfb — up to 5 boots.
Verified end to end against a stub launcher: black stub → relaunch, relaunch,
give up after the attempt budget with exactly one stub alive at a time and no
orphans; healthy stub → zero relaunches, watchdog exits at its deadline. It
cannot fight the service (generation token + `systemctl is-active` gate +
`stop-tile-x11.sh` kills `bootwatch.pid` first). In production it has now armed
on three live cold boots (two on the base image, one on `irix65-apps.chd`); all
three reached the `iconlogin` chooser unaided and the watchdog exited at its
deadline without intervening.

### Measured hang rate

Rig: `/data/vms/soltest/irix-boot-trials/` — `trial.sh` (one namespaced trial:
own dir, own Xvfb display, own nvram, own reflink clone of the golden, killed
only through `clone-guard`), `runner.sh` (serial batches), `probe.lua` (per-
second emulated-time / maincpu-PC / screen-geometry sampling plus MAME-internal
snapshots). Classification is by framebuffer content, never by log inference.

- **Baseline (base `irix65.chd`, one physical core, 13 completed trials):
  1 HANG, 12 OK.** A 14th was cut short at the login screen.
- The **~2 in 3** rate in the earlier notes did **not** reproduce (P(1 hang in
  13 | p=2/3) ≈ 1e-5). The most likely explanation is that the earlier
  observations predate the golden-CHD fix: the uncompressed golden was being
  opened `O_RDWR` and mutated in place — at one point by three concurrent MAME
  instances — so "byte-identical fresh `disk.chd`" was not actually true.
  Today's rate is **~8% (1/13)**, and the watchdog's 5 attempts take that to a
  residual ~5e-6 **if attempts are independent** — which is the load-bearing
  assumption, and it is only justified to the extent that the trigger is a race
  and not a property of the image (the trials do start from a byte-identical
  clone every time, so anything image-borne would have shown a much higher rate).

### What the failure actually is

From the one captured hang plus per-second probes:

- The **emulated MIPS kernel keeps running**: emulated time advances at the
  normal rate and the sampled `PC` moves over a wide spread of kernel addresses
  (`0x88xxxxxx`, plus the `0x80000180` exception vector). It is not a deadlock
  and not an emulator stall.
- **MAME's own internal snapshots are uniformly black** (4 kB PNGs) while its
  X window is still mapped at 1280x1024. So the blackness is in the *emulated*
  video output, not in the host X/SDL path.
- The last good frame is the tail of the `S77sysevent` loop; the display dies at
  exactly the console→`iconlogin` handover. A **healthy** boot has a single
  ~10 s black transient at the same point (seen at t=350 s in a good trial), so
  the hang is that transient never ending.
- Independent corroboration from the perf agent's soak: kernel alive, console
  responsive, X/iconlogin never starts.

### Leading (unproven) mechanism

`src/devices/bus/gio64/newport.cpp`: the VC2 decodes its video timing table into
`m_vt_table` and derives `m_readout_x0/y0/x1/y1` **once**, in
`vc2_device::update_screen_size()`, and that is called from exactly one place —
a write to VC2 register `0x00` (video entry pointer). `newport_base_device::
update_screen_size()` then does `m_screen->set_size(x_end - x_start, y_end -
y_start)`, and `screen_update()` draws nothing when `y_start >= y_end`.

Real VC2 hardware re-reads that table from its RAM continuously; MAME snapshots
a decode. So **any VC2 RAM update that is not followed by a register-0x00 write
is lost**, and if the table was incomplete at the moment 0x00 was written the
screen stays blank forever with no path back. That matches the signature
exactly. A behaviour-preserving fix would be to mark the table dirty on RAM
writes and re-derive it at vblank, only signalling `set_size` when the derived
size actually changes.

**Not yet confirmed** — confirming it needs the emulated screen geometry from a
hung run. `probe.lua` now logs it (`geo=`); healthy runs go `1280x1024` →
`1288x1024` when IRIX programs the VC2, so a hung run showing `0x0` (or a
degenerate size) would settle it. The one hang captured so far predates that
probe change.

### Nondeterminism: RTC-seed hypothesis not supported

The perf agent found two control runs disagreeing byte-for-byte at emulated
t=120/150 (`5bbf4cbe` vs `c34406fe`) and proposed the host-wall-clock RTC seed
as the divergence source. Re-tested with `det-run.sh` + `detprobe.lua`, which
snapshot the emulated screen at **fixed emulated seconds** (40/60/100/110/120/
130/150) so runs are comparable regardless of host speed:

- Two host-clock runs minutes apart were **byte-identical at every mark**,
  including 120/130/150 (both `c34406fe…`, i.e. the same branch the perf agent
  saw as one of its two outcomes).

So the boot is *usually* deterministic even with a freely-seeded RTC. The
divergence is itself rare — which is consistent with a rare race, and with the
~8% hang rate, rather than with a per-run wall-clock branch. If `5bbf4cbe` is
the hang branch, the hash at emulated t=120 is a cheap early predictor worth
using to bisect: it turns a ~7 min trial into a ~5 min one and gives a precise
divergence point.

`det-run.sh` has a `fixed` mode that wraps MAME in `faketime` to pin the RTC
seed, but **it does not work as written**: MAME throttles against the faked
clock and crawls (10% CPU, 3 s of CPU time in 10 minutes, emulated time never
reaching the first mark) even with `FAKETIME_DONT_FAKE_MONOTONIC=1`. Pinning
the RTC needs a different lever — most plausibly seeding the `ds1386` bbram in
`nvram/indy_4610/rtc`, which the tile already ships and controls, rather than
faking the host clock underneath the emulator. Note also that `faketime` adds a
wrapper process, so the pidfile records the *wrapper* and a pidfile kill leaves
the real MAME orphaned; fix that before reusing the mode.

Also measured, on Track A's new `irix65-apps.chd`: 3 trials, 3 OK, then the arm was stopped to free the core
for the determinism runs — far too few to say anything about the hang rate, and
at a baseline of ~8% no 14-trial arm on one core could have.

### Eliminating cold boot — savestate and CRIU verdicts

- **MAME save states: NOT available.** `sgi -listxml indy_4610` reports
  `savestate="unsupported"`, and `src/mame/sgi/indy_indigo2.cpp` declares the
  driver without `MACHINE_SUPPORTS_SAVE` — the device state was never audited
  for save registration, so a save/restore would be silently incomplete. The
  earlier note was right.
- **CRIU: blocked today, fixable in principle, not a quick win.** CRIU 4.1.1
  passes `criu check --extra` on this box, but `criu dump` of a live MAME fails
  at `Can't dump file 8 of that type [20660] (chr 10:259)` — `/dev/udmabuf`.
  MAME's fd table also carries `/dmabuf:`, `anon_inode:sync_file`,
  `memfd:lp_dma_buf` and `/dev/snd/seq`: all of the dma-buf machinery Mesa's
  llvmpipe X11 backend sets up even under `-video soft`. On top of that, the
  X connection to Xvfb is an *external* unix socket — MAME and Xvfb are
  siblings, not one tree, so a working design needs them in a shared PID
  namespace with streamhost outside and able to reconnect after restore, plus a
  disk.chd snapshot per checkpoint. Estimate: a day-plus of work; payoff is a
  near-instant deterministic reset that would moot the hang entirely.
- **Boot-video replay** (`[[osgallery-bootvideo-replay]]`) remains the cheap UX
  mitigation for the remaining ~4.5 min cold boot and is not implemented here.


## Three distinct failure modes — do not conflate them (2026-07-31)

1. **Black-screen hang** — pure black framebuffer (mean 0), guest kernel still
   running (emulated clock advancing), MAME's own snapshots black, window still
   mapped, **emulated screen geometry still correct**. Blackout lands in a tight
   emulated window (t=59–62, the console→X handover); a healthy boot passes
   through the same blackout as a ~10 s transient. **STILL UNEXPLAINED** — the
   VC2 stale-timing-table theory was proven to be a real MAME inaccuracy but
   disproven as the cause (geometry never degenerates, and the patched binary
   hangs too; see docs/guests/irix.md). Mitigation is the boot watchdog.
2. **`PANIC: bad istack sp:8835afa8`** — console text on screen, guest dead,
   MAME still rendering. **SOLVED 2026-08-02 (issue #43): the SGI MC truncates
   DMA page-table addresses above physical 0x0fffffff**, so on a 256 MB machine
   (which only our own RAM patch creates) IRIX's DMA mappings are read from the
   wrong place and the DMA engine scribbles on kernel memory. Fixed by
   `scripts/build-guests/patches/mame-mc-dma-ptbase-mask.patch`; reproduction rig and the
   A/B evidence are in `docs/guests/irix.md`. Trigger: Toolchest → Help →
   "Welcome to SGI". (Historic note: an earlier "5 panics out of 5 boots" run was
   a bug in the park script's own detector calling healthy logged-in sessions
   panics — that detector bug was real and separate, and the panic is real too.)
3. **MAME DRC segfault** in `mips3_device::code_compile_block` — the MAME
   process dies outright. Separate from both of the above.

The framebuffer tells them apart cheaply: black / console-text / no process.

## Netscape autostart — for whoever rebuilds the golden next

Not fixed here; recording it so it is not lost. The session's Netscape window
costs a lot (~90% of real time at a bare idle desktop vs ~56% with Netscape
open, and that cost is genuinely guest-side emulated CPU, not our repaint path),
and its autostart is **inconsistent between boots of the same image** — so what
a visitor sees is not deterministic. Both point at the same thing: the saved
Indigo Magic session under root's home is being restored non-deterministically.
The exhibit wants a deliberate, fixed session, so the next golden re-bake should
either clear the saved session and disable session restore, or bake exactly the
window set the exhibit is supposed to show. Worth folding into the demo-content
rebuild already in flight rather than doing a re-bake for it alone (the same
applies to `chkconfig sysevent off`, which never took — see docs/guests/irix.md).

## A/B verdict on the VC2 patch (2026-08-02) — do NOT promote

Controlled design: `sgi-control` and `sgi-vc2fix` built from **one** source tree,
differing only in `mame-newport-vc2-restale-timing.patch`, so they also share
every other local patch. This matters — an earlier arm compared the *production*
binary against a patched build that also carried the 256 MB DRC code-cache
patch, and the "patched" arm ran at ~41% of real time against ~20%. A 2x
difference that had nothing to do with the VC2 fix. **Control and treatment must
come off one tree**; that confound was caught before any number was reported.

Three interleaved cells, 20 trials each, all on `irix65-apps.chd`:

| cell | hangs / trials |
|---|---|
| control + `-frameskip 6` | 2 / 20 |
| **vc2fix** + `-frameskip 6` | **1 / 20** |
| control, no frameskip | 1 / 20 |

- **The patch does not fix the hang** — the treatment cell hung, verified down to
  the binary path in the trial's `meta.txt` and the identical failure signature.
- **No frameskip amplification** — 2/20 with fs6 vs 1/20 without is nothing at
  these counts. The earlier "fs6 might amplify" hunch came from comparing runs
  taken hours apart under different box load; interleaved cells kill that
  artefact. fs6 keeps its measured speed win with no reliability cost shown.
- Pooled rate **4/60 = 6.7%** (95% CI ≈ 1.8–16%), consistent with the earlier
  1/29 estimate. Per-cell counts are far too small to separate 5% from 10%.
- Patch cost is nil: paired control/treatment trials reached the same emulated
  time in 272 s vs 274 s.

## Guest-side forensics on a hung boot (2026-08-02)

The emulated screen geometry stays correct at 1288x1024 through the blackout, so
MAME is faithfully scanning out a framebuffer IRIX itself left black. That moves
the search inside the guest, and the guest writes down what it did.

**Recipe, scripted as `/data/vms/soltest/irix-forensics/hang-forensics.sh`:** the
golden is an uncompressed CHD, so `chdman extractraw` takes ~9 s, and IRIX XFS
mounts read-only on this kernel with
`mount -t xfs -o ro,norecovery,nouuid,loop,offset=136314880` (`norecovery`
because Linux cannot replay IRIX's XFS log). `trial.sh` now PRESERVES the write
overlay of a hung boot as `hang-disk.chd` — the first four hangs left no
evidence because cleanup deleted it.

Comparing a hung boot against a healthy trial killed the same way:

| | healthy trial (`ctl1`) | hung trial (`u007`) |
|---|---|---|
| `/var/X11/xdm/xdm-pid` | `1404`, rewritten this boot | `1405` — **byte- and timestamp-identical to the golden**, never written |
| `/var/X11/xdm/xdm-errors` | 0 bytes | 0 bytes |
| `/var/adm/SYSLOG` | runs on into userland daemons (`inetd`, `sgindexAdmin`, `tfxd`) | **stops dead at `NOTICE: Ending XFS recovery for filesystem: /`**, then NULs |

**But this is NOT yet conclusive, and the reason matters.** The hung trial was
killed at emulated t=77 while the control ran to emulated t=111 — and a *healthy*
boot has not started xdm at emu 77 either (the login chooser appears around emu
100–110). So "xdm never wrote its pid" is exactly what a healthy boot would also
show at that point. The comparison is confounded by emulated-time-at-kill, and
the SYSLOG difference is partly explained the same way plus syslog buffering.

Fixed for the next hang: `trial.sh` now holds a hung boot for
`ARM_HANG_SOAK` (default 900 s) *before* killing it, so emulated time runs well
past where a healthy boot reaches the chooser. Only then does the absence of an
xdm pid mean something.

### New lead — the guest's clock varies wildly between runs

Every trial copies the SAME nvram (`$ASSETS/nvram`, eaddr + `monitor=h` baked),
so the emulated ds1386 should start every boot at an identical date. It does
not. Boot dates taken from each run's own `SYSLOG`:

```
golden (as built)   Jul  3 23:47
ctl1  (healthy)     Jul 12 03:00    <- 1993
u007  (hung)        Aug 16 06:01
live tile           Aug 24 03:59
```

Those differ by **years**, from identical starting nvram, and none of them match
the host clock (2026-08-02). Something in the RTC path is either host-derived or
reading uninitialised state. That is a real, previously unrecognised source of
run-to-run nondeterminism in a boot we had assumed was deterministic — and IRIX
startup branches on time in several places. It also keeps the start-time
correlation lead alive (three hangs being exactly the three trials launched in
the same second). Worth pinning the RTC properly — seed `nvram/indy_4610/rtc`
deliberately and re-measure — rather than the `faketime` approach, which does
not work (MAME throttles against the faked clock; see above).


## Shared-memory capture + window-free pointer (2026-08-02)

Built and proven on a clone; **the live tile is untouched** (`registry/tiles/irix.json`
still says `SH_CAPTURE=x11` / `SH_INPUT_BACKEND=x11test`). Operator-facing
description is in `docs/guests/irix.md`; knobs in `streamhost/docs/CONFIG.md`.

- **streamhost `SH_CAPTURE=shm`** — `streamhost/streamhost/src/capture/shm.rs`.
  Maps the file MAME publishes, seqlock-validated, straight into
  `FrameState.fb`. `main_conn` is `None` like the x11 backend, so dbus audio and
  QMP idle-pause stay off. Knobs `SH_SHM_PATH`, `SH_SHM_POLL_MS` (2 ms),
  `SH_SHM_DAMAGE` (on). `SH_CAPTURE` still defaults to `qemu`; the 35-tile QEMU
  fleet is byte-identical (the only shared-path edit is `pauser` becoming
  `capture_backend.is_qemu()`, same value for `Qemu`).
- **streamhost `SH_INPUT_BACKEND=mamecmd`** — `streamhost/streamhost/src/mame_input.rs`.
  Same dead reckoning as `x11test`, transport moved to the Lua agent's command
  file because `-video none` leaves nothing for XTEST to inject into.
- **`irixagent.lua` `MOVEP`** — queued, budget-paced relative move. Additive:
  `MOVE` is untouched, so every ops script keeps working.
- **`x11-runtime.sh` `IRIX_CAPTURE=shm`** — no Xvfb, `-video none`,
  `IRIX_SHM_PATH` exported, and the boot watchdog samples the mapping through
  the new `streamhost/tiles/irix/fbstat.py` instead of `import -window root`.
  Default is still `x11`, so the launcher is behaviour-identical until switched.

### What was verified on the clone (`/data/vms/soltest/irix-shmcap`)

All evidence is the real framebuffer read out of the mapping, never log inference.

- MAME under `-video none` **does** call `screen_update`, so the producer keeps
  publishing with no window at all. The mapping is **1288x1024** (5,275,712
  bytes = 64 + 1288*1024*4) from the first frame, colour-correct BGRA with no
  conversion anywhere on the path.
- streamhost comes up on it end to end: `[shmcap] first frame 1288x1024` →
  encoder at 1288x1024 → `LISTENING udp/…` → `mamecmd` router Healthy.
- Damage gating survives: a static login chooser produces `dirty=(1,1,0,0)`
  frames that are skipped without copying a byte, and the encoder idles at
  ~2 fps of pure keyframe heartbeat.

### Two bugs found the hard way (both fixed, both worth remembering)

- **A `Mapping` whose fields are all `Copy` cannot be finished with functional
  update syntax.** `Ok(Some(Mapping { w, h, stride, ..m }))` COPIES the pointer
  and leaves `m` live to be dropped at end of scope — munmapping the region out
  from under the value just returned. Instant segfault on the first frame, with
  no message. The mapping is now built once and mutated in place.

  This is what the three `shmcapture[...] segfault ... error 4` entries in the
  box's `dmesg` are (13:06:06, 13:07:54, 13:08:24 on 2026-08-02, all before the
  fix landed at ~13:20; zero since, across hours of clone runs). Read the fault
  addresses: they all end in **`018`**, and offset 0x18 = 24 is exactly where the
  seqlock word lives — the very first access after the region was unmapped. It is
  NOT the 1280->1288 geometry growth: the consumer only ever indexes with the
  dimensions it mapped for, and re-maps before using new ones. The reader now
  additionally re-maps on a stride change (5120 -> 5152, not just w/h) and
  bound-checks `pixel_bytes_needed(w,h,stride)` against the real mapped length on
  every frame, so a torn or garbage header from the producer can only cost a
  skipped frame, never a fault. Verified with streamhost attached from t=0 across
  a cold boot: `[shmcap] first frame 1280x1024` -> `[shmcap] geometry 1280x1024
  stride 5120 -> 1288x1024 stride 5152` -> the encoder re-opens at 1288x1024, no
  fault.
- **Dead reckoning cannot self-correct at a screen edge**, in any transport.
  The guest clamps, the model does not, and commanding the edge again is a zero
  delta. `MameCmdSink` adds a one-shot full-surface slam on edge ENTRY (never
  while parked). The `x11test` sink has the identical weakness and no such fix.
- **An oversized emulated-mouse delta wedges the guest pointer permanently.**
  `hle_ps2_mouse::sample()` transmits the axis difference as a single 8-bit
  value; a `-8192` slam applied in one shot moved the cursor +208 px and IRIX
  then ignored pointer input for the rest of the session — no later `MOVE`, of
  any size, moved it again. Reproduced twice, on two separate boots. This is why
  `MOVEP` exists and why the pacing budget is per emulated-time window rather
  than per Lua tick (the Lua periodic callback fires at 60 Hz of emulated time,
  well above the 100 Hz mouse sampling, so a per-tick budget still merges).

  **Root-caused and fixed 2026-08-03 — and pacing was never the whole story.**
  The agent seeded its accumulators at 32768 while the device's differencing
  state (`m_mouse_x`, seeded from the same ioports, whose MAME default is 0)
  starts at 0, so the FIRST pointer motion of every session handed the device a
  ~32768-count delta no amount of pacing could prevent. Measured on a clean
  boot: `OVERFLOW dx=-32668 dy=32708` on the very first `MOVEP`. The agent now
  seeds at 0, and `mame-hle-ps2-mouse-carry.patch` makes the device carry an
  over-range delta instead of truncating it, so the failure class is closed at
  the device rather than depending on every producer behaving. Full record,
  including the A/B and why the keyboard looked dead too, is in
  `docs/guests/irix.md`.


### Pointer conservation vs the XTest path (2026-08-02, golden v3)

The golden-rebuild agent measured the XTest route losing 12-16% of motion under
demo load — motion dropped, not scaled, which any dead-reckoning scheme
accumulates without bound. **The ioport `MOVE` route does not have that
problem.** Measured through the production `InputRouter` on `irix65-apps-v3.chd`
at the 4Dwm desktop, 100-event sweeps across the full screen width:

| condition | commanded | applied to ioport | cursor pixels |
|---|---|---|---|
| 60 events/s, 10 px steps | 1000 | 1000 (1.000) | 1000 (1.000) |
| 200 events/s, 5 px steps | 1000 | 1000 (1.000) | 1000 (1.000) |
| 60 events/s under guest load (`find /`) | 1000 | 1000 (1.000) | 1000 (1.000) |

It is lossless by construction: the agent QUEUES counts rather than sampling a
level, and `hle_ps2_mouse::sample()` leaves `m_mouse_x` untouched when it skips a
report, so a delta the device could not send is delivered later rather than
dropped. Acceleration was verified the way it should be — `xset q` run in a
desktop Console opened *through this pointer route*, showing
`Pointer Control: acceleration: 1/1  threshold: 0` (v3 bakes `xset m 1/1 0`;
`xset m 0 0` would set a zero numerator instead of unity).

Caveat: the load arm used a recursive `find /` (CPU/IO), not the graphical demo
load of the original observation. Re-measuring under a running General Demo
would close that gap; the structural argument and the 200 events/s arm both
point the same way.

Two agent limitations found while driving the desktop, worth knowing before
scripting against it: `natkeyboard:post` (the `POST` verb) silently drops
capitals, `_`, `|`, `>` and `&`, so shell one-liners must be plain lowercase; and
4Dwm is pointer-focus, so the pointer must be parked over a window before typing.

## Black-screen hang — investigation STOOD DOWN 2026-08-02 (where the trail stops)

Scoping decision, not a dead end. The **boot watchdog is live and validated in
production** (it fired on a real hang, relaunched and recovered; and it correctly
did *not* fire on the single transient black frame every healthy boot passes
through). That reduces the visitor-visible failure probability to negligible,
which is what actually matters. Getting from here to a proven root cause needs on
the order of hundreds more boots at ~5 min each.

### Final tallies

| arm | design | result |
|---|---|---|
| phase 1 (`b`) | base golden, no frameskip, 1 stream | 1 hang / 13 |
| `q` | control / vc2fix / no-frameskip, 20 per cell | 2 / 1 / 1 hangs — no effect from either variable |
| `g,r,s,t,u,w` | baseline accumulation | 4 hangs / 44 |
| `k,m` | clock PINNED vs unpinned, interleaved | **0 hangs / 36** (18 per cell) |

Pooled baseline **~7%**. Be careful with the last row: 0/36 where ~7% predicts
~2.5 events is mildly unusual (p≈0.07) but **cannot** be read as "pinning the
clock fixed it" — *both* cells were clean, so the clock is not what separated
them, and box load changed a lot over that window. It is not evidence either way.

### Ruled out, with evidence — do not re-litigate

- **VC2 stale timing decode** — a real MAME inaccuracy (proven: IRIX writes
  ~4,500 timing-RAM words after its last register-0x00 write) but **not the
  cause**: a captured hang holds geometry at 1288x1024 for all 180 samples
  through the blackout, and the patched binary hung anyway.
- **`-frameskip 6` amplification** — 2/20 vs 1/20 interleaved. No effect; the
  earlier suspicion was an artefact of comparing runs taken hours apart.
- **RTC nondeterminism** — two genuine MAME bugs found and patched
  (`mame-ds1386-date-from-day.patch`); the clock now pins deterministically with
  `-rtc`. Whether it affects the hang is untested at useful N.

### Where I would pick it up

1. **Guest-side X/session hypothesis — highest value, instrumentation already in
   place.** Geometry staying correct means MAME is faithfully scanning a
   framebuffer IRIX itself left black, so the fault is very likely inside the
   guest. `trial.sh` now preserves a hung boot's overlay as `hang-disk.chd` AND
   holds it for `ARM_HANG_SOAK` (default 900 s) before killing, so emulated time
   runs well past where a healthy boot reaches the chooser (~emu 110). Then
   `irix-forensics/hang-forensics.sh <hang-disk.chd>` reads
   `/var/X11/xdm/xdm-errors`, `xdm-pid` and `/var/adm/SYSLOG` out of it in ~10 s.
   **The soak has never been exercised on a real hang** — the one hang captured
   before it existed was killed at emu 77, where a *healthy* boot has not started
   xdm either, which is exactly why that comparison proved nothing. One hung boot
   with the soak active should settle "X never started" vs "X started and painted
   black".
2. **Start-time correlation.** Three hangs were exactly the three trials launched
   in the same second, while staggered-but-concurrent boots passed. Two
   synchronised batches of 3 afterwards came back 3/3 OK, so it is not a
   reproducer — but it was never chased to conclusion. `syncbatch.sh` runs the
   experiment; ~10 batches would settle it.
3. **Clock-pinned rate**, if 1 and 2 come up empty — but only with N in the
   hundreds, which is why it stopped here.

The ds1386 patch is **not** in the production MAME binary; only the trial rig
used `-rtc`. The exhibit is unaffected either way.

### Reusable assets left behind

`/data/vms/soltest/irix-boot-trials/` — `trial.sh` (one namespaced trial,
framebuffer-classified, clone-guard kills, overlay preservation + hang soak),
`runner4/5/6.sh` (interleaved arms; **always build control and treatment from one
tree** — an earlier arm compared binaries that also differed in an unrelated
patch and showed a 2x speed difference having nothing to do with the variable
under test), `syncbatch.sh`, `probe.lua` (per-second emu/PC/geometry plus
emulated-time snapshots), `results*.txt`, and 4 preserved `hang-disk.chd`
overlays. `/data/vms/soltest/irix-forensics/hang-forensics.sh` reads a guest's
logs out of any overlay. `scripts/build-guests/irix/irix-park-desktop.sh` parks a
clone at a real 4Dwm desktop unattended.


## Cutover done (2026-08-02) — and what it turned up

The tile is LIVE on `SH_CAPTURE=shm` + `SH_INPUT_BACKEND=mamecmd`. Operator
description, the verification table and the rollback procedure are in
`docs/guests/irix.md`; this records the things a future session would otherwise
have to rediscover.

- **The live MAME binary was three adopted patches behind.** It was
  `a33944d3` = skip-warnings + 256 MB RAM only. `mame-indy-drc-cache-256mb`
  (+15% idle), `mame-newport-dirty-frame-cache` (+74% static) and
  `mame-ds1386-date-from-day` were all committed to the repo as adopted and had
  never been promoted to `/data/vms/streamhost/assets/irix/mame/sgi`. Landing a
  patch in `scripts/build-guests/` is not the same as shipping it — check the
  binary's md5 against the perf tree's build products before assuming.
- **`verify-emit.sh` is red fleet-wide, and was before this work.** Live tiles
  carry hand-tuned `SH_BUFSIZE_RATIO` / `SH_ABS_PACE_MS` / `SH_WARPD_PACE_MS` /
  encoder-preset values the manifest does not emit. That is why the irix emit
  was done as a SINGLE `streamhost-tile.sh` invocation and not by running
  `tiles-manifest.sh`: a full emit would have clobbered every one of those.
- **`build-deploy.sh`'s `.last-harvest` marker was stale** (its digest is over
  ABSOLUTE paths, so it must be computed exactly as the script does). Before
  refreshing it, the box's mirrored source was verified file-by-file to match
  commit `392242c` — i.e. a clean committed state with nobody's uncommitted work
  in it. Refresh it only after that check.
- **rsyncing `streamhost/scripts/` to the box drops the exec bit** if the repo
  copies are not `+x`, and `ExecStartPre` then fails 126 and the tile flaps.
  `chmod 755` after any such sync.
- **`-video none` still initialises SDL video.** A stale `DISPLAY` pointing at
  an Xvfb that no longer exists kills MAME with `Could not initialize SDL x11
  not available`, so `x11-runtime.sh` now `env -u DISPLAY -u SDL_VIDEODRIVER`s
  in shm mode.
- **`systemctl restart streamhost@irix` is a full tile reset**, not a
  daemon-only restart: `ExecStop` runs `stop-tile-x11.sh`, which kills MAME by
  pidfile. The `ensure-tile-x11.sh` idempotence only spares the emulator on a
  start WITHOUT a preceding stop. Budget ~5 min of cold boot for any restart.
- **Golden v3 renders the `EZsetup` chooser icon as colour noise.** Confirmed
  NOT caused by the new binary or the shm path: the OLD production binary on the
  same golden over the x11 path shows the identical corruption. It is a property
  of `irix65-apps-v3.chd` and belongs to whoever rebakes the golden. Only the
  chooser is affected; the desktop the exhibit shows is clean.

## Serial exec channel + the agent golden (2026-08-03)

`labctl exec irix "<cmd>"` now returns REAL captured stdout+stderr and the
guest's own exit code. Design, protocol and the full trap list live in
`streamhost/guest-agents/irix/README.md` and `docs/guests/irix.md`; this section
is only what a resumer needs to know.

**Status: built, verified, STAGED — the live tile is untouched, and the
capability is NOT declared.** `registry/tiles/irix.json` keeps `exec_kind: null`
until the cutover, so nothing advertises a channel the live tile does not have.
The golden carrying the agent is `irix65-apps-v3-serial.chd`
(`f8c67f03ccb19ee979d7aadbd60499d7`; `irix65-apps-v4.chd` was the first bake and
speaks the withdrawn `irixser/1`. It is NOT called v5 — the concurrent
`irix-network` work took that name on the same box the same day). Cutover is one
launcher deploy + one golden swap + the registry flip, spelled out in
`docs/guests/irix.md`. `irix65-apps-v3.chd` is still
`368fcfb9b56fb4165a4e456238dc1a18` and is what the exhibit runs.

**`irixser/1` was withdrawn after review.** Four defects, all now covered by
`scripts/build-guests/irix/irix-serial-selftest.py` (which fails on /1 and passes on
/2): the framing sat outside the checksum, so a mangled id became a bogus
timeout; `RESULT` replayed under the ORIGINAL id, so a client could return
truncated output with a SUCCESS status; requests were not checksummed at all, so
a dropped byte ran a different command and reported success; and guest bytes
>= 0x80 were transcoded to UTF-8 on the way out. `irixser/2` checksums both
directions with the framing inside the sum, replays under the requester's id,
NAKs a request it will not run (a RUN is idempotent in its id, so the re-send is
safe), and writes bytes.

### The shape

MAME `-ioc2:rs232a pty` == IRIX `/dev/ttyd2` (free: `t2` in `/etc/inittab` ships
`off`), a Perl 5.004 agent under an inittab **respawn** entry, and
`/root/irixexec.py` on the host behind `exec_kind: "serial_e"`. `ioc2:rs232b` is
`/dev/ttyd1` with the `t1` console getty — production leaves it unpopulated; the
bake rig wires it and uses it once, to type the agent in.

### What cost time, so it does not cost it again

- **A login prompt was already sitting on serial port 1 the whole time.** The
  bootstrap needed no ISO and no key matrix — `t1` respawns a getty and root's
  password is empty. Recon expected the opposite.
- **MAME's `socket.` bitbanger accepts exactly one connection per run** and then
  closes its listener for ever (`ss` shows no LISTEN afterwards). That single
  fact rules out the obvious "give it a TCP port like the other tiles" design.
  `pty` has no accept semantics; its slave name is only in `/proc/<mame>/fd`.
- **MAME's SCC drops TRANSMITTED bytes** unless the guest writes <= 4 at a time
  with a pause. It is the write size, not the rate. Throughput is 139 B/s
  (sleeping) or 267 B/s (busy-loop), against the 960 B/s the 9600-baud line
  could carry. Fixing `z80scc.cpp` is the way to lift it; that is a separate
  change with its own binary cutover.
- **While the guest is echoing, MAME drops bytes it RECEIVES.** Every host->guest
  bulk transfer must turn the guest's echo off first — and `/etc/profile`'s
  `TERM = (vt100)` prompt eats the line you were going to do it with.
- **TWO agents on one line look exactly like wire corruption.** An `X 265` came
  back as `X 3,5`; the cause was two agent processes interleaving their 4-byte
  paced writes, after an install killed the wrapper but not the perl and init
  respawned a second one. The agent now holds an `flock` for its whole life and a
  second instance declines to start (a PID lock is not enough here: the write is
  not atomic — a lock reading `/70` for pid 970 was observed — and the boot pid
  is deterministic, so a stale pid baked into a golden would disable the agent
  for ever); the installer stops the old one through init and asserts a
  single process. Every reply line also carries a 16-bit checksum and there is a
  `RESULT` verb to replay a bad reply (re-fetch, never re-run) — that check is
  what made the diagnosis possible, so do not remove it.
- **`/sbin/killall` in an IRIX guest is the SHUTDOWN HELPER.** It signals every
  process on the machine, not processes matching a name. It took a clone down.
- **`.strip()` on a protocol line is data loss.** It ate four bytes out of an
  otherwise byte-exact `/etc/inittab` transfer, at a chunk boundary that landed
  inside an indent.
- **X clients block at the `iconlogin` chooser** — xdm holds the server grabbed.
  `xdpyinfo` never returned in 10 minutes. Log in first, and always pass a
  timeout.

### Rig left behind (reusable)

`scripts/build-guests/irix/irix-serial-rig.sh` (boot / exec / console / shot / halt a
namespaced clone with the channel wired, with black-screen-hang retries and
readiness measured by the CHANNEL answering, not by a timer) and
`irix-serial-install.sh` (bake + `cksum` verification on both sides). Clones live
under `/data/vms/soltest/irix-serial/<name>` and every kill goes through
clone-guard.

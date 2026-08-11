# SGI Indy, MIPS R4400 — IRIX 6.5 under Iris (`indyr4400` station)

The gallery's **second** SGI Indy, and the first station to run
[Iris](https://github.com/techomancer/iris) (BSD-3), a userspace Rust emulator
of the Indy. It is a deliberate pair with the [`irix`](irix.md) station rather
than a duplicate of it:

| | `irix` | `indyr4400` |
|---|---|---|
| Machine | SGI Indy, **MIPS R4600** @ 100 MHz | SGI Indy, **MIPS R4400** |
| Emulator | MAME `indy_4610` | Iris (`techomancer/iris`, `main`) |
| Launcher | **x11 launcher, BARE METAL** — MAME's Indy emulation kernel-panics under a KVM vCPU | ordinary **KVM kiosk** — Iris is pure userspace and has no such constraint |
| Capture | `SH_CAPTURE=shm`, 1288x1024 emulated framebuffer | Linux framebuffer of a Debian kiosk, 1280x1024, 1:1 |
| Input | `mamesock` → MAME ioport | plain QEMU PS/2 (relative) → guest X → Iris |
| Reset | `relaunch` (+ captured MAME savestate) | `loadvm golden` |

Both run the same IRIX 6.5.22 install — this station's disk is literally derived
from the `irix` station's seed CHD (see *Media* below).

## Status

**Live production station** (added 2026-08-10). Slot 136, UDP 54136, ssh 5839,
VMID label 239, archetype `beige-tower-crt`.

## Acceptance criteria

- Iris `main` @ `1e05210`, features `lightning,rex-jit,chd`, BSD-3.
- IRIX 6.5.22, MIPS R4400, 256 MB (`banks = [128, 128, 0, 0]`), XL 24-bit.
- Pinned QEMU: `qemu-system-x86_64`, `pc-i440fx-11.0,vmport=off`, KVM,
  `-cpu host`, 2048 MB, 4 vCPU, `-vga std`, `-display dbus,p2p=on`, IDE
  overlay + a READ-ONLY virtio raw asset, `e1000` with an ssh hostfwd, no
  audio device, no usb-tablet.
- Framebuffer proof: the Indigo Magic Desktop (4Dwm) with the Toolchest docked
  top-left and the `demos` icons down the right edge, **exactly 1280x1024**.
- Reset: `loadvm` with snapshot `golden`.
- Pointer: **relative** (Pointer Lock). Visible motion + click proof.
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
verified by `streamhost/tiles/indyr4400/fetch-assets.sh`; recorded in
[`../lab/ASSETS-MANIFEST.md`](../lab/ASSETS-MANIFEST.md).

### Why an ext4 wrapper and not the bare raw disk

The station attaches the asset as a second, read-only virtio drive so the 6.3 GB
never enters the station's qcow2 overlay. Iris sizes a SCSI disk with
`File::metadata().len()` (`src/scsi.rs`), which is **0 for a block device**, so
it cannot be pointed at `/dev/vda`. The guest mounts the ext4 read-only at
`/srv/irix`, and `/var/lib/iris/disk.raw` is a symlink to the file inside it.
Iris runs with `overlay = true`, so its copy-on-write file
(`/var/lib/iris/disk.raw.overlay` + its `.dirty` sidecar) lands on the guest's
own writable disk — inside the station overlay, and therefore inside the `golden`
snapshot. Read-only drives are invisible to `savevm`, so the checkpoint stays
small (1.1 GiB vmstate, 702 MB overlay total) and the asset can never be
dirtied. IDE is not usable for the asset: QEMU has no read-only IDE hard disk
(`Block node is read-only`).

## Build

`scripts/build-guests/tiles/indyr4400.sh` — a thin overlay on the frozen
bridge base, same shape as `amiga.sh`.

### The iris binary is built against bookworm, not against the host

The lab box is Debian 13 (trixie, glibc 2.41); the frozen bridge base is
Debian 12 (bookworm, glibc 2.36). A host-built `iris` dies in the guest with

```
/usr/local/bin/iris: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
/usr/local/bin/iris: /lib/x86_64-linux-gnu/libm.so.6: version `GLIBC_2.38' not found
```

The builder therefore `debootstrap`s a throwaway bookworm chroot, installs
`build-essential pkg-config libasound2-dev` plus rustup there, and copies only
the resulting 64 MB binary into the overlay — **no Rust toolchain is ever
installed in the station**, and `CARGO_TARGET_DIR` is unset inside the chroot so
the build does not touch labhost's shared cargo target tree. Measured build:
**6 m 30 s** on the 16-core host. Runtime deps beyond the base are
`libxkbcommon-x11-0`, `libxcb-xkb1` and `xdotool`.

## Four traps this station sprang, in the order they cost time

### 1. No window manager ⇒ no X input focus ⇒ a silently dead keyboard

The kiosk runs a bare X root with no WM, so nothing ever calls
`XSetInputFocus` and the focus stays `PointerRoot`. Iris is a **winit** app,
and winit drops `WindowEvent::KeyboardInput` for a window it does not consider
focused. Every other kiosk is SDL and does not care.

The symptom is nasty because it is asymmetric: the **pointer keeps working**
(winit takes it from XI2 `RawMotion` device events, which ignore focus), so
the exhibit looks completely alive while nothing typed ever arrives. The keys
do reach the guest — the guest kernel's i8042 IRQ 1 counter increments on every
press — they are simply discarded one layer above.

`launch.sh` fixes it by focusing the window explicitly once it appears:

```bash
( for _ in $(seq 1 90); do
    W=$(xdotool search --class iris 2>/dev/null | head -1)
    if [ -n "$W" ]; then xdotool windowfocus "$W" 2>/dev/null && break; fi
    sleep 1
  done ) &
```

The X focus is server state, so it is inside the `golden` snapshot and every
restore comes back with the keyboard live.

### 2. QEMU's VMware backdoor eats the relative pointer

With the default `vmport=auto`, Linux's `psmouse` negotiates the **VMMouse
absolute** protocol and the guest enumerates two `VirtualPS/2 VMware VMMouse`
devices. This station has no absolute host device (no usb-tablet — Iris wants
relative deltas), so the relative PS/2 packets reach the guest kernel (IRQ 12
counts up) and then **never move the X pointer**. The device set pins
`-machine pc-i440fx-11.0,vmport=off`; the guest then enumerates a single
`ImExPS/2 Generic Explorer Mouse` and motion works.

### 3. Bursts of unpaced QMP `input-send-event` overflow the PS/2 queue

While bisecting the above, an unpaced burst of 37 relative events moved the
IRIX cursor by 6 px — which looks exactly like a dead axis. QEMU's PS/2 queue
is small; 20 ms between events makes both axes track cleanly. streamhost paces
at frame rate, so this only bites hand-written QMP harnesses. Note also that
**IRIX applies its own pointer acceleration** (measured ~3.5x horizontal,
~3.3x vertical from a corner slam), and it is history-dependent, so
open-loop absolute positioning does not converge — slam to a corner first.

### 4. Re-emitting strips the launcher's exec bit

`streamhost-tile.sh --launcher-file "$T/indyr4400/qemu-streamhost.sh"` copies the
tracked launcher onto itself (the tracked sidecar and the runtime path are the
same file for a verbatim station), which errors with `cp: ... are the same file`
and leaves the file **non-executable**. `ensure-tile-qemu.sh` then refuses with
`missing launcher: ...` and systemd restart-loops the unit while
`/signal/<tile>.json` keeps answering 200 from the still-published map. After
any re-emit: `chmod +x /data/vms/streamhost/tiles/indyr4400/qemu-streamhost.sh`.

## Pointer

Relative, by design and settled: Iris grabs the pointer on the **first left
click inside its window** (`CursorGrabMode::Locked`, falling back to
`Confined`) and from then on feeds the emulated Indy PS/2 deltas taken from
`DeviceEvent::MouseMotion`. **Right-Ctrl releases the grab.** The registry
declares `stream.pointer.transport = "rel"` and `spa.pointerRel = true`, so the
UI drives it through Pointer Lock (the derived `relativePointerOnly` grid
badge is correct and intended). Absolute positioning would need work inside
Iris and is explicitly out of scope for this phase.

## Checkpoint

`resetMode: loadvm`, snapshot `golden`, captured at the **Indigo Magic Desktop**
of the `demos` session — Toolchest docked upper-left, the demos/fsn/buttonfly
icon column down the right edge, nothing else open.

Proof, sampled at a fixed machine instant so a blinking cursor cannot make two
captures of the same state differ:

```
stop ; loadvm golden ; stop ; screendump out.ppm ; cont
```

Two such captures either side of a dirtying pointer run were **byte-identical**
(`c7ce2397c12dc6e99bdd85918f0ffa31`), while the dirtied frame differed
(`9759f8a191e8323e5933ed47d6197927`). A click on the Toolchest after a restore
highlights it, so input is live immediately after reset.

Cold boot (no checkpoint) takes **~7 minutes**: PROM, IRIX autoconfig — IRIX
re-links its kernel because Iris's hardware differs from MAME's, and the COW
overlay's `.dirty` sidecar is only flushed on a clean exit, so a killed
emulator loses the autoconfig and redoes it — then the graphical login. This
is why the station ships `-loadvm golden`.

## Measured cost

| | |
|---|---|
| `iris` in-guest | **~310-320 % CPU**, RSS ~528 MB, steady state at the desktop |
| station QEMU (host view) | ~150 % CPU, RSS ~1.15 GB |
| overlay.qcow2 | 702 MB (1.1 GiB vmstate inside it) |
| asset | 6.4 GB apparent / ~500 MB allocated (sparse) |

Iris is the most expensive emulator in the lineup, so this station deliberately
**does not** override `SH_IDLE_PAUSE_SECS`: it takes the fleet default and is
QMP-paused when no visitor is attached. Do not copy the amiga/gt40/irix
`SH_IDLE_PAUSE_SECS=0` stanza onto it.

## Known gaps / not done in this phase

- **Networking is parked.** IRIX reports `ec0: machine has bad ethernet
  address 00:00:00:00:00:00` and falls back to standalone mode. The fix is a
  one-time PROM step (`setenv -f eaddr 08:00:69:xx:xx:xx`, then `rtc save`
  from Iris's monitor console on `127.0.0.1:8888`) captured into `nvram.bin`. It
  was attempted and **not** landed: interrupting the PROM countdown needs keys
  delivered before the X focus fix exists in a cold boot, and 60 s of `Esc`
  through QMP did not catch the window. The transient "Cannot access primary
  interface / Using standalone network mode" dialog clears itself before the
  login, so it is not in the checkpoint.
- **Audio is off** (`--noaudio`, no AC97 in the device set). IRIX HAL2 audio
  through Iris is untested here.
- The emulated framebuffer is **1282x1024** and Iris's window is 1282x1040 —
  the extra 16 rows are Iris's own status HUD (`18.5 MIPS 966Hz NET: … SCSI: …
  LED:`). The X root is pinned to 1280x1024 at `+0+0`, which clips both the HUD
  and the 2 overscan columns, so the visitor sees the machine and not the
  emulator. Do not "fix" the root to 1282x1040.
- `reset.mouse` / `reset.keyboard` are `UNVERIFIED` in the registry: both are
  proven by framebuffer here, but not yet through the real UI in a browser.

## Rollback

The station is self-contained. `systemctl stop streamhost@indyr4400`, kill the
QEMU by `/data/vms/streamhost/tiles/indyr4400/qemu.pid`. Nothing it touches is
shared except the frozen bridge base (read-only backing) and the `irix` station's
CHD, which is only ever read via a copy at asset-build time.

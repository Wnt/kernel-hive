# NeXTSTEP 3.3 — live streamhost tile `nextstep` (VMID 237, udp 54134)

**Status: LIVE (relative pointer). The absolute-tablet promotion is landed in
the repo but NOT deployed — see §9.** A captured Debian-12 kiosk runs the **Previous** emulator as a
**NeXTcube** (Motorola 68040, 25 MHz, 64 MB, ROM Rev 2.5 v66) booting **NeXTSTEP
3.3 for m68k**, and streamhost captures the Linux framebuffer + AC97 audio like
every other bridge tile (`streamhost/docs/BRIDGE.md`). The acceptance fixture —
the grey NeXTSTEP Workspace with the right-hand Dock — is reached on an
untouched cold boot with zero input and is framebuffer-verified in
`/data/vms/streamhost/tiles/nextstep/evidence/`.

Builder: `scripts/build-guests/tiles/nextstep.sh` (fully automated, `--force`,
idempotent). Runtime sources: `streamhost/tiles/nextstep/`. Patch:
`scripts/build-guests/patches/previous-wmless-window-borders.patch`. Kiosk helper:
`scripts/build-guests/stages/nextstep-kiosk-frame.sh` == guest
`/usr/local/bin/nextstep-kiosk-frame.sh`.

---

## 1. Why this is a NeXTcube and not an Intel PC

The historical section below records, in full, that **NeXTSTEP 3.3 for Intel
cannot be installed or run on a modern QEMU**. That finding still stands and was
not re-tested. What changed is the gallery's architecture: every recent exhibit
is a *bridge* tile, so the kiosk can run any emulator, and the QEMU driver wall
simply stopped being the constraint.

Two routes were costed before anything was built:

| Route | Machine | Cost | Verdict |
|---|---|---|---|
| **(a) Previous + m68k NeXTSTEP** | the real NeXTcube | emulator builds in ~9 min; the disk image is **pre-installed**, so no 1994 installer to drive | **chosen** |
| (b) QEMU 0.9.0 built in the overlay + Intel install | a PC clone | build an ancient QEMU, then sit through an interactive install, then discover whether the result boots | rejected |

Route (a) also wins on media: the NeXT ROMs ship **inside the Previous source
tree** (`src/Rev_2.5_v66.BIN`), byte-identical to the ones in the archive.org
bundle, so only the disk image has to be fetched. And it is the better exhibit —
a matte-black cube with a MegaPixel display is the machine Tim Berners-Lee wrote
the first web browser on; an Intel clone running the same OS is not.

## 2. What is built, and where

Nothing in the frozen bridge base is touched. Everything goes into the tile's
own overlay:

| Component | Version / pin | Note |
|---|---|---|
| SDL3 | 3.4.14, from source | Previous 4.4 needs SDL3 ≥ 3.2; Debian 12 has SDL2 only. `libxtst-dev` is required or cmake aborts with *Couldn't find dependency package for XTEST*. |
| Previous | SourceForge SVN **trunk r1847** = release **4.4** (2026-07-06) | built with `-DENABLE_RENDERING_THREAD=1` — see trap 4 |
| NeXT ROM | `Rev_2.5_v66.BIN`, sha256 `1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4` | from the Previous source tree; 68040 non-turbo cube/station ROM |
| NeXTSTEP disk | `NS33_2GB.dd`, sha256 `6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b` | 2 GB sparse (≈232 MB on disk), pre-installed NeXTSTEP 3.3 for m68k |

Media provenance is recorded in `docs/lab/ASSETS-MANIFEST.md` and in the guest's
`/opt/bridge/media/nextstep/PROVENANCE`. **The bits are never committed.**

The overlay is grown to 16 GB before first boot: the 6 GiB base has only ~2.6 GiB
free and the disk image alone is 2 GB.

## 3. Emulated machine and X geometry

```
Previous 4.4, ~/.config/previous/previous.cfg (written by the builder)
  nMachineType = 1        NEXT_CUBE040 — NeXTcube, 68040 @ 25 MHz, non-Turbo
  bColor = FALSE          MegaPixel 1120x832, 2-bit greyscale
  Memory 16+16+16+16      64 MB
  nSCSI = 1               NCR53C90A;  nBootDevice = 1 (SCSI)
  szRom040FileName        Rev_2.5_v66.BIN
  bEthernetConnected      TRUE, SLIRP (stops NeXTSTEP waiting on a netinfo server)
  bShowStatusbar/Titlebar FALSE;  bFullScreen = FALSE (windowed on a bare X root)
```

The kiosk adds a **custom 1120x832 X mode** with `xrandr --newmode` — no stock
mode is that size — and makes the root exactly that. This is deliberate:

- the picture is pixel-exact, with no resampling of a 1-bit-crisp Display
  PostScript UI;
- the host pointer and the NeXT arrow clamp at the *same* edges, which is what a
  relative pointer needs to stay in registration.

## 4. Pointer: absolute, through the machine's own tablet

Previous emulates more than a mouse. `src/tablet.c` simulates a SummaGraphics
MM 961/MM 1201 digitiser (and the WACOM SD series) on the NeXT **SCC serial port
B**, and `src/gui-sdl/sdlevent.c` feeds it the host's **absolute** window
coordinates whenever `[Tablet] nTabletType` is non-zero *and* the guest driver
has enabled the tablet; only otherwise does it fall back to the relative
`kms_mouse_move()`. NeXTSTEP 3.3 ships the matching driver on the disk the tile
already uses — `/NextAdmin/InstallTablet.app`, setuid root, 21 Oct 1994 — which
writes a kernel-server relocatable to `/usr/lib/kern_loader/Tablet/`, loads it,
creates `/dev/tableta`+`/dev/tabletb`, probes `/dev/ttyb` and attaches. Nothing
is compiled: this golden carries no m68k toolchain at all.

So the tile ships:

- `nTabletType = 2` in `previous.cfg` (SummaGraphics MM 1201);
- `-usb -device usb-tablet`, `SH_INPUT_BACKEND=dbus-abs`, SPA `pointerRel`
  absent, `stream.pointer.method = qemu-usb-tablet`;
- `-machine …,vmport=off` still pinned — it used to protect the relative path,
  and it now keeps QEMU's implicit VMware mouse from being a *second* absolute
  pointer competing with the tablet;
- an X root of **exactly 1120x832 at +0+0**. That is now load-bearing: the whole
  chain is a straight 1:1 map from the X root to the NeXT screen, so any other
  root size silently scales every visitor's click.

**Measured, on the production tile:** 24 of 24 acceptance targets (corners inset
8 px, edge midpoints, centre, and 15 scattered points) landed at **0 px** error,
one commanded move each, located by an exact glyph match on the framebuffer.
Click and drag were proven the same way — a Workspace icon selects, and the File
Viewer's title bar drags 1:1 and lands where it was let go.

**The one asymmetry, stated plainly.** The driver is a kernel server loaded at
install time; Previous's own README warns it must be reinstalled after every
*boot*. `loadvm golden` is not a boot — it restores RAM and device state — so the
golden keeps the driver for every visitor and every reset, which is exactly why
this fits the exhibit's reset model. **A COLD boot does not have it** and falls
back to Previous's relative mouse, which against an absolute usb-tablet is not a
usable pointer. The tile only ever cold-boots when the golden is missing (i.e.
the fixture is gone and the tile is being rebuilt anyway), and the recovery is
one command:

```bash
ssh lab 'python3 scripts/build-guests/nextstep-tablet-install.py'   # from a repo copy on the box
```

which is the same automation `scripts/build-guests/tiles/nextstep.sh` runs
between its last cold boot and `savevm golden`. It is deliberately NOT wired into
the kiosk's boot path: it drives the guest GUI, and nothing should be clicking
around inside an exhibit a visitor may already be watching.

**How the install is driven, since it cannot be scripted from a shell.**
NeXTSTEP refuses a DPS connection to a telnet session (`DPS client library
error: Could not form connection, host local host`), so `InstallTablet` cannot be
launched from `nstel.py`; and its panel never becomes the *key* window, so its
default button cannot be reached with RETURN either. The working sequence, all
framebuffer-verified: symlink the app into `/me`, reboot NeXTSTEP so the File
Viewer rescans, **type-select** `Install` in the viewer and press RETURN to open
it, then walk the still-relative pointer onto the panel's Install button with a
closed loop on the cursor glyph and click once. From that click on, the pointer
is absolute and the rest (quit, unlink, refresh, pixel-diff back to the fixture)
is exact.

**Historical, kept because it explains the old wiring:** before the tablet the
tile ran `--pointer rel` with no usb-tablet, and the NeXT KMS mouse register's
*signed 6-bit* delta capped a single event at 63 px, so a fast flick under-moved.
That limit is no longer on the visitor's path — the tablet reports a position,
not a delta — but it still applies to anything driving the guest before the
driver is attached.

## 5. Key pacing: not applicable

This is a GUI exhibit, not a type-in exhibit. The NeXT keyboard is a serial
device polled by the KMS controller, not a matrix sampled once per emulated
frame, so playbook §5.1's `SH_KEY_MIN_HOLD_MS` / `SH_KEY_MIN_GAP_MS` are not set
and the tile does not need the pacing canary build.

## 6. The five traps, in the order they bit

1. **`panic: (Cpu 0) Root device is physically write protected.`** NeXTSTEP
   boots, finds the disk and dies on its first write. The kiosk runs as
   `bridge`, and a root-owned 0644 image opens read-only — the same trap the
   pdp11 tile hit with its MSCP pack. `chown bridge:bridge NS33_2GB.dd`.
2. **`SDL screen scale: 0.971`.** Previous asks SDL for the window border
   thickness and, when SDL cannot answer, assumes a decorated desktop (50 px top
   and bottom, 25 px each side) and shrinks the emulated screen to fit. There is
   no window manager here, so it always assumed them and resampled 1120x832 down
   to 1088x808. Fixed by
   `scripts/build-guests/patches/previous-wmless-window-borders.patch`.
3. **No input at all.** With no window manager nobody ever calls
   `XSetInputFocus`, so the X input focus stays `None` and SDL3 hands Previous no
   key events; and because the pointer is already inside the window when it is
   mapped, no `EnterNotify` is generated either, so SDL never acquires a mouse
   focus and drops motion too. The symptom is a perfectly live NeXTSTEP that
   ignores every keystroke and never moves its cursor, with nothing in any log.
   `nextstep-kiosk-frame.sh` focuses the window and walks the pointer out and
   back in. It also re-anchors the window at +0+0 (SDL3 centres it at +16+12 on
   a same-sized root, clipping the Dock) and **re-resolves the window id every
   pass**, because Previous destroys and re-creates its window on a mode change.
4. **Input reaching Previous but not the machine.** Previous 4.4 built with
   `ENABLE_RENDERING_THREAD=0` — the default everywhere except macOS — pushes
   guest key/mouse events onto an internal ring buffer, and on this build
   nothing drained it: at `nTextLogLevel = 5` a clean single keystroke produced
   no `[Keymap]` line at all, while Previous's own F12 menu (handled before the
   queue) opened normally. Rebuilt with `-DENABLE_RENDERING_THREAD=1`, where the
   same events go straight to `Keymap_KeyDown`/`Keymap_MouseMove`, the NeXT
   cursor moved on the next attempt. **The tile must be built with that flag**;
   the builder asserts it in the cmake output.
5. **135% of CPU in four llvmpipe threads.** `SDL_RENDER_DRIVER=software` was
   already set and the renderer really was `software` (SDL3 confirms it under
   `SDL_LOGGING=render=verbose`), but SDL3 still *presented* through an
   accelerated window surface — llvmpipe, on a GPU-less host. Measured before
   and after `SDL_FRAMEBUFFER_ACCELERATION=0`:

   | | llvmpipe threads | `previous` RSS | keystroke → screen |
   |---|---|---|---|
   | accelerated surface | 4, ~135% CPU | 375 MB | 5.7 s, once 33 s |
   | `SDL_FRAMEBUFFER_ACCELERATION=0` | none | 106 MB | 0.58 s (poll-loop floor) |

## 7. Resources, measured

| | |
|---|---|
| QEMU | `-m 1536 -smp 4 -cpu host`, `pc-i440fx-11.0,vmport=off` |
| guest `MemAvailable` at the Workspace | 957 MB of 1462 MB |
| `previous` RSS in the guest | 247 MB |
| host QEMU RSS | 1.06 GB |
| golden snapshot VM_SIZE | 647 MiB |

`-smp 4` is not decoration: Previous runs the 68040, the DSP, a SLIRP thread and
its own present loop, and at `-smp 2` the emulator ran at roughly half real
speed (`[Hardclock] Expected: 8245 us, actual: 15407 us`) and its input queue
visibly backed up.

## 8. Golden fixture and reset

`SH_RESET_MODE=loadvm`, snapshot `golden`: the grey Workspace, the Workspace
menu at the top left, the File Viewer NeXTSTEP opens for itself at login, and the
Dock down the right-hand edge. Nothing is curated — this is where the machine
stops on its own — but the snapshot is **not** taken on an untouched boot any
more: it is taken after §4's tablet-driver install, because a kernel server is
the one thing a cold boot cannot carry. The install automation ends by pixel-
diffing the desktop back onto the frame it started from, and refuses to continue
if too much differs. Restore is verified by framebuffer in the same run.

Evidence in `/data/vms/streamhost/tiles/nextstep/evidence/`:
`coldboot-desktop.png` (the state that was baked), `golden-baked.png`,
`golden-restored.png` (after `loadvm golden`), `live-streaming.png` (with
`streamhost@nextstep` running).

**First boot of a fresh overlay is not zero-input**: NeXTSTEP 3.3 runs its
one-time Welcome panel (language + keyboard) the very first time this disk image
boots. The builder answers it with two RETURNs (English / USA defaults) and then
waits on the Workspace predicate. Every boot after that — and every visitor —
lands on the Workspace with no input at all.

## 9. Open items — stated honestly

- **NOT YET PROMOTED (2026-08-10).** Everything in §4 is proven, and the install
  automation passes end to end on a clone (`driver attached; absolute probe max
  error 0 px`, fixture restored) — but the last step does not converge on the
  TILE. The pre-driver relative closed loop that puts the pointer on the Install
  button lands ~56 px past it, deterministically, where the identical code
  converged twice on the clone. The tile is back on its original golden, still
  `SH_POINTER=rel`; the repo carries the absolute wiring, unde­ployed. Next
  person: instrument `goto()` per step on the tile (it prints nothing today) and
  compare the measured per-event gain against the clone's — the suspicion is that
  NeXTSTEP's acceleration curve is being driven into its superlinear region by a
  step size that is safe on one machine's timing and not the other's, in which
  case the fix is a fixed small step with no proportional term at all.
- The **cold-boot pointer asymmetry** in §4: a cold-booted tile has no tablet
  driver and no usable pointer until the installer is re-run. Documented and
  one command away, deliberately not automatic.
- Only `nTabletType = 2` (SummaGraphics MM 1201) was tried. The WACOM types
  report a finer coordinate range and might behave differently at the edges;
  there was no reason to look.
- Guest-input latency was measured only through Previous's own F12 menu
  (0.58 s, at the floor of a screendump poll loop) and only while the box was
  carrying a load average of 20-45 from concurrent build agents. It should be
  re-measured on a quiesced box.
- `SDL_RENDER_DRIVER=software` alone did not avoid llvmpipe; why SDL3 still
  chose an accelerated window surface was not chased past the workaround.

## 10. Operator notes

- `labctl exec nextstep "<cmd>"` reaches the **Debian kiosk**, not NeXTSTEP.
  For NeXTSTEP itself there *is* now a captured-output channel: Previous
  publishes a fixed SLIRP redirect from the kiosk's `127.0.0.1:42323` to the
  NeXT's telnet port, and `/usr/local/bin/nstel.py` (source
  `scripts/build-guests/nextstep-nstel.py`) drives it. Log in as `me` — NeXTSTEP
  refuses `root` on a pseudo-terminal — and the client `su`s for you; neither
  needs a password.

  ```bash
  ssh lab 'labctl exec nextstep "python3 /usr/local/bin/nstel.py me \"uname -a\""'
  ```

  It is a shell, not a window server: GUI apps launched through it die with
  `DPS client library error: Could not form connection`.
- NeXTSTEP logs in automatically as the user `me`. There is no password prompt
  in the fixture.
- The kiosk writes `/tmp/nextstep-launch.log` (X mode) and
  `/tmp/nextstep-frame.log` (focus + window anchoring); Previous's own stderr is
  `/tmp/previous.err`.

---

# HISTORICAL — the Intel/QEMU-10 dead end (2026, pre-bridge architecture)

*Kept verbatim in substance because it is hard-won and would otherwise be
re-derived. It describes the previous attempt at this tile: NeXTSTEP 3.3 for
**Intel**, installed by QEMU directly, streamed by the retired docker-compose
/ neko stack on port 8109. Both the OS variant and the streaming architecture
are different from what ships today.*

## TL;DR

NeXTSTEP 3.3 for Intel **installs and runs only on QEMU ≤ 0.9.x** (the
busmouse-patched Michael Engel build) or under **Previous**. On QEMU 10.0.8 the
install gets as far as the NeXT Mach kernel booting and **detecting both drives**
(the CD labelled `NEXTSTEP_3.3` and the IDE hard disk), then dies the moment it
starts real bulk I/O:

```
sd0: Bus Reset Detected; FATAL            <- SCSI CD  (lsi53c810)
hc0: interrupt timeout, cmd: 0xc4 ...     <- IDE disk (PIIX3)
hc0: ATA command c4 failed. Retrying..
Load of /etc/mach_init failed, errno 5    <- EIO; installer aborts
Load of /etc/init failed, errno 5
```

Root cause: NeXTSTEP 3.3's 1994-era SCSI/IDE drivers do not get reliable
completion **interrupts / DMA** from QEMU 10 once sustained transfers begin.
Reproduced under **both TCG and KVM**. This matches the public record (gunkies,
emaculation, 86Box #356, PCem, QEMU LP#1471904): "install fails right after the
floppies are read in."

No pre-built NeXTSTEP/OPENSTEP **Intel** disk image exists on archive.org (only
the install media), and a pre-built image would hit the same runtime I/O wall.

## Intel media (unused by the current tile)

Item `NeXTSTEP33CISC` (https://archive.org/details/NeXTSTEP33CISC):
`NeXTSTEP_3.3_User_(i386_m68k).iso` (~356 MB, a 4.3BSD-FFS disc, **not**
ISO-9660 — label `NEXTSTEP_3.3`, 2048-byte blocks) plus the floppies
`3.3_Boot_Disk.img`, `3.3_Core_Drivers.img`, `3.3_Beta_Drivers.img`,
`3.3_Addl_Drivers.img`. No NeXT ROM is used or needed on the Intel path.

## The one QEMU-10 recipe that reached hardware detection

```
qemu-system-i386 -machine pc,acpi=off -cpu pentium -m 64 \
  -rtc base=1995-06-15T12:00:00,clock=vm \
  -drive file=ns33.qcow2,format=qcow2,if=ide,index=0,media=disk \      # HD on IDE
  -device lsi53c810,id=scsi,romfile= \                                 # CD on SCSI
  -drive file=NeXTSTEP_3.3_User.iso,format=raw,if=none,id=cd0,readonly=on \
  -device scsi-cd,bus=scsi.0,scsi-id=0,drive=cd0 \
  -fda 3.3_Boot_Disk.img -boot a -vga std -net none
```

Installer driver selection (framebuffer-validated `sendkey` macro): English(1) →
prepare(1) → insert **Core** (blank list) → insert **Additional Drivers** →
CD-ROM = **Symbios Logic 53C8xx** (page 3, opt 3) → HARD DISK = **IDE Disk
Controller** (page 3, opt 5) → continue(1). The Mach kernel then prints
`sd0: … NEXTSTEP_3.3` and `hd0: … 499 MB`, and then the I/O death above.

Key gotcha: the installer's **CD-ROM** driver menu lists *only* SCSI adapters;
the EIDE/IDE "hard-disk controllers" are hidden there and appear only on the
**HARD-DISK** menu. That is why the CD had to go on SCSI and the disk on IDE.

## Every controller/driver permutation tried

| CD-ROM bus / NS driver | Hard disk bus / NS driver | Result on QEMU 10 |
|---|---|---|
| am53c974 (both devices, 1 target) | am53c974 | phantom 8-LUN scan; **READ CAPACITY = 0 KB**; also QEMU option-ROM exec bug LP#1471904 (dodge with `romfile=`) |
| lsi53c810 (both devices) | lsi53c810 | correct sizes; **reads ~35k blocks then `Bus Reset Detected` → FATAL** |
| lsi53c895a | — | NS **`SYM53C8: Can't find this PCI device; ABORTING`** — PCI id 0x0012 too new for NS driver v3.33 |
| IDE ATAPI (CD) + IDE (disk) | "EIDE and ATAPI Device Ctrl" | detects both, then **hangs for ever at `hc0: Resetting drives..`** |
| **lsi53c810 (CD)** | **IDE "IDE Disk Controller"** | **furthest**: both detected, IDE reset OK, then **IDE `interrupt timeout` + SCSI `Bus Reset FATAL`** → `errno 5` |

Also tried with no effect: TCG vs `-enable-kvm`; a fixed 1995 `-rtc` date (the
`preposterous time in Real Time Clock` warning is cosmetic). Disk kept under
504 MB to avoid NS large-disk CHS traps.

*The retired proposal in this document's earlier revision — a `neko-qemu`
docker-compose service on port 8109, VMID 1040, `NEKO_EPR 53320-53339` — is gone
with the architecture it belonged to. The gallery has run the Rust `streamhost`
daemon with per-tile systemd units since; there is no compose stack to wire into.*

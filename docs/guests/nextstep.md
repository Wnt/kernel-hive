# NeXTSTEP 3.3 — live streamhost tile `nextstep` (VMID 237, udp 54134)

**Status: LIVE.** A captured Debian-12 kiosk runs the **Previous** emulator as a
**NeXTcube** (Motorola 68040, 25 MHz, 64 MB, ROM Rev 2.5 v66) booting **NeXTSTEP
3.3 for m68k**, and streamhost captures the Linux framebuffer + AC97 audio like
every other bridge tile (`streamhost/docs/BRIDGE.md`). The acceptance fixture —
the grey NeXTSTEP Workspace with the right-hand Dock — is reached on an
untouched cold boot with zero input and is framebuffer-verified in
`/data/vms/streamhost/tiles/nextstep/evidence/`.

Builder: `scripts/build-guests/nextstep.sh` (fully automated, `--force`,
idempotent). Runtime sources: `streamhost/tiles/nextstep/`. Patch:
`scripts/build-guests/previous-wmless-window-borders.patch`. Kiosk helper:
`scripts/build-guests/nextstep-kiosk-frame.sh` == guest
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

## 4. Pointer: relative, the c64/qnx path

Previous consumes SDL `xrel`/`yrel` and moves the emulated NeXT mouse by them
(`src/gui-sdl/sdlkeymap.c` → `kms_mouse_move`). It is the playbook's *Class B
relative-only inner emulator*, so the tile ships:

- `--pointer rel` (`SH_POINTER=rel`, backend `dbus-rel`), SPA `pointerRel: true`;
- `-usb` with **no** `usb-tablet`, and `-machine …,vmport=off` — without that,
  QEMU's implicit VMware absolute mouse becomes the active handler and silently
  swallows the relative events;
- `/etc/X11/xorg.conf.d/20-nextstep-pointer.conf`, which turns pointer
  acceleration off for every pointer so the browser's `movementX/Y` survive
  unscaled.

**Known limit, measured:** the NeXT KMS mouse register carries a *signed 6-bit*
delta, so a single event can move the cursor at most 63 px, and Previous sums all
queued motion before applying it. Ordinary pointer-lock movement is far below
that; a fast flick is not, and under-moves. Build-time scripted moves that jump
hundreds of pixels at once are therefore not a fair test of the production path.

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
   `scripts/build-guests/previous-wmless-window-borders.patch`.
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

`SH_RESET_MODE=loadvm`, snapshot `golden`, baked 2026-08-09 from an **untouched
cold boot**: the grey Workspace, the Workspace menu at the top left, the File
Viewer NeXTSTEP opens for itself at login, and the Dock down the right-hand
edge. Nothing curated, nothing typed — this is where the machine stops on its
own. Restore was verified by framebuffer in the same run.

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

- **`reset.mouse` and `reset.keyboard` are `UNVERIFIED`, not `PASS`.** Both were
  proven to reach the emulated machine by framebuffer (the NeXT cursor moved;
  RETURN drove the Welcome panel through two dialogs), but the full
  browser → WebTransport → streamhost → PS/2 → X → SDL → KMS path was never
  exercised end to end, and no click was shown selecting a Workspace object.
  That is the first thing to close on this tile.
- Guest-input latency was measured only through Previous's own F12 menu
  (0.58 s, at the floor of a screendump poll loop) and only while the box was
  carrying a load average of 20-45 from concurrent build agents. It should be
  re-measured on a quiesced box.
- `SDL_RENDER_DRIVER=software` alone did not avoid llvmpipe; why SDL3 still
  chose an accelerated window surface was not chased past the workaround.

## 10. Operator notes

- `labctl exec nextstep "<cmd>"` reaches the **Debian kiosk**, not NeXTSTEP.
  There is no exec channel into the NeXT side.
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

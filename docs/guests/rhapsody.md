# rhapsody guest — Rhapsody 5.1 Developer Release 2 for Intel

Status: **INSTALLED, golden baked, running as `streamhost@rhapsody`,
dark-launched** (`/os/rhapsody` resolves through a darklaunch overlay;
`listing.state=hidden` until the operator eyeballs desktop, pointer and
keyboard). Installed on camera 2026-08-18. The one real blocker — a guest PIC
race that QEMU makes frequent — is diagnosed and fixed with a station-specific
QEMU build (below).
Candidate research: [`docs/lab/research/candidate-rhapsody.md`](../lab/research/candidate-rhapsody.md).

Why it is here: the hinge between the `nextstep` station (pure NeXT) and the
`macos` poster — Apple's Platinum Finder on the NeXT/Mach substrate, the
release where "Mac OS X" (as Mac OS X Server 1.0) starts.

## Identity and source

- Public ID / tile directory: `rhapsody`
- Reserved slot / UDP port: `146` / `54146` (`kh-claim take udp 54146` during bring-up)
- Archetype: `beige-tower-crt`
- OS: **Rhapsody 5.1 Developer Release 2 (DR2) for Intel**, kernel banner
  `Rhapsody Operating System Release 5.1 ... Apple 5.1 Mach for Intel`,
  built `Fri Apr 17 1998` — Apple, preservation-class (commercial, no freeware
  re-release; same posture as NeXTSTEP 3.3).
- Media: archive.org item **`rhapsody5.1`** ("Apple Rhapsody 5.1 DR2 for i386"),
  directory `Rhapsody_5.1/`, three gzipped raw images (md5 as published by
  archive.org, verified after download):
  - `rhapsody_5.1_boot.img.gz` — 1,003,159 B, md5 `3ecf7b827aeacba44c57ab834d02d942`
    → `rhapsody_5.1_boot.img` 1,474,560 B (1.44 MB boot floppy)
  - `rhapsody_5.1_drivers.img.gz` — 454,392 B, md5 `001b684b921cd10b39f8463860f77985`
    → `rhapsody_5.1_drivers.img` 1,474,560 B (Device Drivers floppy)
  - `rhapsody_5.1_install_cd.img.gz` — 261,172,123 B, md5 `f3d7d0766abe320aa52e100a4cbca803`
    → `rhapsody_5.1_install_cd.img` 630,116,352 B (raw CD image, label `RhapsodyDR2`)
  - Staged in the sandbox at `/data/vms/sandbox/rhapsody/media/`.
- Reference only (not used by the station): archive.org
  `rhapsody-install-ready-to-configure` — a DR2 disk (`rhapsody.vmdk`, 8 GiB
  virtual) installed by someone else on a **patched QEMU 0.9.0**
  (`-rhapsodymouse`, `-m 128`, `-hda`, `-cdrom`, `-net nic,model=ne2k_pci`).
  It documents which QEMU generation the community had this working on, and
  is kept as a fallback disk at `media/r2c-preinstalled.qcow2`.

## Boot ladder (what actually happened, in order)

All on the box's stock `qemu-system-i386` 11.0.2 (pve-qemu) unless noted,
`-M pc-i440fx-11.0 -cpu pentium2 -m 64`, one IDE disk (2 GB qcow2), IDE
ATAPI CD, floppy, `-vga std`, `ne2k_pci`, serial Microsoft mouse
(`-chardev msmouse -serial chardev:`), `-display dbus,p2p=on`.

(The install-phase rig used `-vga std`, `ne2k_pci` and a serial Microsoft
mouse; the installed system's device set is what the launcher ships — see
"Install" below.)

1. Boot floppy boots on QEMU 11 under TCG: language prompt (720x400 text)
   → "prepare to install" → asks for the Device Drivers floppy (`change floppy0`
   over QMP). The drivers disk lists SCSI adapters first; **page 3, option 4
   "Intel PIIX PCI EIDE/ATAPI Device Controller (v5.01)"** is our i440fx and
   is auto-detected as `Dev:1 Func:1 Bus:0`. Then "no more drivers" (1) loads
   the Mach kernel from the CD.
2. Kernel comes up (640x480 installer window), sees `IDE Disk 0 (Type 255) -
   2047 MB` and the ATAPI CD (`sd0: QEMU DVD-ROM`); erase whole disk → "Copying
   base system…".
3. **The wall**: after 0–90 MB, `hc0: interrupt timeout, cmd: 0xc5` (Write
   Multiple) or `hc1: interrupt timeout, cmd: 0x28` (ATAPI READ), "Resetting
   drives…", and every later IDE command times out (writes trickle at
   ~1 MB/min through retries). Under KVM it happens on the first ATAPI read.
   This is the "endless lockups with the EIDE driver" the community reports for
   every QEMU newer than ~0.9, and the reason VOM pins 0.8.2.
4. Dead ends tried: KVM (worse), `-M isapc` + the generic "EIDE and ATAPI"
   driver (garbage screen under KVM), QEMU 7.0.0 build (moot once the root
   cause was found — its IDE/PIC core is the same as 11's).

## Root cause: a guest PIC race QEMU makes frequent

Traced with `-trace enable=pic_*,ide_*` (QMP `info pic` shows the end state:
master `isr=04 irr=04`, slave `irr=80 isr=00`). Sequence at the last IRQ15
that was ever delivered:

1. The ATAPI read completes; QEMU raises IRQ15 (slave line 7 → master IRQ2,
   edge-latched into the master's IRR). The 100 Hz timer (IRQ0) fires in the
   same window — under TCG both land between two TB boundaries.
2. The CPU takes IRQ0 (higher priority). Mach's interrupt prologue **masks the
   slave PIC (`imr=0xff`) and the master except the cascade (`0xfb`), then sends
   a non-specific EOI to both PICs before running the handler**. Masking the
   slave drops the slave INT line, but the master's edge-latched IRR2 stays.
3. The master's EOI clears ISR0; the master now delivers IRQ2 → INTA → the
   slave has nothing unmasked → **spurious IRQ15** (vector 0x4f). Rhapsody's
   handler reads the slave ISR, sees 0, and returns **without EOI'ing the
   master** — leaving ISR2 in service forever. From then on no slave interrupt
   (IDE 14/15) can be delivered: `interrupt timeout`.

A real 8259 pair behaves the same way, but the coincidence is rare on hardware
and constant under QEMU. Fix: `hw/intc/i8259.c` — on a spurious cascaded INTA
(slave supplied 7 with nothing in service) take the master's ISR2 back out of
service. Opt-in via `KH_I8259_LENIENT_CASCADE=1` so the same tree stays stock
otherwise. Built as a station-specific `qemu-system-i386` from the kernel-hive
QEMU fork (11.0.2 + fast-poll) into **`/opt/qemu-rhapsody`**, like
`/opt/qemu-hppa` for hpuxvue; patch source
`streamhost/qemu-patches/0006-i8259-lenient-spurious-cascade.patch`.

## Install (what was done, in order)

- Rig: `/data/vms/sandbox/rhapsody/rig/launch.sh` (kills by pidfile, boots,
  restarts the borrowed daemon; `BOOT=disk|floppy`, `QEMU=`, `ACCEL=`, `FDA=`,
  `VGA=`, `NIC=`), `drive-install.sh` (the installer keystrokes via
  `qmp-type.py --qmp`), `k.sh <wait> [keys]` (keys + screendump to
  `shot/cur.png`), `goto.sh X Y [click]` / `mm.py dx dy step` (paced PS/2
  pointer moves; see the pointer note below).
- Text installer (boot floppy → drivers floppy → CD): English (1) → 1 →
  drivers floppy (`change floppy0` over QMP) → 7, 7, 4 (Intel PIIX PCI
  EIDE/ATAPI) → 1 → Ok (1) → IDE Disk 0 (1) → erase entire disk (1) → start
  (1). ~450 MB of writes, ~35 min under TCG on a loaded box. Ends with
  "Copying of Files Completed … Remove the disk … press Return" →
  `eject -f floppy0`, Return → reboots from the disk.
- First disk boot lands in the graphical **Configure.app** (640x480, grey
  desktop pattern, Platinum look). Choices made there:
  - Display: **Cirrus Logic GD5446 PCI Display Adapter (2MB) (v5.00)** — an
    exact match for QEMU `-vga cirrus`; mode **800x600 60 Hz RGB:555/16**
    (list goes up to 1152x864; 640x480 and 1024x768 exist too). "Default VGA
    Adapter" and "Generic SVGA Adapter" also exist but were not needed.
  - Pointing Device: **PS/2 Mouse** (the default — so the candidate note's
    "serial mouse only" was wrong: the serial mouse is what VOM chose, not
    what DR2 requires; the rig now runs without `msmouse`).
  - Network: **Intel EtherExpress PRO/100B PCI LAN Adapter (v5.00)** — QEMU
    `-device i82557b`. No NE2000/PCnet driver in DR2's list. **This pairing is
    TX-only** and was later replaced by **DEC Generic 21X4X** (QEMU `tulip`)
    when the station joined the retronet: QEMU's `eepro100` does not implement
    the flexible receive-buffer-descriptor mode Apple's driver programs, so
    `Ipkts` never leaves 0 — see
    [`../lab/retronet/WEB-STATION-rhapsody.md`](../lab/retronet/WEB-STATION-rhapsody.md).
  - Save → the graphical **Install Rhapsody** package picker (Essentials
    104 MB + all Other Packages = 384 MB) → Install.
- Setup Assistant (after the first disk boot on the final device set): USA
  keyboard; LAN, manual IP **10.0.2.15/24**, router **10.0.2.2**, DNS
  **10.0.2.3** (slirp — all three superseded by the retronet addressing below),
  hostname `rhapsody`; no NetInfo; time zone "Turkey"
  (the EET band — Helsinki is not in DR2's list); no NTP; date left at the
  kernel's May-1998 default; local user **guest** with **autologin**; root
  password set (credentials: `guest/rhapsody` in the private store).
- Shutdown from the desktop: File → Log Out → **Power Off** ("It's safe to
  turn off the computer"), then kill QEMU by pidfile. A pristine copy of the
  installed disk (before any golden) is at
  `/data/vms/build/Rhapsody/rhapsody-installed-pristine.qcow2`; the three media
  `.gz` are in the media cache (`media_cache_put`, labels
  `rhapsody-5.1-{boot-floppy,drivers-floppy,install-cd}`), so the builder's
  media phase is a cache hit.
- Pointer facts (measured with QMP `mouse_move` + screendump diffs):
  **1 unit → 0.478 px** in both axes (`SH_CURSOR_SCALE=2.09`); the guest's
  PS/2 driver decodes garbage (sign flips, jumps to the far corner) when
  moves are pushed faster than it drains the i8042 queue — pace moves
  (~150 ms apart in the rig helper) and keep single deltas ≤ ~100 units. None of
  this constrains the SHIPPED pointer any more, which injects a single 2-unit
  nudge and never a walk; it still constrains any rig that drives the guest by
  relative motion. In NeXT lists, Return = default button (Add),
  but inside a table Return moves the selection — click OK with the pointer.

## Build and device set

- Builder: `scripts/build-guests/tiles/rhapsody.sh` (TODO — recipe from the rig)
- Canonical output: `rhapsody-golden.qcow2` + internal `golden` snapshot
- QEMU: `/opt/qemu-rhapsody/bin/qemu-system-i386`, `pc-i440fx-11.0`, TCG
  (KVM to be re-tested with the fixed PIC), `pentium2`, 64 MB, `-vga cirrus`
  (GD5446, 800x600x16), IDE disk 2 GB, `-device tulip` on the retronet tap
  `rhaprn0` (was `-device i82557b` user-net), PS/2 mouse, COM1 to
  `serial.log`, `-display dbus,p2p=on`.

## Networking

On the retronet web plane since 2026-08-23: bridged `tulip` NIC on `vmbr-rn`
via the persistent tap `rhaprn0`, **static** `10.99.0.22/24` (DR2 has no DHCP
client), DNS `10.99.0.2`, **no default route**, contained by the fail-closed
`RHAPRN-IN` chain. The address lives in `/etc/iftab`, the resolver in NetInfo
`/locations/resolver`, the absent route in `/etc/hostconfig`. As-built, traps
and the measurements:
[`../lab/retronet/WEB-STATION-rhapsody.md`](../lab/retronet/WEB-STATION-rhapsody.md).

## Web browser

DR2 ships **no** web browser — `/Local/Applications` is empty and
`/System/Applications` holds only Clock, Grab, HelpViewer, MailViewer,
Preferences, PrintManager, Preview and TextEdit. The registry's
`periodBrowser: "OmniWeb 3"` was aspiration until **OmniWeb 3.0 final** (Omni
Group, July 1999, fat i486+ppc, frameworks and licence bundled inside the app)
was installed into `/Local/Applications`, with a real bundle copy in the `guest`
home so the open home window carries a one-double-click icon. It browses the
corpus through the gateway's **`:80` origin door with no proxy** — OmniWeb sends
a `Host:` header, unlike os2warp's WebExplorer. Installed and verified by
`scripts/dev/rhapsody-install-browser.sh`; provenance, the raw-second-IDE-disk
delivery path and the desktop traps (a symlinked `.app` launches as "damaged";
autolaunched apps start hidden; the Dock is not scriptable):
[`../lab/retronet/WEB-BROWSER-rhapsody.md`](../lab/retronet/WEB-BROWSER-rhapsody.md).

## The pointer is an absolute write, not a loop and not a device

Rhapsody DR2 keeps **its own** pointer coordinate in guest RAM, as a
`Point{int16 x, int16 y}` at guest-physical **`0x0050fdac`**. So the browser's
absolute pixel is not dead-reckoned and not converged on — it is **written
there**, and published with one small relative event.

`-device kh-ramabs` (`streamhost/qemu-patches/0007-kh-ramabs-guest-ram-absolute-pointer.patch`)
serves the station's `ptr.sock`; the daemon's `ramabs` backend is the wire to it.
Per `MOVEA x y`:

1. pre-compensate for the publish nudge and write the coordinate;
2. inject **one 2-unit relative PS/2 event** — a write alone repaints nothing,
   because the window server redraws the cursor on an *event*;
3. **read the coordinate back**, and re-issue the whole absolute write if the
   publish did not land.

**There is no hotspot in this path.** The hotspot is real and per-glyph — `(1,1)`
for the arrow, `(3,3)` for the Bookmarks-window glyph, `(6,1)` over the OmniWeb
page — but it belongs to the *drawn sprite*, and nothing here needs to know it.
That is the whole reason this route was chosen over a hardware-cursor closed
loop: measuring the hotspot is the hardest part of every closed-loop station, and
a guessed one behaves as a magnet rather than a small error.

**Step 3 is not optional.** DR2's PS/2 driver scales by ~0.478 px/unit through a
fractional accumulator, so a 2-unit nudge is 1 px on 38 of 40 measured trials and
**0 px on the other 2**. The read-back catches those. It is a re-issued absolute
write, not a loop step: no gain, and each attempt is complete in itself.

**The address is bound to the golden, and the device fails closed.**
`0x0050fdac` is not architectural — it is fixed only because `loadvm golden`
restores RAM verbatim, so it is valid for the life of *that* checkpoint.
`kh-ramabs` therefore verifies it at connect (the value must be a plausible
on-screen point, and a probe publish must land) and **refuses every write** if it
cannot, so a stale address degrades the station to its relative path instead of
corrupting guest memory. `STAT` reports `pos=unknown` in that state.
**Re-baking the golden means re-deriving the address** — four `pmemsave` dumps at
four framebuffer-verified positions and a search for the address whose
`value − observed` bias is constant; about an hour, written up in
[`../lab/RHAPSODY-ABSOLUTE-POINTER.md`](../lab/RHAPSODY-ABSOLUTE-POINTER.md).
A second, derived copy at `0x00eae020` tracks the coordinate but is **not** an
input; writing it alone does nothing.

**No golden recapture was needed.** `kh-ramabs` registers no
`VMStateDescription` and models no hardware, so it adds no section to the
migration stream; the device set and `deviceSetId` are unchanged.

**Install order is binding**: QEMU binary before the launcher (`-device
kh-ramabs` is an unknown device on an older binary and QEMU refuses to start),
streamhost binary before the env fixture. **Rollback is two lines**: drop the
`-device kh-ramabs` line and set `SH_INPUT_BACKEND=dbus-rel` with
`SH_CURSOR_SCALE=2.09`.

**Why not a native absolute device**, since this is NeXT lineage: the `nextstep`
station won with a real SummaGraphics tablet on the **NeXT's own SCC serial
port**, which is m68k-hardware specific. DR2 for Intel has no USB stack (so
`usb-tablet` binds nothing), no VMware tools (so `vmmouse` is out), and
Configure.app offers only PS/2 / bus / serial mice. There is no absolute device
on this machine to find — do not re-run that search.

**Proof (rule 9)**, on a sandbox clone, three observers at every target
(commanded / the guest's own coordinate / `cursor-locate.py` on a QMP
screendump): six targets — both screen edges, two window frames, the OmniWeb page
and the desktop — all `err=+0,+0` at `--tol 1`; the true corner `(1023,767)`
exact on the sensor (the sprite is clipped there, so no exact glyph match is
possible); and a click at a commanded pixel that raised a buried window and
switched the active application, 265 062 pixels repainted.


## Golden, input, and rollback

- `golden` baked 2026-08-18 on the station itself
  (`/data/vms/streamhost/stations/rhapsody/rhapsody-golden.qcow2`, internal
  snapshot, 52.5 MiB vmstate) from a cold boot on the production launcher's
  device set: the desktop after autologin, nothing curated. `loadvm golden -S`
  restores the identical frame; `SH_RESET_MODE=loadvm`, `SH_IDLE_PAUSE_SECS=60`.
- Pointer: **truly absolute**, by writing the guest's own coordinate — see
  "The pointer is an absolute write" above. `SH_INPUT_BACKEND=ramabs`.
- Credentials reference only (never values): `guest/rhapsody`
- Rollback: `systemctl stop streamhost@rhapsody`; the station's single disk is
  the whole state — replace it with the pristine copy above (or rebuild with
  `tiles/rhapsody.sh`) and re-bake. Withdraw the dark launch with
  `darklaunch-station.py withdraw rhapsody`.

## labctl exec, resolution, absolute pointer (2026-08-18)

- **Resolution 1024×768** (up from 800×600). Set in Configure.app → Display →
  Cirrus GD5446 → 1024×768 RGB:555/16 @60, saved to the driver Instance table;
  Preferences → Monitor "Minutes Until Screen Dims" set to **Never** so the
  exhibit never blanks. Modes up to 1152×864 are offered.
- **labctl exec** over a getty on COM1 (`exec_kind: serial_getty`). DR2 has no
  network exec, so the launcher exposes COM1 as `<dir>/serial.sock` and the
  guest runs a getty on `ttyda`: added the **TTY Port Server** pseudo-driver
  in Configure.app → Other (it provides the `/dev/tty*`/`cu*` nodes the bare
  ISASerialPort driver does not), then `ttyda "/usr/libexec/getty std.9600"
  ... on` in `/etc/ttys`. `scripts/labctl.d/serialexec.py` logs in as `root`
  (password in the gitignored `<dir>/serial-exec.passwd`, never the registry),
  runs one command per session between sentinels, and returns the guest's exit
  code. Verified: `labctl exec rhapsody "uname -sr"` etc., exit codes and
  quoting propagate, five back-to-back calls clean.
- **Absolute pointer**: see "The pointer is an absolute write" above. (The
  abs→rel dead-reckoning bridge this station shipped with — `dbus-rel`,
  `SH_CURSOR_SCALE=2.09`, `SH_REL_MAX_STEP=24` — is now the ROLLBACK path, not
  the shipped one.)

## Open

- Operator eyeball of desktop/pointer feel/keyboard at `/os/rhapsody`, then
  drop `listing` and republish the three runtime documents (coordinated with
  the other dark launches — a republish wipes every overlay).
- Push the QEMU patch (`0006-i8259-lenient-spurious-cascade.patch`, now the
  level-cascade version) to the `Wnt/qemu` `kernel-hive` branch + submodule
  bump; `/opt/qemu-rhapsody` on the box is already built from it.
- After landing, rebuild+deploy the daemon from main
  (`build-deploy.sh --canary rhapsody`) so `current` points at a
  `streamhost-<gitsha>` instead of the hand-built canary.
- KVM re-test with the fixed PIC (would take the station off TCG).
- Real poster hero (a desktop screenshot) instead of the placeholder card.
- Builder `tiles/rhapsody.sh` has not been run end-to-end.

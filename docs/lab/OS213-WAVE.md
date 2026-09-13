# IBM/Microsoft OS/2 1.3 with Presentation Manager — integration wave, 2026-09-13

OS/2 1.3 (1991; Presentation Manager debuted in OS/2 1.1, 1988) as a **desktop**
station under the fleet QEMU (pve-qemu 11.0.2), Tier inherited from the sibling.
Runs beside four other station waves tonight (`macsys1`, `apple2gs`, `minix2`,
`xenix`) behind the `job-84ed2a5b` coordinator — landing goes through the
`wave.sh land` lock (`WAVE-COORDINATION.md`).

**Sibling is `nt351`, NOT `os2warp`.** `stations-registry.py new os213 --like os2warp`
hard-fails: os2warp has no `streamhost/stations/os2warp/station.env.fixture` (only
`qemu-streamhost.sh`, `rn-tapnet.sh`, `wi-tapnet.sh`), and the scaffold requires one.
`nt351` is the better match regardless — TCG on `-machine isapc -cpu 486`, `ui: desktop`,
`qemu-ps2-relative` pointer, `loadvm golden` fixture, and no retronet/tap lines to strip.

## Ledger — from `scripts/dev/wave.sh alloc os213`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 203 / 54203 / 203 |
| x11warp display | — (not allocated; the pointer is QEMU PS/2 relative) |
| retronet address / MAC / tap / chain / UIN | — (OPEN, see below) |
| sibling (`--like`) | `nt351` |
| hardware tuple (`--tuple`) | `towerC,crtD,keyboardB,paramMouseD` — distinct; scene lineup index 101 of 102 |
| render orders | as scaffolded by `stations-registry.py new` — not hand-edited |
| device set (smoke) | `qemu-system-i386 -accel tcg -m 16 -smp 1 -machine isapc -cpu 486 -rtc base=localtime -boot c -device isa-vga -display dbus,p2p=on -device sb16 -drive …if=none,id=hd0 -device ide-hd,drive=hd0,bus=ide.0,unit=0` |
| pointer | `qemu-ps2-relative` (PS/2 relative; no absolute route on `isapc` — no USB) |
| keyboard pacing | fleet floor 40/40 (QEMU) |

## Media (staged by `os213-media` on LABHOST `/data/assets-staging/os213/`)

Full URLs, licence posture and per-file sha256 are in that directory's `SOURCES.md`
and `MANIFEST.sha256`. Measured:

| File | Bytes | sha256 (short) |
|---|---|---|
| `IBM_OS2_1.30.2_Standard_Edition_144mb.7z` (10 x 1.44 MB SE floppies) | 8,293,261 | `f43c3dac…` |
| `Microsoft_OS2_Server_1.30.1_vmdk.zip` | 5,873,118 | `4670d4b6…` |
| `preinstalled/Microsoft OS2 Server 1.30.1.vmdk` | 159,842,304 | `f444b5fc…` |
| `preinstalled/os213-preinstalled.qcow2` (converted on labhost) | 160,104,448 | `2150669f…` |

VMDK descriptor geometry: **cylinders=310, heads=16, sectors=63**.

## Proven in the spine (coordinator, alone)

- Smoke rig `/data/vms/sandbox/os213/smoke/` (`launch-smoke.sh`, rig-clone convention).
- **First framebuffer**, `smoke/f1.png`: `Microsoft (R) Operating System/2 Version 1.3`
  / `(C) Copyright Microsoft Corp. 1981-1991` / `U.S. Patent No. 4779187; 4825358`.
  The preinstalled image is genuine MS OS/2 1.3 and the boot sector loads.
- `smoke/f2.png` (+13.3 s): screen cleared, partial `TRA` at the top-left.
- `smoke/f3.png`: **wedged** — no framebuffer change for 45 s at that partial `TRA`.
  `TRA` is almost certainly the head of an OS/2 `TRAP xxxx` panic.

## Walls hit

### Wall 1 — MS OS/2 1.30.1 preinstalled image traps right after the banner

Raced per rule 14 / OPERATING-RULES §13, four theories, one clone each:

| Theory | Change | Runner | Result |
|---|---|---|---|
| A (lead) | explicit CHS `cyls=310,heads=16,secs=63` on `-device ide-hd` | lead (Opus) | REGRESSION — boot stalls earlier, at SeaBIOS `Booting from Hard Disk...`, no OS/2 banner at all. `-drive …,cyls=` is rejected outright by QEMU 11 (`Block format 'qcow2' does not support the option 'cyls'`); the geometry must go on `-device ide-hd`. Auto-geometry gets further than the descriptor's 310/16/63. |
| B | `-machine pc-i440fx-11.0,acpi=off,usb=off -cpu 486 -vga std` instead of `isapc`/`isa-vga` | sonnet | FAIL — two boots, both frozen at SeaBIOS `Booting from Hard Disk...`, never reaching the OS/2 banner. Frame `race/pcimachine/frame3.png`. |
| C | RAM/CPU sweep: `-m 8`, `-m 16 -cpu pentium`, `-m 4`, `-m 12` | sonnet | FAIL — only `-m 8` reached before its stop; same SeaBIOS freeze. Frames `race/ramsize/frame-C1.png`, `frame-C1c.png`. |
| D | IBM 1.30.2 SE `Install.img` boots where the MS Server image traps (image, not device set) | sonnet | **WON** — `IBM Operating System/2 Installation Version 1.30` welcome screen, framebuffer settled 5.2 s after launch. Frame `race/ibmfloppy/frame.png`. |

| E | OS/2 1.x "CPU too fast" timing bug: `-icount shift=6/8/4/10` | sonnet | FAIL — `shift=6` reaches the identical truncated `TRA` wedge and stays frozen through ~120 s of wall clock. This is **not** the CPU-speed bug. Frame `race/icount/frame-E1.png`. |

**Verdict: the IMAGE was the problem, not the device set.** `isapc` + `-cpu 486` + `-m 16`
+ auto disk geometry is correct; the Microsoft 1.30.1 Server preinstalled qcow2 is simply
unbootable for us and is abandoned. The station installs from the IBM 1.30.2 SE floppy set.

Two traps worth carrying to other waves:

1. `-drive file=…,format=qcow2,cyls=310,heads=16,secs=63` is rejected outright by QEMU 11
   — `Block format 'qcow2' does not support the option 'cyls'`. Disk geometry only goes on
   `-device ide-hd`. And pinning it there was still *worse* than letting QEMU auto-detect.
2. Theories B and C cloned the rig **while theory A's CHS line was in `launch-smoke.sh`**,
   so both inherited a known-bad flag and their SeaBIOS freezes are partly the lead's
   regression rather than their own theory. When racing, freeze the base rig before
   `rig-clone.sh new`, or hand each runner the exact baseline device set in its brief.
3. `rig-clone.sh`'s generated `launch.sh` duplicated `${RIG_EXTRA}` for this rig, so extra
   args landed on the QEMU command line twice (harmless here — reported for a later fix).

### Wall 2 — the install itself

The IBM SE set is 10 x 1.44 MB (`Install`, `Disk01`-`Disk05`, `Driver1`-`Driver4`). Run as
ONE agent (Opus) with a 45-minute stop, swapping media over QMP
`blockdev-change-medium` on the `fd0` backend and waiting on `fb-wait.py --change` /
`--settle` — never a relaunch per disk, never a guessed `sleep`.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| race B/C/D | one bring-up theory each on a `rig-clone.sh` clone | sonnet | running |
| `docs` | `docs/guests/os213.md`, `GUEST-TIERS.md`, release-notes fact file | sonnet-low | after golden |

## OPEN items

- **retronet: OPEN, deliberately.** Per WAVE-COMMON §Fast path, none of the five
  stations in this wave gets `--retronet`: OS/2 1.3 has no bundled TCP/IP stack
  (IBM TCP/IP for OS/2 1.3 is a separate product), so a web plane + an IM client
  would cost an install-floppy hour this wave cannot afford. No `rn-tapnet.sh` is
  committed for os213 (rule 15).
- **Absolute pointer: OPEN.** `isapc` has no USB, so `usb-tablet` is unavailable and
  the pointer is PS/2 relative. A two-target absolute readback proof needs an
  absolute route and is therefore out of scope; the wave proves motion + click with
  `fb-react.py` instead.

## Sandbox verdict (WAVE-COMMON requirement)

os213 is an **emulated machine under the fleet QEMU**, not a host application: the
visitor's reach ends at the emulated i486. No `systemd-nspawn` container is needed.
No 9p/virtfs/smb/`fat:` host drive, no `-netdev user` hostfwd, no guest-reachable
QMP/monitor, no virtio-serial host channel. Launcher line:
`streamhost/stations/os213/qemu-streamhost.sh`.

## Landing — NOT DONE in this wave's budget

`station-land.sh` was NOT run. Everything except the guest disk is committed,
pushed and green on branch `os213`; the install was still running at the lead's
120-minute stop. **Do not land an enabled production `os213` until a golden
exists** — the registry row is `lifecycle: production, enabled: true`, so landing
it without a disk at `/data/vms/streamhost/stations/os213/os213-golden.qcow2`
would put a dead tile in the gallery.

### Exact resume path

The install rig is alive and resumable; the guest has never been relaunched.

| Thing | Where |
|---|---|
| install target disk | `/data/vms/sandbox/os213/smoke/os213-install.qcow2` |
| running guest | `/data/vms/sandbox/os213/smoke/qemu.pid`, launched by `launch-smoke.sh` (`FD=` / `BOOT=` env vars) |
| floppies | `/data/vms/sandbox/os213/smoke/floppies/*.img` |
| step helper (labhost only) | `smoke/step.sh <name> <settle> <timeout> <keys...>` |
| floppy swap helper (labhost only) | `smoke/swap.sh <Disk0N|DriverN>` — QMP `blockdev-change-medium`, never a relaunch |
| published page | `/os/os213`, dark-launched; **re-run `smoke/run-daemon.sh` after ANY guest relaunch** or the page goes dead |

Then: finish the install, reboot `BOOT=c` with fd0 ejected, reach the PM Desktop
Manager, `savevm golden`, restore-prove it, and run the three proofs (restore,
typed `ver`/`dir`, `fb-react.py` motion + click). After that:

```
scripts/dev/station-land.sh os213 --golden /data/vms/sandbox/os213/smoke/os213-install.qcow2
```

### The "Minimum System Configuration" panel — a scare, resolved on evidence

The IBM 1.3 SE installer shows a **"Minimum System Configuration"** panel whose
default action is Enter: *"No configuration options were selected."* The lead read
that frame and told the install agent to press Esc and go back — worried that a
minimum install would land at a bare `[C:\]` with no Desktop Manager, which is the
whole exhibit, and would only be discovered after the reboot.

**That worry was wrong, and the agent had already checked.** The previous panel's
full option list is exactly nine entries:

> Country Information · Documentation · Fonts · High Performance File System ·
> Optional System Utilities · OS/2 DOS Environment · Picture Utilities ·
> Serial Device Support · Serviceability and Diagnostic Aids

There is **no Presentation Manager entry, no Desktop Manager entry and no tutorial
entry** in it. In OS/2 1.3 SE, PM and the Desktop Manager are the *base system*;
this panel only offers add-ons on top of it. "Minimum System Configuration" means
"no add-ons", not "no GUI". HPFS is on the list and we deliberately do **not** want
it (the station is FAT). So taking the minimum costs Documentation, extra Fonts,
Picture Utilities and the DOS box — none of which is the exhibit — and costs
nothing graphical. Frame: `smoke/shots/s10.png`.

Two lessons, both cheap to reuse:

- **Read the panel the warning refers to before acting on the warning.** The scary
  wording was on the confirmation panel; the fact that settled it was on the panel
  before it.
- A lead peeking at a runner's framebuffer sees a frame that is already ~20 s old
  by the time the message lands. Peek to decide whether to *keep going*, not to
  steer a keypress — the runner holds the QMP socket and the current frame.

### Display adapter and mouse

The installer detects **"IBM PS/2 Display Adapter"** — that is OS/2 1.3's name for
the VGA-class adapter and is correct for `-device isa-vga`; answer 1, *"Yes — no
other display adapters are attached"*. At the mouse panel the answer is the **PS/2
mouse**: `-machine isapc` has no USB at all, so PS/2 relative is the only pointer
transport this machine has.

## Measured timeline

Filled from `scripts/dev/session-timeline.py` after landing.

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` | | |
| first framebuffer (`smoke/f1.png`, MS OS/2 1.3 banner) | | |
| ledger committed | | |

## Teardown (rule 8)

Tracked here as it happens: smoke rig, every `race/<theory>` clone, the claims for
slot/port/VMID under `KH_SESSION=os213`.

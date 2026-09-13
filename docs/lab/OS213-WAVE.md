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

## Wall 3 — and the real cause of Walls 1 and 2: a QEMU TCG defect

The station was TCG throughout, on the reasoning that `isapc` has no KVM path.
That reasoning was wrong, and it cost the whole first budget.

Two **independently produced** OS/2 1.3 systems trapped identically under
`-accel tcg`: the Microsoft 1.30.1 pre-installed image (`smoke/f3.png`), and a
complete IBM 1.30.2 SE floppy install driven to the installer's "successfully
installed" panel (`smoke/shots/s24.png`), which then trapped at its own first
reboot having written ~4 MB. Same truncated `TRA`, same dead framebuffer.

The `xenix` station hit the same shape the same night — "no stack space",
reproduced on two independently produced systems — and it was a **QEMU TCG
defect**: `-enable-kvm` with nothing else changed booted it in 25 s. That
verdict transfers to os213 exactly.

| Theory | Change | Result |
|---|---|---|
| A `kvmpre` | `-enable-kvm`, everything else identical (`isapc`, `-cpu 486`, `-m 16`, `isa-vga`) | **WIN** — full PM Desktop Manager, settled ~20 s. QEMU accepts `-enable-kvm` with `-machine isapc` without complaint. `race/kvmpre/frame.png` |
| C `kvmpc` | `-enable-kvm -machine pc,acpi=off -cpu 486 -vga std` | **also WIN**, `-cpu 486` accepted under KVM with no fallback. `race/kvmpc/frame.png` |

`isapc` was kept: it preserves the committed launcher and the `nt351` sibling
shape. `pc,acpi=off` is the proven fallback if `isapc` ever regresses.

**Two independently produced systems failing identically is the signature.** It
means the fault is in the layer they share — the emulator — not in either
system. Reach for the accelerator before the guest.

## Proofs (rule 9 — the framebuffer is the only proof)

All on the station's EXACT device set, sb16 and dbus audio included, so the
golden matches the launcher (rule 6: checkpoint + binary + device set are ONE
combination).

| Proof | Frame | Measured |
|---|---|---|
| cold boot to the fixture | `smoke/pm1.png` | settled 22.3 s from cold |
| `savevm golden` | — | snapshot ID 1, VM_SIZE 3.21 MiB, VM_CLOCK 00:39.363 |
| **restore** through the launcher's own `-loadvm golden -S` + `cont` | `smoke/restore-proof.png` | settled 8.2 s, fixture identical |
| **keyboard** — two Down keys move the Group-Main selection | `smoke/kbd-before.png` → `kbd-after.png` | `fb-react react` → **changed=5270 bbox=256,171-479,254 REACTION** |
| **pointer motion** (PS/2 relative) | `smoke/ptr-before.png` → `ptr-moved.png` | `fb-react react` → **changed=102 REACTION** |
| pointer motion, clamped 100 px steps | `smoke/ptr-click-item.png` → `ptr2-on.png` | **changed=33 REACTION** |
| pointer **click** (single, selects a Group-Main item) | `race/clickfix/e5-on.png` → `e5-qmpclick.png` | **changed=3631 REACTION** |
| pointer **double-click** (opens the OS/2 System Editor) | `race/clickfix/e5-qmpclick.png` → `e5-dbl.png` | **changed=94050 REACTION** |

### RESOLVED: clicks were never broken — the harness was aiming wrong

Second pass, 2026-09-13 evening (Opus). All three leads were run; the first
two settled it.

1. **`CONFIG.SYS` has the whole mouse stack.** Read straight out of the qcow2
   with a `grep -a` for `PROTSHELL` and a `dd` around the hit — no mount, no
   `qemu-nbd`, no guest login needed:
   `DEVICE=C:\OS2\POINTDD.SYS`, `DEVICE=C:\OS2\MSPS201.SYS`,
   `DEVICE=C:\OS2\MOUSE.SYS TYPE=MSPS2$`, `DEVICE=C:\OS2\PMDD.SYS`.
   The "no driver behind the pointer" theory is dead.
2. **Locating the cursor for real found the bug.** OS/2 1.3's driver uses the
   classic **2:1 horizontal:vertical mickey ratio** — measured 1.02 px/unit in
   x and **0.50 px/unit** in y, with a further acceleration bend above ~1 unit
   per event (20 x `rel x=+10` gives 0.885 px/unit). Every click in the first
   bake was aimed with deltas that assumed 1:1, so the pointer sat roughly
   twice as far down the screen as the harness believed and the clicks landed
   on empty desktop.
3. **HMP `mouse_button` was never needed.** QMP `input-send-event` `btn` and
   HMP `mouse_button 1`/`0` both deliver the button.

With single-unit events and the y count doubled, a single click moves the
Group-Main selection (changed=3631) and a double click opens the OS/2 System
Editor (changed=94050).

**Consequence for the station: `SH_CURSOR_SCALE` cannot fix this.** The daemon
has one scalar, this guest needs x=1.0 and y=0.5, so either axis can be right
but not both. A real 1:1 pointer here has to be absolute.

### Absolute via `kh-ramabs`: the input variable is `0x253ca`, `point16le_yup_yx`

**Proven on the rig 2026-09-13, NOT cut over.** Full table, the probe/sweep
discrimination and the re-derive command are in `docs/guests/os213.md`
§Pointer. What belongs here is the method and the three things that cost time.

Rig `/data/vms/sandbox/os213-ptr/ramabs/` (`launch.sh` now honours `$QEMU_BIN`
and `COLD=1`). Harnesses: `/tmp/ramstat.py` (one QEMU start per candidate,
prints `STAT` + the device's own log line) and `/tmp/ramsweep.py` (five
targets, two laps, sensor + framebuffer per target).

**1. The one-stage bias search returns ZERO candidates on this guest.** The PM
arrow is XOR-drawn and the "densest changed 22x14 window, then bbox minimum"
locator is off by up to 6 px in x and 14 px in y on some samples — measured
against the RAM afterwards. An exact-bias search over six samples then matches
nothing at all, not even at 4-of-6. The fix is two-stage
(`scripts/dev/os213-ramabs-scan.py`): only ~2000 of 8.4M int16 slots change
while the pointer moves, so enumerate those, read the pointer's TRUE positions
out of them, and re-run the family search against that truth vector. Every
family then resolves at once — x/y, y-then-x, inverted-y, doubled-y, int32.
(The oberon wave hit the same wall and solved it with a ±1 tolerance per word;
either works, and the RAM-as-truth version also hands you the hotspot.)

**2. The connect-time write probe is necessary but NOT sufficient here.**
Three addresses pass it (`0x24ea0`, `0x24eb0`, `0x253ca`) and only `0x253ca`
steers the pointer: `0x24ea0` sweeps to `converged=0 gaveup=21`. This is the
first station where `BEOS-ABSOLUTE-POINTER.md` §3's "if more than one
verifies, stop and escalate" resolves by measurement rather than escalation —
the sweep's `converged`/`gaveup` counters break the tie. Never ship on a probe
pass alone.

**3. A failed candidate announces itself at the station's relative gain.**
Every read-only copy ends the probe at `313,243` when the device wanted
`320,239`: x drifting -1 per try, y +0.5 per try, i.e. the 2:1 mickey ratio
applied to the probe's own 1-unit diagonal nudge with the write ignored.

**Addresses are bound to one bake.** These are the `os213-ptr/ramabs` golden's
(baked 2026-09-13 under `/opt/qemu-beos`, `VM_CLOCK 00:28.220`). The cutover
bake must re-derive.

### Remaining to cut the station over

1. Build `/opt/qemu-os213` from the fork tip carrying the table-driven `0007`
   (`point16le_yup_yx`) — **not** `/opt/qemu-beos`, whose goldens belong to
   beos and pcgeos. `/opt/qemu-oberon` already carries the layouts and can be
   used to re-prove without a build.
2. Cold re-bake the golden under that binary, re-derive `0x253ca` against it,
   re-run the two-lap sweep (re-measure the `20,20` target with
   `scripts/dev/cursor-locate-cv.py`, not the naive locator) plus one click
   that reacts.
3. Launcher → `/opt/qemu-os213` + `-device kh-ramabs,addr=…,layout=point16le_yup_yx,width=640,height=480,nudge-units=1,nudge-px=1`,
   `SH_INPUT_BACKEND=ramabs`, registry `stream.pointer` abs + `reset.mouse`
   sentence, then `station-land.sh os213 --golden …`.

## Landing

`station-land.sh os213 --golden .../os213-golden.qcow2` got through the push to
main and `box-deploy`, then **FAILED at step 9, station-up**: `streamhost@os213`
restart-looped 29 times on
`Could not open '/data/vms/streamhost/stations/os213/os213-golden.qcow2'`.

**Cause, and a trap for every `--like` scaffold:** `station-land.sh` stages the
golden as `$D/disk.qcow2` (parking the old one as `disk.qcow2.pre-<ts>`). The
`nt351` sibling this launcher was copied from predates that convention and names
its disk `nt351-golden.qcow2`, so the rewritten copy looked for a file the
landing script never creates. **Check the staged disk NAME against your
launcher before landing, not after.** Fixed in `18a60cff`.

The re-push then hit the **box-state gate**, for a second trap worth knowing:
`emit --pin-machine` rewrites machine-type literals **inside comments too**. A
fallback machine type spelled out in a launcher comment came back rewritten in
the emitted copy, so the live file matched neither the box checkout nor the
working tree and the gate refused the push. Fix: do not spell a machine-type
literal in a launcher comment (the comment now says so), and restore the live
emitted row to the box checkout before pushing.

Sequence that worked: fix → push main → `box-deploy.sh --apply` → `station-up.sh
os213` green → SPA `build` + `deploy`.

**LIVE**: `/data/vms/sandbox/os213/os213-up.png` — the PM Desktop Manager on the
real station, unit active, `NRestarts=0`, all 5 runtime manifests carry `os213`,
`POST /restore/os213 -> 200`.

## One rig dir = one owner (a mistake, published)

Three agents worked in `/data/vms/sandbox/os213/smoke` at once. Its
`launch-smoke.sh` opens with `kill $(cat $R/qemu.pid)`, so whoever runs the
launcher next **silently kills everyone else's guest** — and the victim sees
only a vanished `qmp.sock`, which looks exactly like a guest crash. The lead
rewrote that launcher into a bake rig and ran it while the install agent was
mid-install, and killed it. The install agent diagnosed it from
`terminating on signal 15 from pid <the lead's labrun bash>` plus an
unexplained 160 MB file appearing in the dir.

Rule 4 already says namespace every dir, VMID, socket and port — this is the
same rule applied to a *sandbox* rig, not just a live station. A rig dir has one
owner; a second agent gets `rig-clone.sh new` or its own namespaced dir, never
the same pidfile. Consequence here: the install agent's run says **nothing**
about TCG vs KVM, because its KVM attempt was killed on its first keypress.

## Also worth carrying

- `qemu-system-i386` is a wrapper for `qemu-system-x86_64` on labhost, so
  `/proc/<pid>/exe` resolves to `qemu-system-x86_64` for an i386 guest. An exe
  check that expects the literal `qemu-system-i386` refuses a legitimate kill;
  match `*/qemu-system-*`.
- `scripts/lib/labqmp.py` has no `hmp` action — use QMP
  `human-monitor-command` directly for `savevm`/`loadvm`.

## The IBM 1.30.2 SE install recipe (not shipped, but proven and preserved)

The station ships the Microsoft pre-installed image, but the IBM SE floppy
install was driven to completion and its recipe is in
`docs/guests/os213.md` §Install recipe. Highlights: FAT is option **2** and HPFS
is the default highlight, so you must move off it; the nine-entry configuration
panel contains no Presentation Manager or Desktop Manager entry because PM *is*
the base system in 1.3 SE, so "Minimum System Configuration" means "no add-ons",
not "no GUI"; the display adapter is "IBM PS/2 Display Adapter" answer 1; the
mouse list needs one Down to reach the PS/2 version. Disk copy order is
`Install → Disk01 → … → Disk05 → Install → Driver1`; Driver2-4 are never needed.
~23 minutes under TCG, each disk ~20-25 s. The trapped result is preserved at
`smoke/os213-install-tcg-trapped.qcow2`.

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

# pcgeos guest — PC/GEOS Ensemble, GeoWorks in 640 KB

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-02 in a parallel
wave ([`lab/PCGEOS-WAVE.md`](../lab/PCGEOS-WAVE.md)). The media is sourced,
hashed and staged; the disk is composed by a builder; the golden and its bake
are the golden stream's to prove and record below.

## What it is

PC/GEOS Ensemble is GeoWorks's preemptive-multitasking, object-oriented
graphical desktop for DOS — first shipped in 1990 as **GeoWorks Ensemble**,
sold on through **NewDeal Office** and **Breadbox Ensemble**, and open-sourced
in 2018 by Breadbox/blueway.Softworks under **Apache-2.0**
(<https://github.com/bluewaysw/pcgeos>). It is the GUI that ran a full desktop,
word processor and paint program in **640 KB on a 286**, and made Windows 3.0
look slow doing it. This station runs the bluewaysw CI build of that
open-sourced codebase, not an archival GeoWorks release.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `pcgeos`
- Display name: **PC/GEOS Ensemble**
- Reserved slot / UDP port / VMID label: `175` / `54175` / `175`
- Archetype: `beige-ibm-pc`; era year **1993** (`museum.year`), lineage
  `GeoWorks Ensemble → NewDeal Office → Breadbox Ensemble → PC/GEOS (open
  source 2018)`
- Upstream: <https://github.com/bluewaysw/pcgeos>, release tag `CI-latest`
  (a moving tag — the builder pins the SHA-256 of the asset, not the tag),
  asset `pcgeos-ensemble_nc.zip`
- License class: **free/open**, Apache-2.0
- No login, no credentials. `credentialsRef: guest/pcgeos` exists only because
  the schema requires one.

### Media

| property | value |
|---|---|
| `pcgeos-ensemble_nc.zip` | CI-latest asset, **10 932 546 bytes**, 743 files, 22.2 MB unpacked; unzips to `ensemble/` with `loader.exe`, `geos.ini`, `system/` — every name fits 8.3 |
| SHA-256 | recorded in `/data/assets-staging/pcgeos/MANIFEST.sha256` |
| Base OS | the fleet FreeDOS 1.3 disk, `/data/gallery-guests/FreeDOS/freedos.qcow2` (512 MiB FAT16 LBA partition at byte offset 32256) |
| Builder | `scripts/build-guests/tiles/pcgeos.sh` (`build.rows` key `pcgeos`, class `fast`, `automation: full`, `~2m`) |
| Builder output | `/data/gallery-guests/PCGEOS/pcgeos.qcow2` — FreeDOS 1.3 disk + `C:\ENSEMBLE`, autoexec runs `loader.exe`; pristine, no golden |
| Runtime path | `/data/vms/streamhost/stations/pcgeos/disk.qcow2` — the ONLY block device |

## Composition recipe

The disk is FreeDOS 1.3 converted to raw, then composed with `mtools`
(`-i disk.raw@@32256`, matching the FAT16 partition's byte offset on the
fleet disk):

- `mcopy -s ensemble ::/ENSEMBLE` — copies the unzipped `ensemble/` tree onto
  the FAT filesystem as `C:\ENSEMBLE`.
- `FDAUTO.BAT` edited (kept CRLF) so `call \MENU.BAT` is replaced by
  `cd \ENSEMBLE` + `loader` — the disk boots straight into GEOS instead of the
  FreeDOS menu. `FDAUTO.BAT` already loads `CTMOUSE` and sets
  `SET BLASTER=A220 I5 D1 H5 T6` for the Sound Blaster, both inherited
  unchanged from the FreeDOS base.
- `geos.ini` edited in three places, because the zip's defaults target
  DOSBox, not a raw QEMU PC:
  - `[mouse]` is LEFT AS SHIPPED (device `Basebox Mouse`, driver `Abs. coord. Wheel
    Mouse`): under QEMU with CTMOUSE loaded it moves the pointer 1:1. The `Generic
    Mouse` / `genmouse.geo` entry the first ledger prescribed does NOT move the
    pointer here (measured 2026-09-03: five relative moves, cursor stayed at 320,134);
    the builder's first version had written it under `[task driver]` by mistake,
    which is why the original golden worked.
  - `screenBlanker = false` — was `true` with a 1-minute timeout, which would
    blank a station nobody is actively driving.
  - `Lights Out Launcher` removed from `[ui] execOnStartup` — a DOSBox-era
    convenience utility with no place on a kiosk.
  - Left untouched: the screen mode, `VESA Compatible SuperVGA: 800x600
    64K-color` via `vga16.geo` — this works unmodified on `-vga std`.

## Device set

`streamhost/stations/pcgeos/qemu-streamhost.sh` is deployed **verbatim**.
QEMU **11.0.2** (host `pve-qemu-kvm` 11.0.2-1).

```
qemu-system-x86_64 -name streamhost-pcgeos \
  -enable-kvm -m 64 -smp 2 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device sb16,audiodev=snd0 \
  -drive file=$BASE/disk.qcow2,format=qcow2,if=ide \
  -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  [-loadvm golden -S] \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off -pidfile $BASE/qemu.pid
```

Semantically identical to the fleet freedos launcher — same
`pc-i440fx-11.0,acpi=off` machine, same backend-only PC-speaker routing —
except **`-vga std`** (VESA 800x600 for `vga16.geo`, freedos uses the default
text-mode VGA) and this station's own disk.

- **`-vga std`.** GEOS's screen driver is `vga16.geo`, targeting the VESA
  Compatible SuperVGA 800x600 16-bit mode the zip ships configured for.
  `-vga std` is the Bochs VGA BIOS QEMU exposes for that mode; nothing more
  exotic is needed.
- **`disk.qcow2` is the only block device**, and it carries the `golden`
  vmstate. GEOS's own filesystem — `C:\ENSEMBLE`, any files a visitor's
  session creates or a scratch save writes — lives on the same FAT16
  partition FreeDOS boots from, so storing it as qcow2 lets `savevm golden`
  capture RAM and the disk contents together, and `loadvm golden` restores
  both: a visitor's edits do not carry to the next.
- **Mouse driver:** the zip's default `[mouse]` entry (`Basebox Mouse` / `Abs. coord. Wheel Mouse`); see the composition recipe for why not `genmouse.geo`.
- **Pointer: ABSOLUTE** via `-device kh-ramabs` (the beos/rhapsody route, `docs/lab/BEOS-ABSOLUTE-POINTER.md`). DOS's CTMOUSE keeps the pointer as int16 x,y at guest-physical `0x76e0` and GEOS's `genmouse.geo` takes the absolute CX/DX from its INT 33h callback, so the device writes the visitor's pixel there and one 1-unit PS/2 nudge makes CTMOUSE republish it. 1 unit = 1 px below GEOS's acceleration threshold; hotspot (0,0); five MOVEA targets including (20,560) and (780,30) landed pixel-exact. The address is BOUND TO THE GOLDEN — re-derive with `scripts/dev/pcgeos-ramabs-derive.py` after every re-bake (~3 min: bias search over the first 1 MB, then the device's own write probe per candidate; six addresses tracked, exactly one verified). Runs under `/opt/qemu-beos` (the kh-ramabs build): binary and golden are one unit.
  qemu-ps2-relative`) through CTMOUSE (loaded by `FDAUTO.BAT`) feeding
  the mouse driver's INT 33h reads.
  on this station — see *Known gaps*.
- **Audio**: `sb16` (Sound Blaster, `SET BLASTER=A220 I5 D1 H5 T6`) plus the
  PC speaker (`pcspk-audiodev=snd0` on the machine option), both routed into
  the dbus audiodev.
- **`ne2k_pci` user-mode NIC**, inherited from the freedos base disk; GEOS's
  own TCP/IP stack and WebMagick browser are not wired to it yet — see
  *Known gaps*.
- **64 MB RAM, 2 vCPU, KVM, `-cpu host`.** PC/GEOS is designed to run in
  640 KB on a 286; 64 MB and a modern host CPU under KVM leave enormous
  headroom, same reasoning as the fleet's other small-DOS stations.
- **No exec channel.** `operator.labctl.exec_kind` is `null`, `console` is
  `fb`: drive the station with QMP keys/mouse and read the framebuffer.

## Host-native capture path

**Tier 1**, direct-QEMU, KVM-accelerated. The guest's VGA framebuffer is
captured straight off QEMU's dbus display and input goes straight in through
QMP — no kiosk, bridge or second VM in the path.

## Ready scene

`museum.notes` / `reset.fixture`: the PC/GEOS Ensemble desktop (Computer,
Documents, World icons; Meadows wallpaper; taskbar) at 800x600 16-bit, right
after `loader.exe` finishes — a software cursor drawn into the scanout, not a
hardware overlay.

## Checkpoint

- **Re-baked 2026-09-03 (twice) under `/opt/qemu-beos/bin/qemu-system-x86_64`** (the kh-ramabs build): first for the absolute pointer (pve-qemu bake kept as `disk.qcow2.pre-abs-bak`), then without `truetype.geo` after the KR-11 finding (previous kept as `disk.qcow2.pre-kr11-bak`). Current: VM_CLOCK 0000:00:42.439, VM_SIZE 3.47 MiB, `KH_RAMABS_ADDR=0x76e0` re-derived against it (same address: CTMOUSE loads before GEOS). GeoWrite new document + typed text proven on this golden before it was staged. The facts below describe the first bake and still hold except the binary.

- Snapshot name: `golden`, saved via QMP `human-monitor-command` `savevm golden`.
- Carrier disk: `disk.qcow2` is the ONLY block device — staged at
  `/data/vms/streamhost/stations/pcgeos/disk.qcow2` (399,572,992 bytes / 381 MiB
  on disk; 512 MiB virtual). `qemu-img snapshot -l` reports the `golden` tag at
  `VM_SIZE 3.48 MiB`.
- Boot time: cold boot (no `-loadvm`) reaches the full PC/GEOS desktop
  (Computer/Documents/World icons on the orange "Meadows" wallpaper, taskbar at
  the bottom) in ~31 s under KVM (QMP `VM_CLOCK` read `0000:00:30.870` at the
  moment `savevm` ran, after a settle wait past the desktop paint).
- Restore proven: 2026-09-02, one `loadvm` cycle on a sandbox clone
  (`/data/vms/sandbox/pcgeos-golden/`) — quit QEMU after `savevm`, relaunched the
  same launcher (picks up `-loadvm golden -S` automatically once the tag
  exists), sent QMP `cont`, screendumped. The restored frame is byte-identical
  in size (263,816 bytes PNG) to the pre-`savevm` cold-boot frame and shows the
  same settled desktop. One restore only, per the operator's no-proof-gate rule
  (a restoring golden is enough).
- Coldboot-record arm: `pcgeos` case in `scripts/coldboot/bootrec-tiles.conf`
  (`BR_BOOT_KIND=vmstate`, canvas 800x600 @30fps, audio on, `BR_DISKS=disk.qcow2`).

## GeoWrite "System Error Code: KR-11" — the TrueType driver under KVM

Operator, 2026-09-03: GeoWrite → new document showed `System Error Code: KR-11`
(the SPA stream had already lost its typed text to the same fault). KR-11 is
`KS_TIE_PROTECTION_FAULT` in `Library/Kernel/Boot/bootStrings.asm` — a CPU
general-protection fault inside real-mode GEOS. Bisected on sandbox rigs (QMP
`send-key` walk: Ctrl+Esc, 15×Down, Enter, Enter):

| rig | result |
|---|---|
| KVM `-cpu host`, zip `geos.ini` (`font = { truetype.geo }`) | KR-11 every time |
| KVM `-cpu pentium3`, same ini | KR-11 |
| KVM `-cpu host`, `font = { truetype.geo }` removed | new document opens; typed text renders (Nimbus outline fonts, ruler, sizes) |
| GeoPoint new document, any ini | fine (no TrueType path) |

So `truetype.geo` (the FreeType-based driver added to PC/GEOS in 2019) faults
under KVM on the first document; GEOS's own outline fonts do not need it. The
builder now strips that line; the golden was re-baked without the driver.
**Follow-up:** find the faulting instruction in `truetype.geo` (unreal-mode /
32-bit access under a real-mode segment is the usual shape) and report upstream;
until then TrueType fonts in `USERDATA` are not available to visitors.

## Known gaps / next

- **Absolute pointer not attempted.** This station ships relative-only
  (PS/2 + CTMOUSE + the zip's default GEOS mouse driver); an absolute path (à la the fleet's
  `qemu-usb-tablet` stations) has not been evaluated for GEOS.
- **Network.** GEOS has its own TCP/IP stack and a WebMagick browser; the
  device set already carries a user-mode `ne2k_pci` NIC from the freedos
  base, but joining retronet (`periodBrowser: WebMagick (Breadbox)`) is a
  follow-up, not part of this wave.
- **No exec channel.** As with several of the fleet's small-DOS stations,
  there is no ssh/serial path in — everything is QMP keys/mouse plus the
  framebuffer.

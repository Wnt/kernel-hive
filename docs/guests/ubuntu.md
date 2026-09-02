# ubuntu guest — Ubuntu 4.10 Warty Warthog, the first Ubuntu

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-03 in a parallel
wave ([`lab/UBUNTU-WAVE.md`](../lab/UBUNTU-WAVE.md)).

## What it is

Ubuntu 4.10 "Warty Warthog", released October 2004, is the first Ubuntu — a
Debian snapshot with GNOME 2.8 as its single desktop, shipped as a **live CD**
that also doubled as the installer. This station runs the live session
itself, not an install: there is no persistent filesystem, and every reset
returns to the same instant on the desktop.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `ubuntu`
- Display name: **Ubuntu 4.10 Warty Warthog**
- Reserved slot / UDP port / VMID label: `183` / `54183` / `183`
- Archetype: `beige-tower-crt`; era year **2004**, lineage Linux (Debian)
- Upstream: `warty-release-live-i386.iso`,
  <http://old-releases.ubuntu.com/releases/4.10/>, **674,152,448 bytes**,
  SHA-256
  `189746859b539c37d978b107589610aa49a7415f7c089d22667867a918591013`
  (recorded in `/data/assets-staging/ubuntu/MANIFEST.sha256`; installed to
  `/data/gallery-guests/Ubuntu/warty-release-live-i386.iso`).

### Media: the live CD is the OS

There is no install step. The builder writes the ISO alongside an otherwise
**empty 1G qcow2** (`ubuntu.qcow2`) that exists purely as the vmstate carrier
for the golden snapshot — the live session's kernel treats it as scratch, not
a boot device. `-boot order=d` boots the ISO every time; the qcow2 only ever
holds a `savevm` snapshot, never guest-written files.

| property | value |
|---|---|
| ISO | `warty-release-live-i386.iso`, 674,152,448 bytes |
| Builder | `scripts/build-guests/tiles/ubuntu.sh` |
| Builder output | `/data/gallery-guests/Ubuntu/warty-release-live-i386.iso` + `/data/gallery-guests/Ubuntu/ubuntu.qcow2` (empty 1G vmstate carrier) |
| Runtime path | `/data/vms/streamhost/stations/ubuntu/` (QMP, reset-hmp, pid); the disk stays under `gallery-guests` like `redstar2` |

## Device set

`streamhost/stations/ubuntu/qemu-streamhost.sh` is deployed **verbatim**:

```
qemu-system-x86_64 -nodefaults -enable-kvm -machine pc-i440fx-11.0,acpi=off \
  -cpu host -m 512 -smp 1 -rtc base=localtime \
  -drive file=ubuntu.qcow2,format=qcow2,if=ide,index=0 \
  -drive file=<ISO>,format=raw,if=ide,index=2,media=cdrom,readonly=on \
  -boot order=d \
  -vga std -usb -device usb-tablet \
  -display dbus,p2p=on
```

**No NIC, no audio device.** This is deliberate, not an oversight: raced on
three sandbox rigs, `-device AC97` together with ACPI enabled hangs the
2.6.8 live boot at ~12% of the usplash bar (150 s, no framebuffer change,
reproduced under both `-cpu host` and `-cpu Nehalem,kvm=off`). Dropping the
ACPI+AC97 combination — `acpi=off` and no audio device at all — boots clean
to the desktop in ~90 s. The split (whether AC97 alone or ACPI alone is the
actual culprit) was not tested; not needed to ship.

- **Pointer**: `usb-tablet`. Linux 2.6.8's `mousedev` turns the tablet's
  absolute 0..32767 range into PS/2-style deltas scaled against
  `mousedev.xres`/`yres`, which default to **1024x768** — not this screen's
  resolution. See *Pointer status* below.
- **Screen**: `-vga std` (Bochs VGA BIOS), XFree86 comes up at **640x480**
  (vesa, no DDC).
- **No exec channel.** `operator.labctl.exec_kind` is `none`, `console` is
  `fb`: an air-gapped live-CD guest, driven by QMP keys/mouse and read off
  the framebuffer only.

## Host-native capture path

**Tier 1**, direct-QEMU, KVM-accelerated. The guest's framebuffer is captured
straight off QEMU's dbus display and input goes straight in through QMP — no
kiosk, bridge or second VM in the path.

## Checkpoint

Baked on `/data/vms/sandbox/ubuntu-golden/bake/` (empty 1G qcow2, the exact
launcher device set, first boot without `-loadvm`/`-S`):

- Reached the GNOME 2.8 desktop unattended in **~90 s** (`fb-wait.py --settle
  15` settled at 89.5 s). Login user is **`warty`** (not `ubuntu` — an
  earlier ledger assumption, corrected here).
- Idle prep in a terminal: `xset m 1 1; xset s off; gnome-screensaver-command
  -d`, then back to the clean idle desktop.
- Snapshot `golden`, saved via QMP `human-monitor-command savevm golden`:
  **VM_SIZE = 255 MiB, VM_CLOCK = 0000:05:55.667** (`qemu-img snapshot -l`).
- **Restore-proven**: killed the bake clone by pidfile, relaunched with
  `-loadvm golden -S`, QMP `cont`, `fb-wait.py --settle 3 --timeout 30`
  landed on the identical idle desktop in **3.3 s** (same cursor position,
  same icons, same clock).
- Staged at `/data/gallery-guests/Ubuntu/ubuntu.qcow2` — the builder's
  pristine empty carrier was moved aside first to
  `ubuntu.qcow2.bak-pre-golden`.
- Reset mode: `loadvm`, fixture in `streamhost/stations/ubuntu/station.env.fixture`
  (`SH_RESET_MODE=loadvm`, `SH_GOLDEN_SNAPSHOT=golden`,
  `SH_RESET_MONITOR=.../reset-hmp.sock`).
- Fixture description: Ubuntu 4.10 live session logged in as **`warty`** on
  the idle **640x480** GNOME 2.8 desktop, screensaver off, absolute USB
  tablet and keyboard ready.

## Pointer status

**Fixed on the daemon side, framebuffer proof pending the first station-up.**
On the golden clone, a raw QMP `input-send-event` abs move to the screen centre
overshot off the desktop and a move to (0,0) landed at ~(130,390): Linux 2.6.8's
`mousedev` maps the tablet's 0..32767 range onto its default 1024x768 and emits
the *difference* as PS/2-style deltas, while X runs at 640x480, so every raw
move travels 1.6x too far. The station therefore declares
`SH_CURSOR_SCALE=0.625` (= 640/1024, `stream.pointer.scale` in the registry):
the daemon multiplies the client pixel by it before `SetAbsPosition`
(`streamhost/src/input.rs` `set_abs`), which cancels the rescale exactly — the
same mechanism tinycore ships as 0.783. X acceleration is off inside the golden
(`xset m 1 1`), which is required for the delta sum to stay 1:1. A corner
MOVEA that pins the cursor at (0,0) re-syncs X and mousedev after a restore.
Alternative that removes the need for the scale: X at 1024x768 (edit the
`Modes` line in `/etc/X11/XF86Config-4`, restart X, re-bake).

## Rollback

The launcher, ISO and `ubuntu.qcow2` are one set — a `loadvm` reset or a
recapture must keep them matched. The pre-golden empty carrier is kept at
`/data/gallery-guests/Ubuntu/ubuntu.qcow2.bak-pre-golden` for rollback.

## Operator notes

- `kbd`: **Alt+F2** opens GNOME 2.8's Run Application dialog.
- `kbd_reset`: **Escape** closes it.
- `audio_trigger`: none (no audio device on this station).
- Air-gapped: no NIC, no exec channel — everything is QMP keys/mouse plus the
  framebuffer.

## Known gaps / next

- **1024x768 not attempted.** Ships at 640x480; a future stream can resize X
  from a terminal (Alt+F2 → `gnome-terminal`) and restart X
  (Ctrl-Alt-Backspace), which per the ledger should also resolve the pointer
  scale mismatch.
- **Pointer scale is a daemon-side correction** (`SH_CURSOR_SCALE=0.625`), not
  a guest fix — see *Pointer status* above.
- **No network, no audio** by design — AC97 together with ACPI hangs the live
  boot; not revisited since dropping both is sufficient to ship.

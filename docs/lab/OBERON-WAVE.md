# oberon wave — ETH Native Oberon 2.3.6, the Gadgets text desktop

ETH Zurich Native Oberon 2.3.6 (13 May 1999), Niklaus Wirth and Jürg
Gutknecht's Oberon System 3 with the Gadgets UI, i386, QEMU Tier 1. Native
Oberon IS the operating system — there is no host OS under it, and the
compiler, the editor and the window system are one program. The whole
interface is three mouse buttons and their interclicks. Scaffolded
`--like freedos` and then rewritten to its own device set. Baked 2026-09-13.

## Ledger — from `wave.sh alloc oberon`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 195 / 54195 / 195 |
| x11warp display | `:95` (loopback `127.0.0.1:6095`) — allocated but unused; this guest has no in-guest X server |
| retronet address | 10.99.0.42 |
| retronet tap / chain | `oberonrn0` / `OBERONRN-IN` |
| ICQ UIN | 19500 — unused; no IM client exists for this guest |
| sibling (`--like`) | `freedos` for the scaffold only (another `qemu-ps2-relative` x86 station); device set, fixture and pointer numbers are all this station's own |
| device set | `oberon-ps2rel-vesa1280-fdqcow`: `qemu-system-x86_64` (pve-qemu-kvm 11.0.2), `-machine pc-i440fx-11.0,acpi=off -enable-kvm -cpu host`, 64 MB, 1 vCPU, `-vga std` (Bochs VBE 2.0 LFB), `disk.qcow2` on IDE index 0 (only persistent block device), one EMPTY 1.44 MB floppy as QCOW2 (not raw — see wall 2), `sb16` over the dbus audiodev, one `ne2k_pci` NIC on `-netdev user,restrict=on`, dbus display p2p |
| media | third-party ready-made image `NativeOberon-2.3.6-qemu-fallback.img`, 83,886,080 bytes, sha256 `65f21c27cd62ceffab303d7266606f4db3c22e83be462f8a70a0f0ea4f8c60d1`, from `https://github.com/asig/native-oberon` (2.3.6/), direct URL `https://raw.githubusercontent.com/asig/native-oberon/master/2.3.6/Native%20Oberon%202.3.6.img` |

The official ETH installer diskettes (`Oberon0.Dsk`, `OberonCF0.Dsk`) and the
12.3 MB `NativeOberon_2.3.6.tar.gz` release tree are also staged, from the
SourceForge mirror of `ftp.inf.ethz.ch/pub/ETHOberon/Native/`. They are the
documented alternative build-from-floppy path, not what ships — see wall 1.

## Proven in the spine

The ready-made image booted on the first try under the device set above, so
the floppy install path was never raced. Everything below — pointer, middle
click, keyboard, golden — was measured against that one boot.

## Streams

No stream split for this wave; one bake pass proved pointer, middle click,
keyboard and the golden in sequence on `/data/vms/sandbox/oberon/bake/`.

| Stream | Owns | Model | Status |
|---|---|---|---|
| bake | device set, pointer scale, middle-click proof, keyboard proof, golden + restore proof | Opus (lead) | done |
| docs | this file, `docs/guests/oberon.md`, `registry/posters/oberon.md` | Sonnet 5 | done |

## Walls hit

### 1. The from-floppy install wall — INHERITED, not reproduced here

`asig/native-oberon`'s own README records that installing from `Oberon0.Dsk`
under QEMU stops at `Boot.Bin checksum bad`, and that author's working path
went through VirtualBox + `vbox-img convert` instead. This wave did not
re-derive that wall — the ready-made image booted first try, so the floppy
install was never attempted here. Treat the from-floppy path as an **open
item**, not a proven dead end: nobody has raced it against this fleet's QEMU
build to see whether the same checksum failure reproduces.

### 2. `savevm` refused a raw empty floppy — FIXED

The first bake used a raw empty floppy (`floppy-empty.img`) and `savevm
golden` failed with exactly:

```
Error: Device 'floppy0' is writable but does not support snapshots
```

Fix: the empty floppy is QCOW2 (`floppy-empty.qcow2`), created by the
launcher itself with `qemu-img create -f qcow2 ... 1440k` if missing. This is
a device-set change, so it is part of the one golden+binary+device-set
combination (rule 6) — the device set id is `oberon-ps2rel-vesa1280-fdqcow`.

## Proofs (the framebuffer is the only proof — rule 9)

**Pointer — ABSOLUTE 1:1 since 2026-09-13 (`kh-ramabs`).** Full detail, the
address, the three read-only copies and the proof table are in
`docs/guests/oberon.md` §Pointer; the derivation tool is
`scripts/dev/oberon-ramabs-derive.py`. The three things that made this station
different from every other ramabs guest:

1. **Oberon's coordinate is stored `(y, x)`, and its y counts UP from the bottom
   of the screen.** Two independent inversions at once, so it needed its own
   kh-ramabs layout (`point32le_yx` + the y-up conversion against `height`), not
   a flag on an existing one.
2. **A pair search over RAM found nothing**, twice, while the coordinate was
   plainly there — because the diff locator's `xs.min()` is one pixel left of
   the guest's x over some backgrounds (Oberon draws the arrow against whatever
   it sits over). The search that works is **per word, independently, with a
   ±1 tolerance on x**, pairing the survivors afterwards. That single pixel is
   the difference between "this guest has no readable coordinate" and a landed
   station.
3. **The nudge has to stay under Oberon's acceleration threshold.** 1–4 units
   move 1–4 px; 6 units and up move 1.5 px per unit. The first probe attempt
   used 2 units/3 px and failed verification by exactly 1 px on both axes. The
   same fact retro-condemns the old relative fixture: `SH_CURSOR_SCALE=0.6667`
   was measured with 126-unit steps and was simply wrong for small ones.

The pre-abs relative numbers, kept because they are the rollback path: PS/2
relative, exactly 1.5 px per unit at 126-unit steps, `SH_CURSOR_SCALE=0.6667`,
`SH_REL_MAX_STEP=126`, `SH_REL_HOME_TO=600,510`.

**Three-button UI is a hard requirement.** Oberon's whole interface is the
three mouse buttons and their interclicks: LEFT sets the caret, MIDDLE
executes the command word under the pointer, RIGHT selects. The SPA must map
a real middle button through to the guest or half the system — every command
in System.Tool — is unreachable.

**Middle-button / interclick — proven.** After `loadvm golden`, pin + walk
570/420 units → (855,630), the word `System.Directory` in the System.Tool
viewer. One middle click opened a new `Directory` viewer at the bottom of the
right track. Frame `/data/vms/sandbox/oberon/bake/mid.ppm`, crop
`mid-crop.png`.

**Keyboard — proven.** Left click at (960,60) inside System.Log to set the
caret, then `scripts/dev/qmp-type.py --qmp .../qmp.sock --gap 0.08 "Opus
typed this"`. The string appeared in System.Log under the boot banner, no
dropped or scrambled characters. Frames `/data/vms/sandbox/oberon/bake/kbd.ppm`,
crop `kbd-crop.png`. Fixture pacing is the fleet floor
`SH_KEY_PRESS_MS=40` / `SH_KEY_GAP_MS=40`.

**Golden — proven.** `savevm golden` on the bake rig took **0.107 s** and
wrote a **3.51 MiB** vmstate into `disk.qcow2` (snapshot id 1, tag `golden`,
VM_CLOCK 00:26.046). Restore proof: killed the QEMU by `/proc/<pid>/exe`,
relaunched with `-loadvm golden -S`, `cont` — **0.296 s** from launch to
running; the screendump was **pixel-identical** to the frame captured
immediately before `savevm` (PIL `ImageChops.difference(...).getbbox() is
None`), cursor back at `600 510`. Frames
`/data/vms/sandbox/oberon/bake/golden-frame.ppm` and `restore-frame.ppm`.

**Golden fixture description**: the Gadgets desktop at 1280x1024 — the
`System.Log` viewer top right carrying one line, `ETH Oberon System 3 / PC
Native 2.3.6 (13 May 1999)`, the `System.Tool` viewer below it (the command
menu: Script.Open, Compiler.Compile, System.Directory, NetSystem.Tool,
Desktops.OpenDoc, …), the whole left user track empty flat grey, arrow
pointer parked at (600,510).

### Tooling proven end to end

`scripts/build-guests/tiles/oberon.sh --force` was run on labhost start to
finish: it re-fetched the 83,886,080-byte image from the pinned URL, matched
the pinned sha256 and byte size, converted raw -> qcow2 into
`/data/gallery-guests/OBERON/oberon.qcow2`, then BOOTED that output on the
station device set with `-display none` and `fb-wait.py --settle 6`. The
framebuffer **settled after 9.5 s with its last change at 3.3 s** — which is
where the fixture's "boots in 3.3 s" number comes from — and the assertion
passed: 1280x1024, 6 distinct colours, not blank. Artifact:
`/data/gallery-guests/OBERON/verify-desktop.png`.

`scripts/dev/smoke-rig.sh oberon --like freedos --slot 195` published the
guest at `/os/oberon`, dark-launched (`listed: false`). CAVEAT WORTH KNOWING:
`--like` copies the SIBLING's manifest row, so `/os/oberon` first came up
labelled "oberon (smoke rig), 1994, DOS era" with freedos's blurb and app
list. The row was replaced with one built from this station's own
`registry/stations/oberon.json` museum block via
`darklaunch-station.py publish oberon --entry <file>`. Check the label on any
smoke rig before handing the URL to the operator.

`spa/src/ui/keyboard/keyboardProfiles.ts` needs an `OS_FAMILY` entry for
every production streamhost station — it is test-enforced against the
registry in two places, so a new station without one fails `npm test`.
`oberon` is `generic`, and that is the honest answer rather than a
placeholder: Oberon has no chord set at all. Its verbs are clicks and
interclicks on command words; the keyboard only ever feeds text to the caret.

## §Sandbox — this station's reach is the emulator, and nothing past it

Verdict: **emulated machine under the fleet QEMU.** The visitor's reach ends
at the emulated i440fx hardware; Native Oberon is the guest OS on it and has
no path to the host. Launcher line (see
`streamhost/stations/oberon/qemu-streamhost.sh`):

```
qemu-system-x86_64 -name streamhost-oberon -enable-kvm -m 64 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host -rtc base=localtime \
  -drive file=$SDIR/disk.qcow2,format=qcow2,if=ide,index=0 \
  -drive file=$SDIR/floppy-empty.qcow2,format=qcow2,if=floppy,index=0 \
  -boot c $LOADVM -vga std -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device sb16,audiodev=snd0 $NETDEV -device ne2k_pci,netdev=n0${NICMAC} \
  -qmp unix:$SDIR/qmp.sock,server=on,wait=off -pidfile $SDIR/qemu.pid
```

Four rules checked, each holding:

- **No 9p/virtfs/smb/`fat:` host-directory drive.** The only drives are
  `disk.qcow2` and the empty 1.44 MB QCOW2 floppy — both opaque disk images,
  neither a host directory.
- **No `hostfwd`.** The netdev is `-netdev user,id=n0,restrict=on`, the
  fleet's restricted slirp: no route to labhost or the world. The guest's own
  network stack is live enough that QEMU logs `Slirp: Failed to send packet`
  when Oberon's `NetNe2000pci` driver ARPs into it — proof the stack tried,
  not that it reached anywhere.
- **QMP/monitor sockets are host-side.** `qmp.sock` is a UNIX socket under
  the station dir, created by `-qmp unix:...,server=on`; nothing inside the
  guest can see or reach it.
- **No `virtio-serial` or any other host channel** in the device set above.

The nspawn audit block (the checklist for a host-application-as-guest
station like `medley` or `sculpt`) does **not** apply here: no host
application runs at all. Native Oberon IS the machine's whole software stack
from the boot sector up; there is nothing outside the emulator to contain,
because nothing outside the emulator runs on this guest's behalf.

## OPEN items

1. **Retronet web plane — the top open item.** The `ne2k_pci` DEVICE is
   already in the golden and Native Oberon has its own TCP/IP stack
   (NetSystem) and its own driver (`NetNe2000pci.Mod`), so the NIC BACKEND
   can move from slirp to the tap without a re-bake. But no `rn-tapnet.sh` is
   committed for this station (rule 15 — a committed tap script deploys
   fleet-wide on the next `box-deploy --apply`), so the web plane is
   allocated (10.99.0.42, tap `oberonrn0`, chain `OBERONRN-IN`) but not
   proven. Exact next step: bring the tap up, point the guest at 10.99.0.42
   via `NetSystem.Tool`/`Oberon.Text`, and prove `Desktops.OpenDoc` fetching
   a retronet page on the framebuffer before `rn-tapnet.sh` is committed.
2. **From-floppy install** (wall 1) — never raced against this fleet's QEMU
   build. If the ready-made image is ever retired, the next session should
   race the `Oberon0.Dsk` / `OberonCF0.Dsk` install path fresh rather than
   assume the upstream README's checksum wall reproduces here.
3. **IM plane** — n/a. No IM client exists for Native Oberon; UIN 19500 is
   allocated but unused.
4. **Audio is declared, not proven.** `sb16` is in the device set over the
   dbus audiodev because Oberon's own Sound driver is SB16, but nothing on
   this station has made a sound yet. Next step: drive `Sound` from the
   System.Tool and listen on the stream, or drop `audio: true` from the
   registry row.
5. **Cursor template bank covers the grey desktop only.** Teach
   `cursor-locate.py` the black-on-white variant (`learn A.ppm B.ppm --at X,Y`
   with both frames inside a text viewer) so a pointer check over System.Log
   stops reading as NOTFOUND. The pointer tooling works around this today with
   a diff locator (`oberon-ramabs-derive.py`), which needs no template bank but
   carries a ±1 px edge-column error of its own.
6. **`/opt/qemu-beos` still has the old kh-ramabs.** The `point32le_yx` /
   `point16le_yup*` layouts are in patch `0007` and in `/opt/qemu-oberon`; the
   published fork `github.com/Wnt/qemu` and the `third_party/qemu-kernel-hive`
   submodule have NOT been bumped. Next step: apply the regenerated `0007` to a
   fork checkout, push, bump the submodule.

## Measured timeline

Not run — this wave was a single bake-and-document pass, not a multi-stream
landing; `session-timeline.py` is for the coordinator's own transcript.

## Teardown (part of "done" — rule 8)

Every process this wave started, and the check that proved it gone:

| Released | How | Proof |
|---|---|---|
| the dead predecessor's bake QEMU, pid 2530962 | `kill` after asserting `readlink /proc/2530962/exe` = `/usr/bin/qemu-system-x86_64` — never `pkill -f` (rule 5) | `[ -d /proc/2530962 ]` false |
| this wave's own bake QEMU, pid 3122688, `/data/vms/sandbox/oberon/bake/` | same `/proc/<pid>/exe` check | `[ -d /proc/3122688 ]` false |
| the dead predecessor's smoke daemon, pid 2409477 | superseded by `smoke-rig.sh`, which kills and restarts the daemon itself | new daemon pid 3388302 |
| the tile builder's verify QEMU | the builder's own `trap stop_qemu EXIT` | builder exited 0 |

A scan of `/proc/*/cmdline` for `oberon` afterwards finds exactly one
emulator left, pid 3383244 `-name oberon-smoke`, which is **deliberate**: it
is the guest behind `/os/oberon`, waiting for the operator to drive it. Take
it down with
`scripts/dev/smoke-rig.sh oberon --down` — WITHOUT `--release-claims`, because
slot 195, port 54195 and VMID 195 pass to the real station.

Still held, on purpose: the `kh-claim` claims on slot/195, port/54195 and
vmid/195 under session `oberon`, and the retronet allocation (10.99.0.42, tap
`oberonrn0`, chain `OBERONRN-IN`, UIN 19500) — all of which the station
inherits. `ssh lab 'labctl who'` shows them.

Landing (`station-land.sh` under the landing lock, then
`scripts/dev/box-deploy.sh --apply`) is the coordinator's to run: a push is
not a deploy (rule 11).

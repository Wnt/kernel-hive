# Minix 2.0.4 integration wave — 2026-09-13

Minix 2.0.4 (Andrew Tanenbaum's teaching microkernel; the 2.0 line is 1997,
2.0.4 dates from 2003) as a **Tier 1 text-console QEMU station**, scaffolded
`--like freedos`. Part of the five-station evening wave of 2026-09-13
(`macsys1`, `apple2gs`, `minix2`, `xenix`, `os213`) coordinated per
[`WAVE-COORDINATION.md`](WAVE-COORDINATION.md); landing goes through the
`wave.sh land` lock inside `station-land.sh`.

The exhibit is the source tree. Minix 2 is the operating system people *read*:
`/usr/src` holds `kernel`, `mm`, `fs`, `inet`, `commands`, `lib` and `tools`,
and the golden fixture puts that listing on the screen at a root shell.

## Ledger — from `scripts/dev/wave.sh alloc minix2`

| Field | Value |
|---|---|
| slot / UDP port / VMID | 201 / 54201 / 201 |
| x11warp display | — (text console, no in-guest X) |
| retronet address / MAC / tap / chain / UIN | — (retronet OPEN, see below) |
| sibling (`--like`) | `freedos` |
| SPA hardware tuple | `towerE,crtF,keyboardH,paramMouseG` (distinct from freedos's `pizzaBoxB,crtA,keyboardA,paramMouseA`) |
| render orders | as scaffolded: signal 88 / stationsManifest 86 / binding 102 / golden 86 / actionMap 50 / bringUp 102 |
| device set | QEMU 11.0.2 KVM, `pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, `-cpu host`, `-m 32`, `-smp 1`, `-vga std`, `-boot c`, IDE disk **with explicit CHS 200/16/32**, no NIC, no floppy |
| pointer | `none` (text console) |
| keyboard pacing | fleet floor 40/40 — no dropped characters measured |
| audio | PC speaker only (Minix console bell) through the dbus audiodev; no sound card in the guest |
| media | `mx204bx01.zip` 7,179,269 B from `https://minix1.woodhull.com/pub/demos-2.0/BochsImage/mx204bx01.zip`; its `minix204/minix.img` 52,428,800 B sha256 `012dc3b9…c79e` is the station disk |
| media (provenance set) | official 2.0.4 install set, `i386/ROOT.MNX` 491,520 B sha256 `f7fcafb3…e9c8`, `i386/USR.MNX` 737,280 B sha256 `c5a9b0e8…a465`, plus `USR.TAZ`/`SYS.TAZ`/`CMD.TAZ`/`FIX.TAZ` |

### Provenance: three origins agree

The station ships a *pre-installed* disk, which always needs an argument that it
is the real distribution. Here it is, and `scripts/build-guests/tiles/minix2.sh`
asserts it on every build:

1. The media agent fetched the official install set from
   `https://minix1.woodhull.com/current/2.0.4/`.
2. The wave lead independently fetched the same set from
   `http://download.minix3.org/previous-versions/Intel-2.0.4/` and verified every
   file against **that directory's own `md5list`** — all matched.
3. `root.img` and `usr.img` *inside* Woodhull's Bochs package are byte-identical
   (same sha256) to both copies of the official `ROOT.MNX`/`USR.MNX`.

So the pre-installed image comes from the same hand, and the same bits, as the
official floppies. The builder fails loudly (`provenance broken`) if that ever
stops being true.

## Proven in the spine (lead, alone) — all on the framebuffer

Frames live in `/data/vms/sandbox/minix2/smoke/` (sandbox, not committed).

| Frame | What it proves |
|---|---|
| `f01-boot.png` | `Minix boot monitor 2.19` from the official ROOT floppy — first framebuffer |
| `f04-disk.png` | boot monitor from the **hard disk** image, offering `= Start Minix` / `n Start Networked Minix` |
| `f05-boot.png` | full boot: `Minix 2.0.4 Copyright 2001 Prentice-Hall, Inc.` · `Executing in 32-bit protected mode` · `at-d0: QEMU HARDDISK` · `Memory size = 32328K  MINIX = 291K  RAM disk = 0K  Available = 32037K` · `/dev/c0d0p2 is read-write mounted on /usr` · `Minix Release 2 Version 0.4` · login prompt |
| `f06-login.png` | `login: root` with **no password** reaches the `#` shell |
| `f07-src.png` | `/usr/src` = `LICENSE boot etc inet lib tmp / Makefile commands fs kernel mm tools` — the exhibit exists |
| `f08-fixture.png` | the golden fixture screen: `Minix minix 2 0.4 i686` + the `/usr/src` listing |
| `f09-keyproof.png` | **keyboard proof**: `echo KEYBOARD PROOF minix2 2026-09-13` echoed and printed, every character, at 40/40 |
| `f10-restore.png` | **restore proof**: `loadvm golden` wiped the typed lines and returned the exact fixture |

Golden: QEMU `savevm golden`, vmstate 1.62 MiB, taken on
`/data/vms/sandbox/minix2/smoke/rig.sh` with the same device set the shipped
launcher uses. `resetMode=loadvm`.

One guest at a time, KVM throughout, no race clones were needed or started.

### Two edits made to the image before the bake

- `/etc/hostname.file` was `bochs-minix.local.net`; set to `minix` so the exhibit
  does not advertise a different emulator. `hostname minix` applied live.
- Nothing else. No packages, no config, no network.

## Cold boot waits for a key — on purpose

Without the snapshot the launcher cold-boots to the Minix boot monitor 2.19 menu
and **stops there** until `=` is pressed. That is the real machine's behaviour and
it is what the cold-boot arm calibrates against; the station normally starts from
`-loadvm golden -S`, so a visitor never sees it.

## Walls

### 1. The official floppy install set fails under KVM — ABANDONED, not raced

Booting `ROOT.MNX` (padded to 1,474,560 B) as `-fda` with `USR.MNX` on `-fdb`:
the boot monitor loads, `=` starts the kernel, and the RAM-disk copy then throws

```
Unrecoverable disk error on device 2/0, block 269
fs: I/O error on device 2/0, block 287
… (every 18th block, to "RAM disk loaded.")
```

Errors begin at block 269 and recur every **18** blocks — i.e. the last sector of
each 18-sector track — so this is a floppy geometry/track-boundary problem in the
`-drive if=floppy` path, not bad media (all four md5s match the publisher's
`md5list`). **This was never raced to a root cause**: the pre-installed hard disk
image landed from the media agent one minute later and made the whole install
path unnecessary. It stays OPEN for anyone who needs to install Minix 2 from
floppies under QEMU; the theories worth racing first are (a) unpadded 491,520 B
image so QEMU picks a 720K-style geometry, (b) `-accel tcg` for FDC timing, (c)
the documented single combined 1.44 M floppy with USR on partition `p2`.

### 2. IDE geometry

The disk is attached with explicit `cyls=200,heads=16,secs=32` on the `ide-hd`
**device** (QEMU 11 rejects `cyls=` on `-drive`). This worked on the first try and
is what the golden is baked against. Whether QEMU's *auto* geometry would also
work was not tested — the os213 lead found explicit geometry to be a regression on
its guest, so if this station is ever rebuilt, auto is worth one frame of testing.
Changing it is a device-set change and needs a new golden (rule 6).

## Retronet: OPEN

Minix 2.0.4 does ship an `inet` server and a `dp8390`/NE2000 driver, so a tap NIC
is technically reachable. There is no period web browser and no IM client for
Minix 2, so a retronet join would buy the station nothing a visitor can see. No
`--retronet` allocation was taken and **no `rn-tapnet.sh` is committed** (rule 15).
Revisit only if someone ports or finds a Minix 2 client worth showing.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| `minix2-media` | `/data/assets-staging/minix2/` + `MANIFEST.sha256` + `SOURCES.md` | (coordinator's) | delivered the pre-installed image; the lead had already fetched the official set independently, which became the provenance cross-check |
| spine (`build`+`golden`) | launcher, fixture, registry row, tile builder, hero, golden bake and both proofs | Opus | done, this branch |
| `minix2-spa` | poster prose, hero, scene rows | (coordinator's) | merged at landing if it exists |
| `minix2-docs` | `docs/guests/minix2.md`, `GUEST-TIERS.md`, release-notes facts | sonnet-low | branch `minix2-docs` |

## Teardown

The smoke rig (`smoke-rig.sh minix2 --down`) and its QEMU are taken down by
`station-land.sh`; slot/UDP/VMID 201 pass from session `minix2` to the station.

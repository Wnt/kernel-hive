# Macintosh System 1.0 integration wave — 2026-09-13

Macintosh System Software 1.0 (version string 0.97) with **Finder 1.0**, running on
an emulated **Macintosh 128K** (January 1984) under the fleet MAME 0.289,
**host-native** (drawshm frames, ctlsock input, FIFO audio — no bridge kiosk, no
nspawn container). Tier 1 station scaffolded `--like apple2e`, the fleet's other
`apple/` MAME-native machine. This wave runs beside four others
(`apple2gs`, `minix2`, `xenix`, `os213`) under the evening five-station wave;
coordination contract in `WAVE-COORDINATION.md`, landing through
`scripts/dev/station-land.sh` which takes the landing lock.

## Ledger — from `scripts/dev/wave.sh alloc macsys1`

| Field | Value |
|---|---|
| slot / UDP port / VMID | **199 / 54199 / 199** |
| x11warp display | — (not allocated: host-native MAME captures through drawshm, there is no guest X server) |
| retronet address / MAC / tap / chain / UIN | — (**retronet: NONE.** A Macintosh 128K has no networking stack to run: no TCP/IP, no browser, no IM client existed for System 1.0 in 1984. AppleTalk arrives with the Mac Plus/LaserWriter in 1985–86 and is not an internet plane. Recorded OPEN and permanently out of scope for this machine.) |
| sibling (`--like`) | `apple2e` |
| render orders | signal 88 / stationsManifest 86 / binding 102 / golden 86 / bringUp 102 — as scaffolded, not hand-edited |
| SPA hardware tuple | `compactA,compactA,keyboardG,paramMouseF` (body/monitor = the compact all-in-one case, the only station in the hall that holds `compactA|compactA`; `keyboardG` is the smallest keyboard in the kit, the honest silhouette for the M0110; `paramMouseF` is the one-button mouse) |
| device set | mac128k's own fixed config: 68000 @ 7.8336 MHz, 128 KB RAM, RTC3430040, IWM with **two 400K single-sided drives** (`fdc:0`/`fdc:1` = `-flop1`/`-flop2`). No slots, no NIC, no hard disk — a 1984 Mac had none. |
| media | see below — all four artifacts measured with `stat -c "%n %s"` + `sha256sum` on labhost |

### Media (staged by `macsys1-media` at `/data/assets-staging/macsys1/`, MANIFEST.sha256 written last)

| File | Bytes | sha256 | What |
|---|---|---|---|
| `mac128k.zip` | 99174 | `0f01b231…c51c8fa` | MAME romset: `342-0220-a.u6d` + `342-0221-a.u8d`, the 64 KB Mac 128K boot ROM |
| `mackbd_m0110.zip` | 1021 | `b0c4b818…fb3f834` | MAME **device** romset: `ip8021h_2173.bin`, the Intel 8021 MCU inside the M0110 keyboard |
| `system-disk-1.0.dc42` | 419284 | `b63062a6…e334e3b1` | DiskCopy 4.2, 409600-byte GCR CLV ssdd 400K — the January 1984 "Macintosh System Disk" (System 1.0/0.97 + Finder 1.0) |
| `write-paint-1.0.dc42` | 419284 | `4733d46b…748e18a17` | the companion "Write/Paint" 400K disk — **MacPaint 1.0 + MacWrite 1.0** |

Origins and licence posture: `/data/assets-staging/macsys1/SOURCES.md` (ROMs from
archive.org MAME romset mirrors, disks from earlymacintosh.org). Nothing was copied
from `/mnt/vom`. **No bits are committed** — only URL + sha256 + byte size, in
`scripts/build-guests/tiles/macsys1.sh`.

## Sandbox verdict (WAVE-COMMON, required)

**No nspawn container.** This station is an EMULATED MACHINE under the fleet MAME
0.289: the visitor's reach ends at the Motorola 68000 and the two emulated 400K
drives. There is no host application acting as the guest, so the medley rule
(`docs/lab/OPERATING-RULES.md`, no unsandboxed host-app stations) does not apply —
this is the same posture as every other MAME-native station (`apple2e`, `fmtowns`,
`atari800xl`, `samcoupe`).

Launcher line (the shared `streamhost/stations/mame-native/x11-runtime.sh` composes it
from the fixture):

```
/data/vms/streamhost/assets/macsys1/mame-native/mac128 mac128k \
  -rompath /data/vms/streamhost/assets/macsys1/mame-native/roms \
  -flop1 /data/vms/streamhost/assets/macsys1/media/system-disk-1.0.dc42 \
  -flop2 /data/vms/streamhost/assets/macsys1/media/write-paint-1.0.dc42 \
  -video shm -sound ... -skip_gameinfo
```

Forbidden and absent: no 9p/virtfs/smb/`fat:` host drive, no `-netdev user` hostfwd
(no NIC at all), no guest-reachable QMP/monitor (MAME has no QMP; the ctlsock is a
host-side unix socket the guest cannot address), no virtio-serial host channel.

## Proven in the spine (lead, alone)

1. **The machine and the media boot to Finder 1.0.** Stock labhost MAME **0.276**
   (`/usr/games/mame`) under Xvfb `:99`, `-rompath /data/assets-staging/macsys1`
   (MAME reads the TorrentZips directly), `-flop1 system-disk-1.0.dc42
   -flop2 write-paint-1.0.dc42`:
   - `frame-12s.png` — the white "**Welcome to Macintosh.**" box with the 1-bit
     Mac-and-mouse icon. (`/data/vms/sandbox/macsys1/smoke/frame-12s.png`)
   - `frame-37s.png` — **the Finder 1.0 desktop**: the Apple/File/Edit/View/Special
     menu bar, the dithered 50% desktop pattern, **both** floppies mounted as
     `System Disk` and `Write/Paint` icons, and the Trash.
     (`/data/vms/sandbox/macsys1/smoke/frame-37s.png`) — 452336 lit pixels of 786432
     on the 1024x768 surface, i.e. the Mac's 1-bit raster is mostly LIT, the inverse
     of every other station's gate assumption.
   The rompath needs **both** romsets: with only `mac128k` extracted flat, 0.276 says
   `ip8021h_2173.bin NOT FOUND (tried in mackbd_m0120 mackbd_m0110 mac128k)` and
   refuses to run. Since MAME 0.221 the Macintosh keyboard is its own emulated i8021
   device.
2. **`mac128k` is `MACHINE_SUPPORTS_SAVE` and status good** — read from the driver
   source at the fleet pin (`src/mame/apple/mac128.cpp:1634` @ `mame0289`). So this
   station needs **neither** `mame-irix-skip-warnings.patch` (no MACHINE_NOT_WORKING
   nag panel to pause a headless kiosk) **nor** `MAME_NATIVE_CHECKPOINT=0`: the shared
   launcher's savestate restore applies unmodified, like `apple2e`.
3. **The pointer ioports, from source** (`mac128.cpp:1403-1411`, input map `macplus`).
   A Mac 128K has **no ADB** — the mouse is the quadrature mouse read through the VIA,
   exposed as three **top-level** ioports:
   `MOUSE0` = `IPT_BUTTON1` PORT_NAME("Mouse Button"), `MOUSE1` = `IPT_MOUSE_X`
   (0xff mask), `MOUSE2` = `IPT_MOUSE_Y` (0xff mask). Hence
   `MAME_CTL_PTR_TAGS=":MOUSE0,:MOUSE1,:MOUSE2"`, `MAME_CTL_BTN_NAMES="Mouse Button,,"`,
   `MAME_CTL_PTR_MOD=256` (8-bit fields, not the module's 65536 SGI default).
   The `mame-ctlsock-ptr-tags.patch` type-based `IPT_MOUSE_X/Y` match (the fmtowns
   fix) is what binds MOUSE1/MOUSE2 at all — their PORT_NAMEs are MAME's generated
   defaults, not the module's hardcoded "Mouse X"/"Mouse Y".

## Build

`scripts/build-guests/emulators/native.d/macsys1.sh` — `NATIVE_DRIVER=mac128k`,
`NATIVE_SUBTARGET=mac128`, `NATIVE_SOURCES=src/mame/apple/mac128.cpp`,
`NATIVE_GEOM=1024x768`, `NATIVE_MAME_ARGS=()` (the driver fixes its own device set;
the floppies are handed over at launch through the fixture's `MAME_NATIVE_ARGS`, the
fmtowns `-cdrom` shape). Patch stack = the three base patches + the apple2e
open-loop pointer stack (`ptr-tags`, `move-step-cap`, `open-loop-gain`, `home-drain`,
`count-carry`) — same reason as apple2e: an 8-bit delta field the guest nets and
drains, and no host-readable cursor register, so MOVEA runs open-loop.

Run with `JOBS=4`, in the fleet builder (ccache wired), work dir
`/data/vms/sandbox/macsys1/BUILD-native-macsys1`, output
`/data/vms/sandbox/macsys1/build/mac128`.

## Walls hit

### Wall 1 — `git fetch --tags origin` blew up on a seeded MAME tree (spine, ~1 min)

To skip a fresh `git clone --filter=blob:none` of MAME (minutes on a box at load 40),
the work tree was seeded by cloning the already-checked-out
`/data/vms/sandbox/BUILD-native-apple2e/mame` locally (hardlinks, instant) and then
pointing `origin` at upstream GitHub. `build-mame-native.sh`'s mandatory
`git fetch -q --tags origin` then died:

```
fatal: pack has 14340 unresolved deltas
fatal: fetch-pack: invalid index-pack output
```

— a local clone of a `--filter=blob:none` repo does not carry the promisor
configuration the upstream fetch needs. **Fix:** leave `origin` pointing at the
local donor tree (`git remote set-url origin /data/vms/sandbox/BUILD-native-apple2e/mame`);
it already carries the `mame0289` tag, `git fetch --tags` is instantaneous and the
script's `git rev-parse HEAD == $MAME_BASE` assertion still proves the pin.
Not raced — the failure named its own cause.

**Trap for other MAME leads:** seeding a native build work dir from a sibling's tree
is a big win (893 MB, instant, and the ccache is shared anyway), but you must point
`origin` at the donor, not at GitHub.

### Wall 2 — the scaffold's aux keymap keeps the sibling's filename

`stations-registry.py new macsys1 --like apple2e` rewrites the *directory* in the
registry row's aux paths but not the *filename*, so it emitted
`streamhost/stations/macsys1/apple2e.keymap` and then refused its own output:

```
registry/stations/macsys1.json: referenced aux path does not exist:
  streamhost/stations/macsys1/apple2e.keymap
```

and rolled the whole scaffold back (leaving the two SPA scene shards modified —
`git checkout --` them before retrying). **Fix used:** pre-create
`streamhost/stations/macsys1/apple2e.keymap` (a copy of the sibling's) so the scaffold
completes, then rename it to `macsys1.keymap` and rewrite the two aux references
(`runtime.x11.emitArgs`, `runtime.x11.auxFiles`) in the registry row. The real keymap
is regenerated from the built binary with `scripts/dev/mame-keymap.py` against a live
`ctl.sock`. **This bites every MAME-native station scaffolded `--like` another one.**

## Open items

| Item | Why | Exact next command |
|---|---|---|
| retronet / IM plane | Permanently out of scope: 1984 Macintosh, no TCP/IP stack exists for System 1.0 | — |
| `mackbd_m0120` (numeric keypad romset) | Not staged; not in the default `mac128k` slot config and `-verifyroms mac128k` passes without it | only if a keypad demo is ever wanted |

## Golden bake — proofs (all on the framebuffer, real fleet binary)

Binary `sha256 583d07a0efc3167b2ad1b31cd734c8961e909e7005f959eb0c4a01eb64f7567b`
(`SUBTARGET=mac128`, driver `mac128k`, MAME `mame0289`). Rig = the station dir
`/data/vms/streamhost/stations/macsys1` (for a MAME-native station the rig IS the
station dir — `smoke-rig.sh` drops every `MAME_NATIVE_*` line and the shared
`x11-runtime.sh` hardcodes `BASE=/data/vms/streamhost/stations/$SH_STATION`).
Frames in `/data/vms/sandbox/macsys1/frames/`.

| # | What | Result | Frame |
|---|---|---|---|
| 1 | Cold boot on the fleet binary via drawshm | Finder 1.0 desktop, both volumes mounted | `02-desktop.png` |
| 2 | `SAVEST golden` | `OK ms=27 bytes=63068 paused=0` → `sta/mac128k/golden.sta` | — |
| 3 | Relaunch with `-state golden` | **2.4 s wall** to the identical desktop (cold boot is ~37 s) | `03-restore.png` |
| 4 | Pointer gain, `MOVE 100 0` / `MOVE 0 100` | 396 published px each → **3.96 px/count on both axes** | `p0/p1/p2.png` |
| 5 | Four-target `MOVEA` readback @ gain 3.96 | (300,200) −4,+4 · (700,500) 0,+8 · (150,600) −6,+8 · (850,150) +2,+2 — **worst 8 px** | `t-*.png` |
| 6 | `MOVEA` onto the System Disk icon + `CLICK1` | icon inverted, Write/Paint deselected — 13604 px changed | `c2.png` |
| 7 | `KEY` down/up Command + `o  O` | 1900 px changed inside the icon label — characters rendered | `k1.png` |
| 8 | Relaunch from golden with both floppies mode 444 | identical desktop, no locked-disk dialog | `04-golden-ro.png` |

### Pointer — the ONE open item is a constant offset, not drift

Unlike apple2e (whose arrow walks off over three laps), this station's landings do
not drift: worst error 8 px across four targets, and a click selects what it is
aimed at. What it has instead is a **constant +42 px Y offset**, and it is
geometric, not arithmetic: the 512x342 raster is letterboxed into the published
1024x768 surface as **1024x684**, with a 42 px black band top and bottom. The
guest's cursor origin therefore sits at published `y=42`, while the ctlsock
module's belief origin — the corner its homing slam clamps into — is published
`y=0`. Every landing is 42 px below the module's target (the table above was aimed
with the offset pre-subtracted), and the bottom ~84 px of the module's coordinate
space is unreachable.

The station ships `stream.pointer.transport = none` until that is carried properly.
**NEXT:** set `stream.pointer.offset = [0, -42]` in the registry row (the field
already exists), redeploy, and re-run the four-target table aiming at **raw**
surface coordinates; prove it from the real SPA on CT950, not from the rig.
Every letterboxed MAME-native station has this shape — `apple2e` (560x192) and
`fmtowns` included — so the fix is probably fleet-wide, not per-station.

### Keyboard — two traps in the field names

1. `mac128k`'s default slot chain puts an **M0120 numeric keypad in front of the
   keyboard**, so every key field lives at `:kbd:pad:kbd:us:ROWn` and the keypad's
   own keys at `:kbd:pad:ROWn`. `mame-keymap.py`'s default `--tags :kbd:` filter
   finds nothing useful; **use `--tags ':'`**. 71 keys mapped, 22 unmatched (the
   three `:MOUSE*` ports and the keypad).
2. MAME's field names carry the shifted legend with **double spaces** — `o  O`,
   `1  !`. A `KEY` verb spelled `O` is rejected `ERR noport`. The generated keymap
   has them right; hand-typed ctlsock verbs must copy the field name verbatim.

### Media integrity — a smoke rig that mounts staging media MUTATES it

The first smoke boot passed `/data/assets-staging/macsys1/*.dc42` straight to
`-flop1`/`-flop2`. Finder 1.0 wrote to the Write/Paint volume, and its sha256
stopped matching the media agent's `MANIFEST.sha256`
(`4733d46b…` → `9ac7dc2a…`). Both images were re-fetched from the origin
(`https://earlymacintosh.org/disk_images/Finder%201.0.zip`), reinstalled into
`/data/vms/streamhost/assets/macsys1/media/` **and** back into the staging dir,
`MANIFEST.sha256` regenerated, and both copies set **mode 444** in both places.
Both now hash exactly as the manifest says.

**Rule for every future MAME/QEMU smoke rig: never hand staging media to a guest
that can write to it.** Copy it first, or mount it read-only.

Write-protection is also the right answer for the exhibit itself, not just for
provenance: Finder 1.0 renames a volume from a single click on its icon label, so
a writable image would carry the first visitor's typo to every visitor after them.
Both floppies ship `444`; the desktop comes up unchanged.

## Streams

| Stream | Owns | Model | Status |
|---|---|---|---|
| lead (spine + build + golden) | native.d stanza, fixture, registry, this doc | Opus | done |
| `macsys1-media` | `/data/assets-staging/macsys1/` + `SOURCES.md` + `MANIFEST.sha256` | — | done |
| `macsys1-spa` | poster, hero, scene tuple, `classicmac128` keyboard family | — | merged (fast-forward) |

## Open items

| Item | Why | Exact next command |
|---|---|---|
| absolute pointer | constant +42 px letterbox offset (above); landings otherwise within 8 px and clicks land | set `stream.pointer.offset=[0,-42]`, redeploy, re-run the four-target table on raw surface coords from the real SPA |
| audio | `stream.audio` is declared and the FIFO is wired; the Mac's 1984 sound is a boot chime and Finder beeps — not proven on this pass | operator validates by ear |
| the MacPaint/MacWrite demo | the Write/Paint volume is mounted and visible on the desktop, but no `demoProgram` drives a double-click into MacPaint yet | needs the pointer offset above first |
| retronet / IM | permanently out of scope — a 1984 Macintosh has no TCP/IP | — |
| `mackbd_m0120` romset | not staged; not needed (`-verifyroms mac128k` passes, and MAME resolves the keypad's ROM from `mackbd_m0110`'s file) | only if a keypad demo is wanted |

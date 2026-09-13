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

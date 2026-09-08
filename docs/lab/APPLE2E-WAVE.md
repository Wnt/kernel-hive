# apple2e wave — Apple //e, ProDOS, AppleWorks + Dazzle Draw + Angry Birds behind a boot menu

Operator ask (2026-09-08): the existing `apple2` station shows a 1988 GEOS desktop,
which almost nobody ran on an Apple II in the day. Add a **second Apple II station
next to it** that shows the period-typical machine: ProDOS, **AppleWorks** (the
80-column productivity suite) and **Dazzle Draw** (double hi-res paint), reachable
through a one-keypress selector in the spirit of the FreeDOS station's
`MENU.BAT`. If the selector works well, add the modern **Angry Birds** port
(8-Bit Shack, double lo-res) as a third entry. Sources the operator named: the
8-Bit Guy's "How the Apple ][ Works!" (YouTube VStscvYLYLs — names AppleWorks
as the 80-column app and Dazzle Draw as the double-hi-res showcase, and shows
Angry Birds in double lo-res) and "What Woz Knew" (lunarmobiscuit.com, 2022)
for the exhibition notes.

Rule 13 applies: `apple2` is a legacy LinApple bridge kiosk; the new station
lands **host-native** on the MAME path the nine de-bridged stations use
(`stations/mame-native/x11-runtime.sh`, drawshm frames, ctlsock keys, FIFO
audio) — `mpf2` is the closest sibling (same driver family, `apple/`).

## Ledger (allocated by `wave.sh alloc apple2e`, session `apple2e`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| apple2e | apple2e | 185 / 54185 / 185 | — | — (an Apple //e has no network plane) |

| Fact | Value | Measured by |
|---|---|---|
| Display bookkeeping (inert, `runtime.x11.display`) | `:73` | spine |
| Scene tuple | `eightBitWedgeA,homeCrtD,none,paramMouseD` | spine (scaffold refused apple2's tuple; keyboard is built in) |
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Driver | `apple2ee` — Apple //e (enhanced), 1985, `MACHINE_SUPPORTS_SAVE` | spine, `src/mame/apple/apple2e.cpp:6371` |
| Device set (target) | `-sl4 mouse` (Apple II Mouse Card), `-sl6 diskiing` (Disk II, default), `-sl7 cffa2` (CFFA 2.0, `-hard1 <volume>.hdv` / `.2mg`), aux `ext80` (default, 128 KB) | spine from stock MAME 0.276 `-listslots/-listmedia`; **native stream confirms on 0.289** |
| Mouse card ioports | `:sl4:a2mse_button` ("Mouse Button", BUTTON1), `:sl4:a2mse_x`, `:sl4:a2mse_y` (IPT_MOUSE_X/Y, sensitivity 40) | spine, `bus/a2bus/mouse.cpp:83-85,157-164` |
| ROMs the driver wants | apple2ee: `342-0265-a.chr`, `342-0304-a.e10`, `342-0303-a.e8`, `341-0132-d.e12`; diskiing: `341-0027-a.p5`; mouse: `341-0270-c.4b`, `341-0269.2b` (+ two PAL dumps); cffa2 firmware: see `-listroms` on the 0.289 build | spine from source; **native stream stages by sha1 via `stage-romset.py`** |
| Published surface | 1024x768 (mpf2 convention, MAME aspect-corrects 560x192) | native stream re-measures |
| Boot volume | `/HIVE` ProDOS volume, 32 MB `.hdv`, boots from slot 7 (the //e scans 7→1) | media stream |
| Media (Asimov mirror `mirrors.apple2.org.za/ftp.apple.asimov.net/images/`) | `masters/prodos/ProDOS_2_4_2.dsk` (or Apple's `ProDOS_2_0_3.dsk`), `productivity/integrated/appleworks/v3.0/`, `productivity/graphics/dazzle_draw/Dazzle Draw v1.2 (Broderbund-1988).dsk` + `dazzledraw1/2.dsk`, Angry Birds: `https://8bitshack.org/post/angrybirds/` (free DSK) | media stream hashes + sizes |
| Tooling | `a2kit 4.4.2` at `/data/vms/sandbox/apple2e/tools/a2kit` (built from crates.io, CT950 and labhost) ; stock `mame 0.276` at `/usr/games/mame` on labhost for quick media boots | spine |

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| native | `apple2e-native` | `scripts/build-guests/emulators/native.d/apple2e.sh`, ROM staging under `/data/assets-staging/apple2e/roms/`, the built binary under `/data/vms/streamhost/assets/apple2e/mame-native/`, `streamhost/stations/apple2e/apple2e.keymap`, `station.env.fixture` (MAME_NATIVE_*, MAME_CTL_PTR_TAGS/BTN_NAMES, pacing), registry `runtime`/`reset`/`stream.pointer` truth | sonnet |
| media | `apple2e-media` | `scripts/build-guests/tiles/apple2e.sh` (fetch, SHA-256, compose the `/HIVE` volume with the STARTUP menu), `/data/assets-staging/apple2e/media/`, the composed `hive.hdv`, `check-assets.sh` / `ASSETS-MANIFEST.md` / `os-media-catalog.md` rows | sonnet |
| spa (after both) | `apple2e-spa` | `registry/posters/apple2e.md`, hero + frames, `museum`/`spa` prose, `keyboardProfiles.ts` | Fable (museum voice) |
| docs (after native) | `apple2e-docs` | `docs/guests/apple2e.md`, release notes | sonnet-low |

One owner per file. A stream that needs another's fact reads this ledger or
waits for the report.

## The selector (what "autoexec menu on an Apple II" means)

ProDOS 8 + `BASIC.SYSTEM` auto-runs an Applesoft program named `STARTUP` on the
boot volume — that file is the Apple II's `AUTOEXEC.BAT`. The menu is an
Applesoft program: `TEXT: HOME`, a boxed 40-column list, `GET K$`, and per
choice `PRINT CHR$(4);"PREFIX /HIVE/AW"` then `PRINT CHR$(4);"-APLWORKS.SYSTEM"`
(the `-` command runs SYS/BIN/BAS files). A protected/bootable-only disk is
instead booted from slot 6 (`PRINT CHR$(4);"PR#6"` with the image in `flop1`).
Return path: the station reset (relaunch) always lands on the menu; a
`[Q]`/Reset line on the menu says so.

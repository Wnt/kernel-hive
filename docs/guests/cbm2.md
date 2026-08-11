# Commodore CBM 610 (PAL) — gallery station notes (udp/54111)

**Guest:** a captured **Debian 13 (trixie) x86_64 kiosk** running **VICE `xcbm2 -model
610`**, emulating a **PAL Commodore CBM 610** — the CBM-II / B-series business
machine of 1982 — at its own untouched power-on screen. A **kiosk**:
streamhost captures the Linux framebuffer + AC97 audio exactly like every
other kiosk. See **`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base-trixie.qcow2` — already contains the
whole VICE family.
**Build script (station):** `scripts/build-guests/tiles/cbm2.sh` — thin overlay + kiosk
`launch.sh` + ROM repair/assert + quiet console + memory assertion + checkpoint capture
+ a framebuffer-asserted keyboard proof, fully automated, ~2 minutes.
**Station dir (host):** `/data/vms/streamhost/tiles/cbm2/`.
**Registry entry:** `registry/tiles/cbm2.json` (slot 111, udp 54111, VMID 226,
ssh hostfwd 127.0.0.1:5826).

## What the machine is — and why it is not the station next door

The CBM-II (sold in Europe as the CBM 6x0/7x0, in the US as the B series) was
Commodore's 1982 push into small business. It is a **MOS 6509** at 2 MHz: a
6502 with two extra registers that page one of sixteen 64 KB banks into the
address space, so the CPU reaches **a full megabyte** — an unusual answer, in
1982, to the 6502's 64 KB ceiling. The 610 ships 128 KB of that, an 80x25
monochrome CRTC screen, a SID for sound, IEEE-488 for disks and printers, and
**"BASIC 128" v4.0** in ROM.

**The name is a coincidence and a trap.** "commodore basic 128" here means
*128 KB of RAM*, three years before the Commodore 128 of 1985, with which this
machine shares no hardware, no ROM and no software.

**The honest exhibit risk:** the cold screen is a green 80-column CBM BASIC
banner, and so is the `cbm8032` station's. At a glance they are close. What makes
this a different exhibit is not the frame, it is the machine behind it, and the
placard is written to make that unmistakable within one sentence:

| | cbm8032 (PET, 1980) | **cbm2 (CBM 610, 1982)** |
|---|---|---|
| CPU | 6502, flat 64 KB | **6509, 128 KB banked out of a 1 MB space** |
| Form | all-in-one, screen bolted to the case | **low-profile box, detached monitor** |
| Aim | schools, labs, the machine that worked | **small business — the machine that did not** |
| Fate | sold for years | **cancelled within about a year** |

If the gallery ever needs to cut one of the two, this is the one to argue about:
the 8032 has the stronger claim to the shelf on merit, and this station's case
rests on being the *failure* beside it. That judgement is the operator's; both
are built so it can be made from a real frame rather than from a description.

## Media and license — there is none to stage

Like `vic20` and `plus4`: VICE bundles the Commodore ROMs, and a CBM 610 boots
to BASIC with **zero media attached** — no disk, no cartridge, no licensed
image, no `check-assets.sh` row.

- **VICE 3.9** — GPLv2; bundles the CBM-II BASIC/KERNAL/chargen ROMs for
  emulation use.

`cbm2.sh` still repairs the CBM-II ROM directory from the source tree the base
retains (`/usr/local/src/vice-3.9/data/CBM-II/`) and then **asserts** the three
images a 610 loads plus the profile that selects them — `basic-901242+3-04a.bin`,
`kernal-901244-04a.bin`, `chargen-901237-01.bin`, `rom128l.vrs`. The installed
tree measured complete on this base (the only difference from source was
Makefiles and gtk3 keymaps), so the copy is a no-op; **the assertion is the
deliverable**, because VICE's `make install` has silently skipped ROM data files
before and the emulator's response is a segfault with no output at all (it bit
the C64 station and the VIC-20 station).

## The scene, and how a visitor drives it

The checkpoint is **the machine's own untouched power-on screen**:

```
*** commodore basic 128, v4.0 ***

ready.
█
```

green on black, 80 columns, nothing typed. That is the whole machine as sold
with no peripherals: no free-memory line, no menu, just BASIC. The visitor types
at the prompt through the UI's on-screen keyboard; `PRINT`, `BANK`, `LIST` and
the built-in machine-language monitor all work from cold.

This follows the lesson the `plus4` station paid for: **capture the state the machine
itself chose.** An earlier plus4 checkpoint rested inside an application and dropped
visitors into the middle of it; the affordances belong in the exhibit UI, around
an honest idle screen.

## Device set and launcher

Identical in shape to its kiosk siblings (`c64`, `vic20`, `plus4`, `apple2`,
`atarist`, `amiga`, `mpf2`) — see `streamhost/tiles/cbm2/qemu-streamhost.sh` —
with **768 MB** of guest RAM rather than the siblings' 1536 MB (measured: see
below). The kiosk launcher is:

```
xcbm2 -model 610 -sounddev alsa -pal
```

on an **800×600 X root**, with **no `-CRTCdsize`**.

### Why not doubled — the measurement

There is no window manager, so an SDL window larger than the X root is silently
**clipped**, and on this machine the clipping is invisible to the eye: the
emulated screen is black and so is the bare root. The geometry was therefore
measured on a recon clone with `xsetroot -solid magenta` under the window, so
the window's true rectangle could be read off the framebuffer:

| X root | flags | window | verdict |
|---|---|---|---|
| 1024×768 | (none) | 704×528 centred | fits, 69% × 69% |
| 1024×768 | `-CRTCdsize` | 1408×1056 | **clipped** — banner sliced at y=0, left edge lost |
| 1280×1024 | `-CRTCdsize` | 1408×1056 | **clipped** horizontally |
| 1920×1080 | `-CRTCdsize` | 1408×1056 centred | fits, 73% × 98% |
| **800×600** | **(none)** | **704×528 centred** | **fits, 88% × 88% — shipped** |

The doubled window needs a 1600×1200-or-larger root, i.e. four times the capture
area of every other kiosk (`c64`/`vic20`/`plus4` all run 800×600), to
enlarge glyphs that are 8 px wide only because the machine draws 80 columns.
Native on 800×600 gives the same 88% fill at a quarter of the encode cost.

As for every VICE station, **the kiosk profile must not redirect `startx`'s output
to a file**: VICE 3.9 segfaults in `vice_banner()` whenever stdout is not a
terminal and prints nothing at all — backtrace and symptom in
[`vic20.md`](vic20.md).

### Memory

`-m 768`, not the siblings' 1536. Asserted by the builder on every run
(`assert_guest_memory`, floor 200 MB): with `xcbm2` (RSS 148 MB) and Xorg
(RSS 70 MB) up, the guest reports **MemAvailable 415–426 MB**. Host-side the
running station's QEMU is **≈660 MB RSS** (the daemon's rss-guard arms at
anon 596 MB + 2048 MB). If a future change pushes MemAvailable under the floor
the build fails and says to raise `MEM` to 1024 and recapture.

## Keyboard pacing

`SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80` — **four** PAL frames each way.
Carried over from the VIC-20's bisect rather than re-measured: same emulator,
same 50 Hz frame, same host, and the failure those numbers guard against is a
host scheduling stall rather than a property of the emulated machine
(`scripts/dev/emu-key-pacing-bisect.py`: 40/40 corrupted one line in 22, 80/80
none in 22). **Two frames is a floor, not an answer.** Re-bisect if this station
ever drops characters.

No `SH_KEY_MAP`: VICE's symbolic keymap already maps host ASCII onto the CBM-II
matrix, and unlike the Plus/4 this machine needs no un-typeable key — the CBM-II
business keyboard has no Commodore key, RUN/STOP is `Esc`, and its numeric
keypad is ordinary digits.

## Verification (2026-08-09)

Evidence in `/data/vms/streamhost/tiles/cbm2/evidence/`:

| Artifact | Shows |
|---|---|
| `cold-boot-basic.png` | first boot of the fresh overlay reaching BASIC 128 after the ROM repair and the kiosk install |
| `ready-before-golden.png` | the untouched power-on screen — **the frame that was captured** |
| `golden-restored.png` | `loadvm golden` immediately after the capture |
| `keyboard-print3.png` | `PRINT 3` typed at 80/80 **after** the capture: BASIC echoes the line, prints ` 3`, paints a second `ready.` |
| `golden-restored-after-keyboard.png` | `loadvm golden` returning to the exact captured screen, the typing gone |
| `live-service-frame.png` | the frame the running `streamhost@cbm2` is serving |

The readiness predicate is **positional, not just bright**: `fb-probe.py` reports
the lit-green pixel count *and* its bounding box, and `wait_for_basic` requires
≥250 lit pixels with `minrow` in 60..140 and the box inside cols 40..760. That is
what catches a clipped window — with `-CRTCdsize` on 1024×768 the same banner
started at row 0, column 0, which a brightness-only test would have passed.

The keyboard proof asserts **growth of the lit bounding box** (rows 100..162 →
100..226), not "the framebuffer changed": measured on the clone, a pixel *count*
test is unfalsifiable here because the blinking cursor gives back what the new
lines add (456 → 454). A proof that cannot fail is not a proof.

## Cold boot and rollback

Zero input is genuine, and because the checkpoint is the power-on screen itself a
cold boot and a restore reach the same place. See
`scripts/coldboot/cbm2-zero-input-prep.md`.

To withdraw the station: `systemctl stop streamhost@cbm2`, set `enabled: false`,
regenerate, republish the three runtime documents (tiles.json, gallery-manifest.json AND golden-manifest.json — the third is the reset allow-list). To rebuild:
`scripts/build-guests/tiles/cbm2.sh --force`, which replaces `overlay.qcow2` and so
**destroys the checkpoint inside it**, then captures and re-proves a new one.

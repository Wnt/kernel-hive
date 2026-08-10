# bbcmicro — Acorn BBC Micro Model B (1981)

Status: **LIVE production streamhost tile** (bridge tile, `resetMode=loadvm`).

The machine the BBC Computer Literacy Project put in British schools, and act 1
of the ARM story: the Acorn team that built this designed the ARM1 next, and its
first silicon ran on a board plugged into a BBC Micro's Tube interface. A second
exhibit (`armeval`, not in this wave) shows that second processor on this same
MAME driver — see *The ARM angle* below for the division of labour.

## Identity and source

| | |
|---|---|
| Public ID / tile directory | `bbcmicro` |
| Slot / UDP | 129 / 54129 |
| VMID label / bridge SSH | 232 / `127.0.0.1:5832` (key `/data/vms/bridge/bridge_key`) |
| Emulator | MAME **0.289** driver `bbcb`, purpose-built subtarget |
| Guest | Debian 13 (trixie) X kiosk on a thin overlay of the trixie bridge base |
| Archetype | `beige-tower-crt` (fallback; no bespoke Acorn archetype exists) |
| Builder | `scripts/build-guests/tiles/bbcmicro.sh` (+ `build-mame-bbcb.sh`) |
| Credentials | none — the machine has no login (`guest/bbcmicro` is a placeholder) |

### The MAME binary, and why it is not the distro's

`scripts/build-guests/emulators/build-mame-bbcb.sh` builds tag **`mame0289`**
(`f34f02505e32c1993c6a782b6814232cbfc74e36` — the newest stable tag when this
tile was added, confirmed with `git ls-remote --tags`; the same release the mpf2
tile ships) inside the **trixie** chroot at
`/data/vms/soltest/trixie-chroot`, with `SUBTARGET=bbcb
SOURCES=src/mame/acorn`.

Migrated bookworm → trixie on 2026-08-10 (wave 2 of
[`../lab/BRIDGE-TRIXIE-MIGRATION.md`](../lab/BRIDGE-TRIXIE-MIGRATION.md)). The
chroot's job changed with it: guest and host are both Debian 13 now, so it is no
longer matching an ABI the host cannot produce, it is only keeping the build
reproducible and the pin honest.

Three reasons it is not simply apt's MAME:

- the lab host's own `/usr/games/mame` is 0.276, and the romset here is
  assembled against **this** binary's `-listxml`, not against whatever the
  distro froze;
- the bridge base's own `apt install mame` would be an unpinned suite freeze;
- MAME moves ROM requirements between versions, so a romset is only meaningful
  against **one** binary. The builder therefore asks the *shipped* binary
  (`bbcb -listxml bbcb`) which entries it wants and asserts the staged SHA-1s
  against that answer.

`SOURCES` is the **directory** `src/mame/acorn`, not `bbcb.cpp` alone: in 0.289
the driver is split across `bbcb.cpp`, `bbc_kbd.cpp`, `bbc_v.cpp` and `bbc_m.cpp`
behind a shared `bbc.h`, and the directory form also brings in the Tube
second-processor devices that `armeval` will need from the same binary.

The build carries `scripts/build-guests/patches/mame-irix-skip-warnings.patch` — see
*The warnings screen* below.

### ROMs — preservation-source, staged by the operator

**There is no authorised fetchable source for the Acorn MOS/BASIC dumps**, and
there is documented doubt that Acorn's successors hold clean assignment of the
original MOS work. The builder therefore **does not download anything**. It
requires five blobs staged at `/data/assets-staging/bbcmicro/` and gates each on
its SHA-1, then assembles the three MAME zips itself:

| staged file | SHA-1 | bytes | what it is | MAME set |
|---|---|---|---|---|
| `os12.rom` | `0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d` | 16 384 | MOS 1.20 (driver default BIOS `os12`) | `bbcb` |
| `basic2.rom` | `4a7393f3a45ea309f744441c16723e2ef447a281` | 16 384 | BBC BASIC II | `bbcb` |
| `phroma.bin` | `b369809275cb67dfd8a749265e91adb2d2558ae6` | 16 384 | TMS5220 speech PHROM | `bbcb` |
| `saa5050` | `6c8daba70374e5aa3a6402f24cdc5f8677d58a0f` | 960 | SAA5050 teletext character generator | `saa5050` |
| `dnfs120.rom` | `7e3c536baeae84d6498a14e8405319e01ee78232` | 16 384 | Acorn DNFS 1.20 | `bbc_acorn8271` |

Assemble **by SHA-1, never by filename** — MAME renames members and moves
parent/clone splits between versions. See `docs/lab/ASSETS-MANIFEST.md` for the
provenance row and `scripts/build-guests/check-assets.sh` for the gate.

Two traps paid for here on 2026-08-09:

- **`saa5050` is a third zip and is easy to miss.** It is not a member of
  `bbcb.zip` and belongs to no BIOS set — it is the character generator inside
  the Mullard teletext chip, shipped as its own 960-byte device romset. MODE 7,
  the mode the machine powers on in, has no glyphs without it, and MAME refuses
  to start: `saa5050 NOT FOUND (tried in saa5050 bbcb)`.
- **The disc interface is the dragon32 trap in reverse.** `mame bbcb` with no
  slot options fits the driver's default `fdc` slot, `acorn8271`, whose default
  BIOS is DNFS 1.20. Omitting `dnfs120.rom` does not silently give a
  cassette-only Model B; MAME refuses the missing device ROM. This tile ships
  MAME's own defaults, so the banner carries the `Acorn DFS` line a
  disc-equipped Model B printed — and that is also the configuration `armeval`
  runs under.

`-verifyroms` is **not** used as a gate: on a BIOS-selectable computer driver it
reports "bad" purely because the alternative BIOS entries (OS 1.00 / 0.92 / 0.10,
BASIC I, eight Watford/Acorn DFS variants) are absent, which is the point of a
pinned set.

## Device set

Identical in the builder and in `streamhost/tiles/bbcmicro/qemu-streamhost.sh`
(the launcher is the guest-visible ledger; changing it invalidates the golden):

```
qemu-system-x86_64 -name streamhost-bbcmicro
  -enable-kvm -machine pc-i440fx-11.0,vmport=off -m 768 -smp 2 -cpu host
  -rtc base=localtime
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c
  -vga std
  -display dbus,p2p=on,audiodev=snd0
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16
  -device AC97,audiodev=snd0
  -usb
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5832-:22 -device e1000,netdev=n0
  -qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid
```

**768 MB, not the 1536 the VICE bridge tiles use.** Measured in-guest at the
fixture with X and MAME up: `MemAvailable` 570 MB, MAME RSS 116 MB, host QEMU
RSS 1.06 GB. The builder asserts a 200 MB `MemAvailable` floor, so a future
MAME that needs more fails the build rather than the exhibit.

### The emulator window and the captured root

```
bbcb -rompath /opt/bbcmicro/roms -inipath /opt/bbcmicro
     -skip_gameinfo -artwork_crop -video soft -prescale 2
     -keepaspect -nowindow -nofilter
```

MAME runs fullscreen on the bridge base's **stock 1024×768** X root (unlike the
VICE tiles, whose fixed SDL window forces the root down to 800×600). The BBC's
MODE 7 raster is 480×500 — 40×25 teletext cells of 12×20 pixels — which is the
pixel count, not the picture's shape; `-keepaspect` reconstructs the 4:3 image
the machine drew on a television or a Microvitec Cub.

`-artwork_crop` is load-bearing. The driver ships an internal layout with the
Model B's three keyboard LEDs (cassette motor, caps lock, shift lock) drawn as a
labelled strip *under* the screen; uncropped the composite view is 480×549 and
the exhibit is a picture with a row of emulator chrome beneath it. The
caps-lock LED it removes was worth seeing once, though — it is **lit at
power-on**, which is why the demo listing is typed in lower case.

### The warnings screen

`bbcb` is driver status `imperfect` (emulation good, sound imperfect), so MAME
raises a startup **warnings** stage. That stage is separate from the game-info
screen and `-skip_gameinfo` does **not** suppress it. It is not the full-screen
red "THIS SYSTEM DOESN'T WORK" panel — that one is reserved for `preliminary`
drivers — but it would still be the first thing every visitor saw. The shipped
binary carries the one-line patch the IRIX/MPF-II builds already use so the
existing `skip_warnings` UI option gates that stage, and `/opt/bbcmicro/ui.ini`
sets it. The builder's readiness predicate **rejects a red-dominant frame**, so
a binary rebuilt without the patch fails the build instead of shipping.

## Golden fixture

`resetMode: loadvm`, internal qcow2 snapshot `golden`, no post-restore keys.

The fixture is **the machine's own untouched power-on screen** — white teletext
on black, MODE 7:

```
BBC Computer 32K

Acorn DFS

BASIC

>
```

Nothing is typed into it and nothing is curated. That is the Plus/4 lesson
applied before it could be repeated: a golden baked inside an application drops
a visitor into the middle of something with no idea what it is or how to leave.
Here the machine's own first screen is also the invitation — a blinking prompt
on a machine whose entire purpose was that you programmed it.

## Keyboard

The exhibit's only input surface. No pointing device: the Model B had none, and
`stream.pointer.transport` is `none`.

### Layout — a BBC is not a PC

Derived from the driver's own `PORT_CHAR` table (`src/mame/acorn/bbc_kbd.cpp`,
the `bbc_keyboard` port) with `scripts/dev/mame-keymap.py`, not guessed.
Thirteen characters sit on different keys from a US PC; the map is declared once
in `registry/tiles/bbcmicro.json` (`keyboard.charMap`, mirrored to `SH_KEY_MAP`
for labctl) and used by the SPA typist and by the builder's proof:

| BBC character | send this US key |
|---|---|
| `"` | `@` (BBC: Shift+2) |
| `'` | `&` (Shift+7) |
| `&` | `^` (Shift+6) |
| `(` `)` | `*` `(` (Shift+8/9) |
| `=` | `_` (Shift+`-`) |
| `@` | `\` |
| `+` | `:` (Shift+`;`) |
| `^` `~` | `=` `+` |
| `_` | `` ` `` |
| `:` `*` | `'` `"` |

Untranslated, `=` and every bracket land one key over and a BASIC listing is
quietly corrupt — the symptom reads exactly like dropped keystrokes.

**The MOS enables CAPS LOCK at reset**, so unshifted letters arrive upper case,
which is what BBC BASIC's tokeniser requires. The registry demo listing is
therefore written in lower case (as vic20's and mpf2's are) and the machine does
the shifting. Sending real upper case with caps lock on would produce lower case
and `Mistake`.

### Pacing

`SH_KEY_MIN_HOLD_MS=80`, `SH_KEY_MIN_GAP_MS=80`; `demoProgram.perCharMs=170`
(the SPA typist's per-character budget must not undercut hold+gap, enforced by
`validate_demo_pacing`).

Derivation and measurement: the BBC is a 50 Hz machine, so the frame period is
20 ms and playbook §5.1's two-frame floor is 40/40. Two frames is a floor, not
an answer — the vic20 shipped at its derived 40/40 and still lost characters to
host scheduling stalls. Bisected here on a namespaced clone with
`scripts/dev/emu-key-pacing-bisect.py` (see the campaign note in the guest doc
history below), and shipped at 80/80, the same margin as the other bridge tiles
on this box.

**This tile must run the pacing canary binary.** The shared fleet streamhost
binary does not implement `SH_KEY_MIN_HOLD_MS`; `/usr/local/lib/streamhost/tiles/bbcmicro/{current,previous}`
point at the same build vic20/plus4/c128 use
(`streamhost-bca88a2bed22e1ea616993995faf4379b954bb11`).

### The type-in demo

`registry/tiles/bbcmicro.json` → `demoProgram`, a five-line MODE 1 line fan:

```basic
10 mode 1
20 for i=0 to 1279 step 16
30 gcol 0,1+i mod 3
40 move 640,512:draw i,1023
50 next
```

BBC BASIC is the point of the machine, and this listing exercises the three
translations that matter (`=`, `+`, `:`) as well as the graphics the Model B was
bought for. The builder types exactly this listing after the bake, runs it, and
asserts the lit-pixel count — a listing full of `Mistake` errors would leave the
screen a teletext banner and fail.

## The ARM angle

The Acorn team that built this machine designed the ARM1 next, and the first
ARM silicon ran on 26 April 1985 — first time, correctly. The ammeter wired in
series with its supply read **zero**: the board had a fault and never connected
the chip's power pins, so the processor was running on leakage through its I/O
pins alone. That is the origin of ARM's power story, and it is a BBC Micro
anecdote: the evaluation board plugged into this machine's Tube interface.

A separate exhibit, **`armeval`** (not in this wave), shows the ARM Evaluation
System on this same driver via `bbcb -tube arm`. The two are visibly different
and deliberately so: plain reads `BBC Computer 32K` with a white `>`; with the
ARM second processor it reads `ARM Second Processor 4096K` and the prompt is a
blue `A*`. This tile's placard sets that exhibit up and does not duplicate it.

## Cold boot and reset

- Zero input: genuine. A cold boot reaches the same banner the golden holds —
  see `scripts/coldboot/bbcmicro-zero-input-prep.md` and the `bbcmicro)` arm in
  `scripts/coldboot/bootrec-tiles.conf`. No clip is published.
- Reset: `POST /restore/bbcmicro` → `loadvm golden`. The tile must appear in the
  live `golden-manifest.json` or that endpoint returns `404 unknown osId` while
  the tile streams perfectly.

## Rollback

Keep the launcher and the golden as an atomic pair. To roll back, restore the
previous `overlay.qcow2` (the snapshot lives inside it) and the previous
`qemu-streamhost.sh` together; a device-set change alone makes `-loadvm golden`
fail. Re-baking after any launcher or X-geometry change is mandatory — otherwise
reset restores the old layout and the fix appears not to have worked.

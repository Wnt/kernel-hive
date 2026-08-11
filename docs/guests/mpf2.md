# Multitech Microprofessor II (MPF-II, 1982) — BASIC gallery station notes (:8120)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **MAME `mpf2`**
fullscreen, emulating a **Multitech Microprofessor II (1982)** that boots
**Applesoft-clone BASIC** to a 560×192 @ ~60 Hz composite display with 6-colour
artifact palette (black, white, blue, orange, purple, yellow) at 2× integer
scale (1120×384). This is a **kiosk** — streamhost captures the
Linux framebuffer exactly like every other station. See **`streamhost/docs/BRIDGE.md`**
for the bridge pattern and **`docs/guests/amstradcpc.md`** for the CPC reference
recipe this station forks.

**The Machine:** Taiwan's first mass-market home computer (1982), a landmark upon
which **Acer was built**. The MPF-II is a 6502-based **Apple II ish-clone** with an
incompatible memory map (hires pages at $2000/$A000, not $2000/$4000) and a
deliberate **keyboard matrix at $C000/$C010** that is NOT the Apple II interface.
Apple II emulators will not run it; `MAME mpf2` (clone of `tk2000`) is the only
option.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` (read-only backing; built by
`scripts/build-guests/lib/bridge-base.sh`). The MPF-II builder installs the pinned
MAME 0.289 binary into its own thin overlay; the frozen shared base remains
unchanged.

**Build scripts:** `scripts/build-guests/emulators/build-mame-mpf2.sh` reproducibly builds
the narrow MAME 0.289 `tk2000.cpp` subtarget in the Bookworm lab build chroot,
then
`scripts/build-guests/tiles/mpf2.sh` creates the thin overlay, kiosk `launch.sh`,
framebuffer checks, keyboard proof, and checkpoint cold-restore.

**Station dir (host):** `/data/vms/streamhost/tiles/mpf2/` — `overlay.qcow2`
(thin, on the base; holds the INTERNAL `golden` snapshot), `qemu-streamhost.sh`,
`tile.env`.

## License / provenance
- **MAME `mpf2`** — emulation driver in `src/mame/apple/tk2000.cpp`, GPLv2 licensed.
  Driver added in MAME 0.218 (February 2020), still present in 0.289. Runs a
  1 MHz 6502 — trivial CPU load.
- **MPF-II ROM** (`mpf_ii.rom`, 16 KB, CRC32 8780189f, SHA1
  92378b0db561632b58a9b36a85f8fb00796198bb) — Monitor + Applesoft-clone BASIC in
  one blob. **No CHARGEN ROM** and none is needed — the MPF-II has no hardware text
  generator; ROM code software-paints glyphs into the hires bitmap (which is also
  why scrolling crawls on real hardware).

## Sourcing the ROM
Because `mpf2` is a *clone* of `tk2000`, in a **merged** MAME ROM set, the file
lives inside **`tk2000.zip`**, not `mpf2.zip`. In a split/non-merged set, you want
`mpf2.zip`. This is the #1 cause of "ROM not found" errors.

Candidate merged sets (MAME >= 0.218):
- <https://archive.org/details/MAME_0.224_ROMs_merged>
- <https://archive.org/details/mame-0.239-roms-merged>
- <https://archive.org/details/MAME_0.232_ROMs_Merged>

Verify with: `mame -verifyroms mpf2`

Stage per house convention: immutable intake copy at
`/data/assets-staging/mpf2/`, `MANIFEST.sha256` record, provenance in
`docs/lab/ASSETS-MANIFEST.md` and `docs/catalog/os-media-catalog.md`, extend
`scripts/build-guests/check-assets.sh`. Bits never committed — URL + hash only.

## Display constraints (shape the station)

1. **560×192 @ ~60.05 Hz**, a 2.92:1 aspect ratio, composite-artifact colour
   (6 colours: black, white, blue, orange, purple, yellow). **Integer scale only**
   (2× → 1120×384, 3× → 1680×576) and letterbox. Non-integer scaling destroys the
   artifact fringing that *is* the machine's look.

2. **No pointing device** — 8×8 matrix, 48 chiclet keys, uppercase only. No game
   port, no paddles, no mouse. Joystick support on real hardware was simulated
   through the key matrix. The fleet's 1:1 absolute-pointer requirement has
   nothing to drive here: `pointer_mode` must be **none/disabled**; **keyboard is
   the entire input surface**.

3. **Software scope** — no disk controller ROM and no MAME A2BUS slot configured.
   The exhibit **boots to BASIC and you type**; that is accepted and is the whole
   exhibit. There is no TOSEC / No-Intro software list for the MPF-II, no `mame`
   software list for `mpf2`, and `apple2_cass.xml` is not a substitute (incompatible
   memory map).

## Curated metadata (for the UI placard)
- **Year:** **1982**.
- **Lineage:** Multitech (Taiwan) — the MPF-II was the homeland's first mass-market
  home computer and the machine upon which **Acer was founded**. A 6502-based
  **Apple II ish-clone** with incompatible memory map and keyboard matrix.
  Boots to **Applesoft-clone BASIC** on a composite 560×192 display.
- **One line:** *"Taiwan's first mass-market home computer — an Apple II
  ish-clone that boots Applesoft-clone BASIC on a composite 560×192 display with
  6-colour artifact palette."*
- **Iconic era software:** Applesoft-clone BASIC (bundled ROM).
- **Current archetype:** **beige-tower-crt** fallback; the ideal follow-up is a
  bespoke MPF-II unit with composite monitor.

## Input — keyboard exhibit (NO pointer)
The MPF-II is **keyboard/matrix-driven with no pointing device**. The device set
mirrors the Amstrad CPC keyboard sibling: `-machine pc-i440fx-11.0,vmport=off`,
no `usb-tablet`, `SH_INPUT_BACKEND=disabled`. The UI still emits pointer
coordinates; streamhost discards pointer, button, wheel, and touch records while
continuing to inject keyboard events into the matrix.

## Ports (assigned)
- streamhost UDP (WebTransport): **54124** (slot 124).
- ssh hostfwd (host→guest :22, for `labctl exec`): **127.0.0.1:5820** (guest user
  `root`, key `/data/vms/bridge/bridge_key`).
- UI web port (reserved): **8120**. VMID **220**.

## Proven raw QEMU profile (the station device set — MUST match the checkpoint capture)
```
qemu-system-x86_64 -name streamhost-mpf2 -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=overlay.qcow2,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5820-:22 -device e1000,netdev=n0 \
  -qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid
```

## Kiosk / MAME mpf2 launch
The MPF-II ROM has no disk controller; cassette and Centronics printer only.
MAME's `tk2000` machine config has **no A2BUS slot**, so optional disk/modem
devices are not emulated.

Verified launch command (patched MAME 0.289, soft framebuffer video, 2× prescale
before the fullscreen fit):
```
exec /opt/mpf2/mame/mpf2 mpf2 \
  -rompath /opt/mpf2/roms \
  -inipath /opt/mpf2 \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
```

MAME runs FULLSCREEN on the bridge seed's stock 1024×768 X root (`~/.xinitrc`,
same as every sibling kiosk), with its normal aspect correction on, so the
picture fills the captured framebuffer. Forcing `-resolution 1120x384` instead —
the raw composite pixel count with aspect correction defeated — pinned a 2.92:1
strip in the middle of a large black root: that number is the machine's PIXEL
count, not its picture's shape. The real machine drew a roughly 4:3 image on a
television, which is what `-keepaspect` reconstructs.

## Keyboard mapping
The browser and streamhost send explicit XT key-down/key-up events to QEMU's
default PS/2 keyboard. MAME maps those physical keys to the 6502 memory-mapped
matrix at $C000/$C010. Uppercase letters and symbols follow standard ASCII.

Two registry-declared streamhost keyboard knobs make that surface usable
(`registry/tiles/mpf2.json` → `runtime.stationEnv`; both also cover the UI's
on-screen keyboard, since it shares the same wire record):

- **`SH_KEY_REMAP=0x0e:0xe04b`** — Backspace is delivered as LEFT ARROW. The
  machine has **no Backspace key at all**: MAME's `src/mame/apple/tk2000.cpp`,
  which the `mpf2` driver clones, declares only `KEYCODE_LEFT` and
  `KEYCODE_RIGHT` of the whole edit cluster in its `ROW*` matrix ports. As on
  the Apple II it clones, the left arrow *is* the rubout key.
- **`SH_KEY_MIN_HOLD_MS=32`** and **`SH_KEY_MIN_GAP_MS=32`** — MAME samples its
  input ports once per emulated frame (~16.7 ms at 60 Hz), so anything completing
  inside one frame is never observed. The hold makes each key visible for long
  enough; the gap makes the SPACE between two keys visible, which is what
  sustained typing actually loses. Bisected here on a 16-key line: gap 0 ms → 0
  of 16 keys land, 8 ms → 4, 12 ms → 12, 16 ms (one frame) → 16. Both ship at
  32 ms = 2 frames of margin. While the knobs are on, key events serialize, so
  typing faster than the pace queues rather than drops and two keys can never
  interleave into a stuck-key state.

The MPF-II's 8×8 matrix is also not laid out like a PC's: `=` is Shift+O, `-` is
Shift+I, `+` is Shift+P, and the shifted number row is offset by one (Shift+8/9/0
give `( ) *`). Untranslated, `=` and `-` vanish — those PC keys have no matrix
position — and brackets land one key over. The registry entry's
`spa.demoProgram.keyMap` translates them; the pairings come from the `PORT_CHAR`
declarations in `src/mame/apple/tk2000.cpp`.
The certified proof types `PTRON` (a valid BASIC function returning TRUE/-1),
presses Return, and visibly renders the result in the MPF-II framebuffer.

## Build status (2026-08-06)
- Registered disabled candidate: VMID 220, UDP 54124, slot 124; SSH 5820 and
  web-port reservation 8120. Promote it only after the builder completes its
  framebuffer, keyboard, and cold-restore proofs.
- The build is intentionally gated on the locally staged, hash-verified ROM:
  `/data/assets-staging/mpf2/mpf_ii.rom`, and requires the host-produced
  `/data/vms/streamhost/assets/mpf2/mame/mpf2` binary. The builder installs that
  binary in the thin overlay, verifies `mpf2 -verifyroms mpf2`, captures the
  BASIC prompt, proves keyboard input, and proves reset. UI reset is the sibling
  pattern — `SH_RESET_MODE=loadvm` restoring the INTERNAL `golden` snapshot in
  `overlay.qcow2`, captured from a clean cold boot and with no post-restore key
  injection (driving a MAME soft reset to replay the power-on beep raced the
  restore and left the screen scrolled with two prompts stacked).
- Pointer acceptance is N/A: `SH_INPUT_BACKEND=disabled` preserves keyboard
  injection while discarding all pointer-class input.

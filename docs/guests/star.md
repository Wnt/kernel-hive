# Xerox Star 8010 "Dandelion" / Pilot + ViewPoint 2.0 — gallery tile notes (udp/54138)

Tile id `star`, slot 138, UDP 54138, VMID 240, kiosk ssh `127.0.0.1:5840`.
Builder: [`scripts/build-guests/tiles/star.sh`](../../scripts/build-guests/tiles/star.sh).
Registry source: `registry/tiles/star.json`.

**Emulator-in-captured-Linux bridge tile**, the same shape as `amiga`, `c64` and
its sibling `daybreak`: a thin qcow2 overlay on `/data/vms/bridge/bridge-base.qcow2`
whose `/etc/bridge/launch.sh` runs Darkstar under mono on a bare X root with no
window manager. streamhost captures the Linux framebuffer exactly like every
other tile.

This is **not** a duplicate of `daybreak`. That tile is the 1985 Xerox 6085
under Dwarf/Draco (Java), from the Dwarf project's own disk. This is the 1981
8010 itself — the machine that introduced the desktop — under a different
emulator, from bitsavers media, with a different processor, a different display
size, a different keyboard idiom and a different pointer model.

## Media and licence

| file | sha256 | size | class |
|---|---|---|---|
| `8010_hd_images.zip` (bitsavers) | `d9fb11362229ba7b9dbb7500f2240f9c1e9cdaa9f37bb4431221174483ca438e` | 14 020 559 | preservation-source |
| `ViewPoint-2.0-11-9-1990-18-38.img` (from the pack) | `a7ead97a18d748debd769e5d2358f05ece24f10a5421e9fbc73b598e4a7f7020` | 65 433 601 | preservation-source |
| Darkstar `livingcomputermuseum/Darkstar` @ `7ab55ff3` | — | — | BSD-2-Clause code, Xerox-copyright ROM/microcode inside it |

Xerox never released ViewPoint or Pilot and there is no licence grant, so the
posture is the usual one: **URL + measured sha256 + size + class in
`docs/lab/ASSETS-MANIFEST.md`, never the bits.** The repo is public; the gallery
is passkey-private and streams pixels only, with no download affordance. The
BSD-2 licence on Josh Dersch's emulator does not launder the Dandelion IOP PROM
dumps (`537P030xx.bin`) and CP microcode the same repo ships — those are
preservation material on exactly the same footing as the disk image.

The pack also contains `XDE-5.0.img` and `Interlisp-D-Harmony.img`. Both boot on
this emulator and neither is wired up; they are the obvious second and third
exhibits if the Star ever earns more than one slot.

## Building Darkstar on Debian — three fixes, not two

Darkstar is **.NET Framework 4.5, WinForms, with an SDL2 surface embedded via
`SDL_CreateWindowFrom`**. Mono's WinForms X11 driver is therefore a hard
dependency and `dotnet`/CoreCLR is not an option. Debian bookworm's
**mono 6.8.0.105** builds and runs it fine (the study asked for 6.12; it is not
needed):

```
apt-get install mono-complete mono-xbuild nuget libgdiplus libsdl2-2.0-0
nuget restore D.sln && xbuild /p:Configuration=Release D.sln
```

— 0 errors, seconds, at the pinned commit. Then:

1. **delete the bundled Windows `SDL2.dll`**, or SDL2-CS binds to it and dies;
2. **add `SDL2-CS.dll.config`** with `<dllmap dll="SDL2.dll" target="libSDL2-2.0.so.0"/>`;
3. **start it from `D/bin/Release`.** Darkstar resolves its PROM and microcode
   paths *relative to the CWD* (`Path.Combine("IOP","PROM",name)`), so from any
   other directory it dies with `FileNotFoundException: /IOP/PROM/537P03029.bin`.
   And **`-rompath` is not a tree root** — it replaces the whole `IOP/PROM`
   prefix, so `-rompath .` makes it look for `./537P03029.bin`. Do not pass it.

## The time lock — the number-one boot gotcha

The Xerox software is time-locked ("Product Factoring"). With a 1990 TOD the
boot **stalls at MP 7800 indefinitely** — measured at over 12 minutes, twice.
`star.cfg` pins `TODSetMode = SpecificDateAndTime` / `TODDateTime = 1997/12/01`,
which is the date the emulator's published perpetual option keys are cut for
(ViewPoint 2.0 / Services 11.0: `8 7T78 M8YL LFEQ`). **Do not change it.**
`AltBootMode = Rigid` skips the long power-on memory diagnostic.

## MP codes are not a progress bar

Boot progress is a four-digit **MP (Maintenance Panel) code** — on a real Star, a
front-panel LED. It walks `0910 → 7600 → 7700 → 7800 → 8000`, and each step takes
minutes. Two traps, both of which have cost this project hours:

- **MP 7600 sits for several minutes on a blank white page with zero disk I/O.**
  That is the exact symptom of upstream issue #22 ("Darkstar stuck booting
  ViewPoint on Linux"), and it is not a hang. "No disk I/O" proves nothing here:
  the 65 MB image is fully page-cached after the first pass, so a *healthy* boot
  also shows zero reads.
- **MP 8000 is the RUN state, not a completion signal.** It is reached before the
  Set Time Utility even appears, and the logged-off bouncing-keyboard screen sits
  at 8000 too. Distinguish the three states before diagnosing: a wrong TOD
  wedges, low speed crawls, and a logged-off desktop is just waiting for NEXT.

**Reading the MP code from this tile takes one extra step**, because the status
bar is deliberately off-screen (see Display). `/root/starmp.sh` on the box slides
the window up 26 px, grabs the framebuffer and slides it straight back.

## Display — the captured frame is the Star screen and nothing else

The Star's display is **1024×808 visible inside a 1088×860 DisplayBox**, one bit
per pixel, landscape ≈1.26:1 — squarer than 4:3, so the SPA pillarboxes slightly.
None of the Alto's portrait problem.

Measured window geometry under mono, with no WM: the WinForms top level is
**1091×915**, containing a **1091×30 System Menu**, the **1088×860 DisplayBox**,
and a **1088×23 System Status** bar.

The kiosk therefore builds a **custom 1088×860 X mode** — exactly the DisplayBox
— and `launch.sh` moves the window to **(0, −29)**, so the System Menu sits above
the root and the status bar below it. What streamhost captures is the Star screen
edge to edge, with no emulator chrome and no grey gutter. X also runs with
**`-nocursor`**: Darkstar paints the Star's own cursor into its framebuffer, and
the X core pointer would be a second, wrong arrow sitting in the captured frame.

A side effect worth knowing: the off-screen System Menu is also where
`System → Exit` lives, so a visitor cannot quit the emulator.

## Input

### The pointer is RELATIVE, and that is the correct answer

**Darkstar has no absolute pointer path at all.** `DWindow-IO.cs` computes
`dx = x − DisplayBox.Width/2`, feeds `IOP.Mouse.MouseMove(dx, dy)`, then
`SDL_WarpMouseInWindow`s the host pointer back to the centre under
`SDL_SetWindowGrab`. Feeding it absolute coordinates makes every sample a delta
from the centre and the Star cursor runs away.

That is not a blocker and it does not need a patched emulator: it is exactly what
the gallery's **relative** pointer path is for. Six tiles already ship it
(`qnx`, `nt351`, `amstradcpc`, `c64`, `freedos`, `msdoswin1`). The chain here is:

```
browser absolute sample
  -> streamhost SH_POINTER=rel (dbus-rel): calibrate, difference against the
     previous target, corner-pin home on the first sample, chunk to <=256 px
     per axis, pace 16 ms  [input.rs rel_motion_bounded]
  -> QEMU PS/2 mouse (NO usb-tablet, machine vmport=off)
  -> Linux generic PS/2 mouse -> X (acceleration OFF via xorg.conf.d, below)
  -> SDL relative motion -> Darkstar dx/dy -> the Star cursor
```

Three things make it work, and all three are load-bearing:

- **No `usb-tablet`, and `vmport=off`.** With either present QEMU's absolute /
  VMware-mouse handler absorbs the REL events before the guest's PS/2 driver sees
  them. This is the `c64` lesson (`docs/guests/c64.md`) applied unchanged.
- **X pointer acceleration off — and `xset m` is NOT how you do that.** Under
  libinput the core pointer control cheerfully reports `acceleration: 1/1
  threshold: 0` while the DEVICE goes on applying its own adaptive profile. The
  real switch is the `AccelProfile "flat"` InputClass the builder installs at
  `/etc/X11/xorg.conf.d/20-star-pointer.conf`. Measured before it existed: about
  **1.8x** on medium moves, so the Star cursor overshot every target. This cost
  a full round of pointer measurements — `xset q` said the right thing the whole
  time.
- **The 256 px chunking already in the daemon is what this machine needs.** The
  Star drops large single deltas — a 985 px jump applied only ~127 px, while
  50 px steps at 120 ms apply 1:1 — and `rel_motion_bounded` is exactly a bounded,
  paced walk. No new mechanism was invented and none was needed.

The tile therefore declares `stream.pointer.absolute = false` honestly and earns
the derived **`Rel. pointer`** grid badge, which is what that badge is for.

### What the pointer actually does, measured end to end

Driven through the deployed SPA in a real browser (`tests/e2e-live/star-rel-probe.mjs`),
with the Star cursor located in the QMP framebuffer at each dwell:

| commanded delta | applied to the Star cursor |
|---|---|
| −336, +230 | **−336, +230** — exact |
| +680, −500 | +663, clamped at the top edge (97.5 % in x) |
| −344, +270 | clamped at the left edge, **+269** in y |

**Gain is 1:1.** That is the number that decides whether this exhibit is usable
and it is as good as it can be.

**The ORIGIN is the honest caveat, and it is the shipped behaviour of the
relative path rather than anything Star-specific.** Two things move it:

- *Session seed.* The daemon pins the guest cursor into the top-left corner on
  the first sample of a session and dead-reckons from there. The seeding sample
  itself carries no motion, so the pointer's true origin is established one
  sample later — invisible when a hand is moving, total when a test harness
  teleports the pointer in a single event and then sits still.
- *Edge clamping.* The `dbus-rel` bridge has no edge self-correction (that is
  `ptr_reckon`, which only the `x11test`/`mamecmd` sinks use). Push the pointer
  past a screen edge and the guest stops while the model keeps going, so the two
  drift apart by the overshoot and stay drifted. Measured: after deliberately
  clamping in both axes, an offset of about (−185, −170).

**The recovery is a real gesture and worth knowing:** drag into the **top-left
corner**. Both ends clamp there, and the offset goes to zero. A `loadvm golden`
reset also re-parks the Star cursor in that corner, which is why the golden is
baked with it there rather than somewhere prettier.

Two daemon fixes landed while measuring this, both of which make the seed more
robust for every relative tile: the homing pin is now bounded to 2048 counts per
axis (8192 is ~65 PS/2 packets and takes most of a second to drain, and anything
sent during the drain merges into it), and the seeding sample now sends the pin
and nothing else, so the pin and the first walk cannot race through the queue.

### Darkstar has to be told to take the mouse — once, at bake time

Darkstar does not track the pointer until **the display has been clicked once**
("Click on the display to capture mouse/keyboard" in its status bar); that click
turns on the SDL grab. `launch.sh` performs it with real dwell a few seconds
after the window appears, so the capture is armed **inside the golden** and no
visitor spends their first click buying it.

The other half of the same switch: **either Alt key RELEASES the capture.** A
visitor pressing Alt on a physical keyboard would silently kill the pointer until
they clicked again, so the tile remaps both Alt scancodes to an inert key
(`SH_KEY_REMAP`, see `tile.env.fixture`). The SPA's `xerox-star` on-screen
keyboard has no Alt button.

### X autorepeat must be off

Darkstar wants a ~300 ms key hold, X repeats a held key after 660 ms, and Pilot
does its own repeat on top. Leave autorepeat on and a deliberate hold enters the
character several times — `launch.sh` runs `xset -r`.

### Keys want DWELL — and so does the modifier

A ~12 ms XTEST-shaped press lands **nothing** in Pilot: four presses across four
candidate focus windows produced one advance, which reads as flaky focus and is
not. A **300 ms hold lands every time**. The daemon's ceiling is 250 ms
(`SH_KEY_MIN_HOLD_MS` is clamped there) and that is enough through the QEMU PS/2
path.

Keys must reach the **WinForms top-level window**. The SDL child window lands
nothing — Darkstar handles keys on the form, not on the SDL surface — so
`launch.sh` sets the X input focus explicitly, because with no WM nothing else
will.

**The modifier is a key and needs its own dwell.** Sent in one batch, `Shift`+`;`
produces `;` while `Shift`+`a` still produces `A` — a partially applied shift that
looks exactly like a keymap gap. Led by its own event and held across the key it
produces `:`. Measured on this emulator: a **200 ms lead fails, 350 ms works**.
Since the daemon caps the gap at 250 ms, the reliable path for shifted
punctuation is the SPA's **shift latch**, which holds Shift down across a
human-timed pause; machine-speed typing of shifted symbols is not reliable here.

**And it is genuinely flaky rather than simply slow.** Building the exhibit's
own user account needed an XNS three-part name, so the colon was on the critical
path, and the same `Shift`+`;` sent the same way produced `:` sometimes and `;`
other times — through XTEST inside the guest AND through QMP scancodes, at leads
from 200 ms to 700 ms. A run of fifteen shifted characters typed back to back
came out perfectly (`A : " < > ? _ + { } | * ( )`); the same chord embedded in a
word did not. Two things that *do* work, and are worth reaching for before
another timing sweep:

- **Verify the glyph, do not trust the timing.** In this bitmap font a colon and
  a semicolon are one descender pixel apart. The cheap discriminator is that
  `user:star:xerox2` contains no descender letters at all, so *any* ink below the
  baseline in that field is a failed shift. `/root/cell.py` on the box prints the
  cell as ASCII art.
- **Remapping the X keymap does NOT work.** `xmodmap -e 'keycode 47 = colon
  colon'` makes the bare key produce nothing at all in the guest: Darkstar's own
  table is keyed on the layout it expects, and an unexpected keysym is simply
  dead.
(Dwarf, on the 6085, needs only that the modifier not ride the same event —
150 ms is plenty there. Carry the *rule* between these machines, never the
number.)

### The Xerox Level-V keys

ViewPoint runs on Xerox Level-V verbs — NEXT, OPEN, PROPERTIES, MOVE, COPY, SAME,
AGAIN, FIND, UNDO, HELP, STOP, DELETE, SKIP, DEFAULTS, EXPAND. **`Tab` is not
NEXT**, and the logon sheet cannot be completed without NEXT.

On the Star these are **plain PC keys**, not Daybreak's `Ctrl+letter` layer
(Darkstar README §3.2): `Again F1, Delete F2, Find F3, Copy F4, Same F5, Move F6,
Open F7, Props F8, Defaults NumLock, Skip/Next Home, Undo PgUp, Defn/Expand End,
Stop PgDn, Help Up`. The SPA family `xerox-star` in
`spa/src/ui/keyboard/keyboardProfiles.ts` is built from the shared `LEVEL_V_META`
table with a Star-specific binding, so the two Xerox tiles share one definition of
what the verbs *are* and differ only in what they emit. The Star's rows are longer
than Daybreak's because SKIP, DEFAULTS and EXPAND exist here.

Note that on the Star **SKIP and NEXT are one key** (Darkstar's table reads
"Skip/Next Home"), so the profile carries only NEXT.

### Driving the guest by hand

`/usr/local/bin/stardrv` is baked into the kiosk overlay and carries all of the
above timing:

```
labctl exec star "su bridge -c '/usr/local/bin/stardrv key Home'"
stardrv key <key>...     press / hold / release / gap, on the top-level window
stardrv shift <key>      one shifted key, modifier led and held
stardrv rel <dx> <dy>    walk the pointer in <=50 px steps around the centre
stardrv click [dx dy]    optional walk, then a 400 ms button-1 dwell
stardrv adjust           a 400 ms button-3 (ADJUST) dwell
```

`labctl exec star` reaches the **Debian kiosk**, not the Star. There is no shell
inside the emulated machine and no network behind it.

## Cold-boot route (framebuffer-verified)

The golden erases all of this; it is recorded so it can be reproduced.

| step | what you see |
|---|---|
| ~1 min | the **Set Time Utility 2.0** banner, after MP walks `0910 → 7600` |
| five CRs | time-zone offset `-8`, minute offset `0`, first DST day `98`, last DST day `305`, `change the time? N` → `Starting ViewPoint......` |
| MP `7600 → 7700 → 7800` | several minutes each; 7600 is a blank white page |
| MP 8000 | the **logged-off bouncing-keyboard** screen |
| `Home` (= NEXT) | the **Workstation Administration** desktop — grey stipple, a `Free Disk Pages` header, one window offering Desktop Creation / Deletion / Changes. There is no Logon Option Sheet at first: with no XNS Clearinghouse this image wakes straight onto a logged-on administrator's console |
| Desktop Creation | expands into `Name` / `Password` / `Administrator`. The little menu button beside `Name` is spring-loaded and offers the template `user:star:xerox` — which **already exists** on the shipped image, so edit it to something else. The caret in this field always sits at the end: clicking mid-string does not move it, so append rather than insert |
| `Start` | the machine **logs itself out** without asking |
| `Home` again | now the real **Logon Option Sheet** — Xerox 1981-1988 copyright, Name / Password / Default Domain / Default Organization |
| Start | the **ViewPoint user desktop**: grey stipple, the `Free Disk Pages` header with a Help button, and the **Directory** icon bottom-right |

Two hazards in that sequence: `Start` needs the pointer *precisely* on the
button — a 57 px miss silently does nothing, with no hover feedback to warn you —
and the machine logs out at the Desktop Creation step without asking.

## The fixture

The golden is baked at the **iconic ViewPoint user desktop**, not at the
Workstation Administration console it first wakes into. That is the famous Star
screen, and the 30-second interaction works from it: select the **Directory**
icon, press **OPEN** (F7), and a real window lists `Workstation` and `Desktop`.

Idle auto-pause is **ON** (`SH_IDLE_PAUSE_SECS=60`, the fleet default; flipped
2026-08-11 — registration shipped `0` for fear of freezing Darkstar
mid-Pilot-tick). The fear was misplaced for a whole-VM freeze: QMP `stop` halts
the kiosk's virtual clock together with the emulator, so Pilot sees no
discontinuity on `cont` — and the exhibit already lives on wrong wall time by
design: every `loadvm golden` resumes the kiosk clock from bake day, with
Darkstar's TOD pinned by `star.cfg` at emulator start (see the time lock,
above). Proven on a soltest clone: 2- and 20-minute QMP stop soaks both resumed
to the intact desktop with the Star cursor still answering `stardrv rel`
nudges.

## Shutting down

**`xdotool windowclose` is NOT a clean exit and it silently discards the disk
image.** Darkstar writes the image back only from `Program.cs` →
`system.Shutdown()` → `_hardDrive.Save()`, reached after the main form's dialog
returns `DialogResult.OK`. Destroying the X window from outside gets WinForms far
enough to kill the emulation thread and then throws `Cannot call Invoke or
BeginInvoke on a control until the window handle is created`; the process dies
*before* `Shutdown()` and the file's mtime never moves. An hour of desktop-creation
work was lost to this once.

For the tile it is mostly moot — the golden is a QEMU RAM+device snapshot, so
Darkstar never has to flush — but **any script that relies on the `.img` must
drive `System → Exit`** and wait for the process to leave. On this tile the System
Menu is off-screen; slide the window to (0,0) first.

## Rollback

The tile is a thin overlay with an internal `golden` snapshot. Never
`rm`/recreate `overlay.qcow2` — the golden lives inside it. To roll the exhibit
back to the baked desktop: `scripts/serve/reset-tile.sh star`, or by hand
`python3 /root/qmp_hmp.py <qmp.sock> 'loadvm golden'` **followed by an explicit
`info status` check** — a golden baked while the VM was stopped restores paused,
which looks perfect and is dead.

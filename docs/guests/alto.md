# Xerox Alto II XM — gallery tile notes (udp/54137)

**Guest:** a captured **Debian 12 x86_64 kiosk** running **ContrAlto 2**
([`jdersch/Contralto2`](https://github.com/jdersch/Contralto2), BSD-3-Clause,
.NET 8 + Avalonia) as a **Xerox Alto II XM**, booted from the
**Non-Programmer's Disk**. An **"emulator bridge"** tile — streamhost captures
the Linux framebuffer exactly like every other tile. See
**`streamhost/docs/BRIDGE.md`**.

**Shared base:** `/data/vms/bridge/bridge-base.qcow2` — which does **not**
contain ContrAlto or a .NET runtime; see
[The emulator, and where it is built](#the-emulator-and-where-it-is-built).
**Build script (tile):** `scripts/build-guests/tiles/alto.sh` — pinned source
checkout + patch + self-contained publish + thin overlay + kiosk `launch.sh` +
quiet console + golden bake + framebuffer-asserted keyboard, pointer and reset
proofs, fully automated, ~12–18 minutes from scratch.
**Tile dir (host):** `/data/vms/streamhost/tiles/alto/`.
**Registry entry:** `registry/tiles/alto.json` (slot 137, udp 54137, VMID 243,
ssh hostfwd 127.0.0.1:5843).
**Feasibility study:** [`docs/lab/research/xerox-add.md`](../lab/research/xerox-add.md)
§1. **Build log for the three-tile Xerox wave:**
[`docs/lab/research/xerox-build-log.md`](../lab/research/xerox-build-log.md).

## Acceptance criteria

| | |
|---|---|
| Emulator | ContrAlto 2 pinned at `e3681fbc30d129172b4c306aaee8c4e71ae1a458`, plus `scripts/build-guests/patches/contralto2-wmless-kiosk.patch` |
| Machine | `SystemType = TwoKRom` — the Alto II XM's 2K control ROM |
| Media | none staged. The microcode PROMs and eight Diablo packs ship inside the emulator's repository; the exhibit's pack is `Disks/nonprog.dsk`, sha256 `2696bc0d…a289`, asserted by the builder |
| Device set | `qemu-system-x86_64 -machine pc-i440fx-11.0 -m 1024 -smp 2 -cpu host`, IDE qcow2 overlay, `-vga std`, dbus display + AC97, `-usb -device usb-tablet`, `e1000` on SLIRP with `hostfwd 5843→22` |
| Kiosk canvas | **608×808, portrait** |
| Ready state | the **Alto Executive** banner and `>` prompt, cold, untouched |
| Reset | `loadvm` snapshot `golden` |
| Pointer | absolute `usb-tablet`; three buttons RED/YELLOW/BLUE = left/middle/right |
| Keyboard | `SH_KEY_MIN_HOLD_MS=66`, `SH_KEY_MIN_GAP_MS=66` (two Alto fields) |
| Login | none. The Alto has no user accounts and no network in this tile |

## The machine, and why its screen is the exhibit

The Alto is the machine every other exhibit on the wall is descended from:
overlapping windows, a mouse with buttons, a what-you-see-is-what-you-get
editor, Ethernet and laser printing, all working in 1973, none of it for sale.

The single most visible thing about it is the shape of the screen. The Alto's
bitmap is **606 × 808 pixels at about 72 dots to the inch**, which is 8.5 × 11
inches, which is a sheet of paper standing on end. That was the point: PARC was
building the office of the future and the display had to be a page. It is the
reason every document window since has been taller than it is wide, and it makes
this the only exhibit in the collection whose screen is portrait.

There is no CPU chip. The processor is a few hundred TTL parts microcoded into
**sixteen priority tasks** that share one datapath: the display task repaints the
screen straight out of main memory, the disk task shifts Diablo sectors, the
Ethernet task moves packets, and the lowest-priority task emulates the
instruction set the software is written in. The screen is not driven by a video
card; it is driven by the same hardware that runs the programs, which is why the
Alto slows down while it is drawing.

## The emulator, and where it is built

**MAME does not work.** `xerox/alto2.cpp` exists, the romset verifies clean and
`chdman` converts the packs correctly, but across five packs and 120-second runs
the framebuffer stays a uniform white field with the emulator task's PC pinned at
1. The same `xmsmall.dsk` boots to the Executive under ContrAlto. That negative
result is recorded in `xerox-add.md` §1.1 so nobody pays for it twice.

ContrAlto 2 is C# on **.NET 8** with an Avalonia UI. The tile carries **none** of
that as a dependency: `alto.sh` runs `dotnet publish -c Release -r linux-x64
--self-contained true` on the **host**, and only the ~150 MB output tree crosses
into the overlay, where it runs with no runtime installed and no apt package
added to the shared bridge base. The ~350 MB SDK is downloaded once into
`/data/gallery-guests/Alto/dotnet` and never enters a tile.

That publish output is also where the exhibit's *content* comes from. ContrAlto
ships `ROM/AltoI`, `ROM/AltoII` and `Disks/` in its own repository, so the
microcode and eight Diablo packs arrive with the source the emulator is built
from — the same story as `gt40`'s `lunar.lda`. Nothing is downloaded, staged
under `/data/assets-staging`, or committed.

### Which pack, and why not the one the study used

`xerox-add.md` booted `xmsmall.dsk`. Do not ship it: its `?` listing is Chat,
Ftp, FileStat and Scavenger — **no Bravo and no Draw at all** — and it greets the
visitor with `// This USER.CM has NON-STANDARD parameters!`.

The exhibit boots **`nonprog.dsk`, the Non-Programmer's Disk**: `BRAVO.RUN`,
`DRAW.RUN`, `EMPRESS.RUN`, `Laurel.run`, the Helvetica family and a shelf of
document templates. Its Executive also renders in the Alto's proportional serif
face rather than a fixed one, which simply looks more like the machine people
remember.

One correction to the study while we are here: §1.2 says "Alto I says
Executive/11 … OS 20/16; Alto II says Executive/12 … 18/16". That is a property
of the **disk**, not the machine. Running `TwoKRom` throughout, `xmsmall.dsk`
reports Executive/12 and `nonprog.dsk` reports Executive/11.

## The two patches, and the failure each one hides

Both live in `scripts/build-guests/patches/contralto2-wmless-kiosk.patch` and the
builder refuses to continue if they do not apply.

**1. `KioskMode = True` crashes upstream, on every platform, before the first
frame.** `AltoUIViewModel`'s constructor sets `FullScreenDisplay = true` when the
config asks for kiosk mode, and the setter measures the screen through a window
the view model is not attached to yet:

```
System.InvalidOperationException: No parent window found.
   at ContraltoUI.ViewModels.ViewModelBase.FindWindowByViewModel(…)
   at ContraltoUI.ViewModels.AltoUIViewModel.set_FullScreenDisplay(Boolean)
```

Kiosk mode is not optional cosmetics: the Avalonia **menu bar** and the
**Fields/Sec status bar** both bind to `!FullScreenDisplay`, so it is the only
switch that keeps emulator chrome out of the captured framebuffer.

**2. Nothing places the window, and nothing focuses it, because there is no
window manager.** Two separate symptoms:

- Avalonia leaves the window at its default `+10+10`, which paints a black L down
  two edges of the root and pushes ten rows of the Alto's picture off the bottom.
  Measured before the patch: `Contralto 608x816+10+10`. After: `608x808+0+0`.
- The keyboard goes through `AltoDisplay.OnKeyDown`, a `Focusable` UserControl
  that normally gets Avalonia focus because a user **clicks** it. Nothing clicks
  anything in a kiosk, so every keystroke was dropped and the Executive sat there
  blinking its cursor — indistinguishable from a dead emulator. `OnLoaded →
  Focus()` fixes it.

X input focus, by contrast, is **not** a problem here and it is worth knowing
why: with no WM the X focus is `PointerRoot`, so keys go to the window under the
pointer, and this window covers the whole root. A tile whose emulator window is
smaller than its root does not get that for free.

## Geometry: 608×808, and there is no slop

The study called the portrait geometry the biggest risk in the add, because QEMU
`-vga std` wants a width that is a multiple of 8 and 606 is not. The answer was
in ContrAlto's own source: it renders a **608-wide bitmap**
(`ALTO_DISPLAY_BITMAP_WIDTH`, "rounded up so it's a nice even multiple of 8
bits") around the 606 visible pixels. 608 **is** a multiple of 8.

So the kiosk root is exactly `608x808` — the Alto's own picture, no letterbox, no
painted surround, no 2-pixel slop, and no `presentAspect.ts` entry. `bochs-drm`
advertises no such mode and the bridge base has no `cvt`, so the launcher carries
a hardcoded modeline:

```sh
xrandr --newmode alto608x808 33.00 608 640 704 800 808 811 821 838 -hsync +vsync
xrandr --addmode "$OUT" alto608x808 && xrandr --output "$OUT" --mode alto608x808
```

A QMP `screendump` then comes back `608x808`. **This recipe generalises**: any
bridge tile whose emulator wants a non-standard canvas can have one, as long as
the width is a multiple of 8. Changing it invalidates the golden — re-bake.

The kiosk runs `startx -- -nocursor`, unlike `gt40`: ContrAlto warps the *Alto's*
cursor to the host pointer, so the Alto draws its own arrow and the X core
pointer would be a second, wrong one a pixel away.

## Input

**Absolute pointer with no calibration**, which is unusual for an emulator
bridge. ContrAlto's UI calls `MouseMoveAbsolute()` — it warps the Alto cursor to
where the host pointer is rather than feeding it deltas — so a stock `usb-tablet`
lands where the visitor points. Measured on the clone, uncalibrated:

| requested | Alto cursor |
|---|---|
| (300, 400) | (302, 402) |
| (100, 700) | (101, 700) |
| (600, 800) | (602, 802) |

**Three buttons, all of them real.** RED/YELLOW/BLUE are host left/middle/right,
and Bravo is where the difference is visible — it is the machine's own selection
grammar, and it is the proof the builder runs on every build (400 ms dwell):

| host | Alto | Bravo, observed |
|---|---|---|
| left | RED | underlines one **character** |
| middle | YELLOW | underlines the whole **word** |
| right | BLUE | **extends** the selection to the pointer |

Do not use DRAW as the middle-button oracle: a middle click there does nothing at
all, which is a Draw fact rather than a transport fault.

The five-key **chord keyset** is a separate physical device and no candidate rest
state needs it; it is placard material, not an input path.

### Key pacing — measured, and NOT the same as its Xerox siblings

ContrAlto samples its keyboard once per Alto field, so playbook §5.1 applies. One
20-character line, explicit `input-send-event` press/release pairs:

| hold/gap | landed |
|---|---|
| 16/16 ms | 15 of 20 |
| 33/33 ms | 20 of 20 |
| 66/66 ms | 20 of 20 |
| 120/120 ms | 20 of 20 |

One field is 33 ms; the tile ships two, **66/66**. Worth stating plainly because
the other two Xerox tiles in the same wave need ~400 ms holds under Darkstar and
Dwarf: **that is not a fleet-wide constant.**

**Modifiers must lead by a full gap.** Pressing `shift` and the letter in one QMP
event lost the capital every time — `Bravo` arrived as `ravo` and the Executive
answered `There is no subsystem named ravo.`, which reads exactly like a missing
file rather than a dropped keystroke. `alto-drive.py` in the tile dir presses the
modifier one gap early; streamhost's own pacing does the same thing for the
browser path, which is why the SPA's macros do not have to care.

## The fixture, and the argument about it

**The golden rests at the Alto Executive, untouched, exactly as a cold boot
leaves it.**

The tempting alternative was Bravo. It is the headline — the first WYSIWYG word
processor — and it takes about half a minute to load, so baking inside it would
put every visitor straight into it with no wait. `xerox-add.md` §1.4 raised
exactly this and left it to the operator.

The operator has already answered it once. `plus4` shipped a golden curated
*inside* its ROM office suite and **10ae428 reversed it**: a visitor arrives
mid-application with no idea what it is, how they got there or how to leave. The
Alto case is not different enough to overturn that. So:

- the fixture is the machine's own empty state, which is also its launcher;
- the choice of application moves into the exhibit UI, exactly as `plus4`'s did.
  `spa/src/ui/keyboard/keyboardProfiles.ts` gives `alto` its own family whose
  first row is **?**, **BRAVO**, **DRAW**, **LAUREL** — one Executive command
  each, lower case because the Executive is case-insensitive, so no Shift ever
  has to survive the wire.

`?` is on that row for a reason: the Executive's own directory listing is the
machine answering "what can I run", and it is the closest thing the Alto has to
`plus4`'s power-on screen advertising its own suite.

## Cost

| | |
|---|---|
| ContrAlto RSS (in guest) | ~180 MB |
| CPU | ~170–190 % of a core while the Alto runs (`ThrottleSpeed = True` holds it near real Alto speed) |
| Guest RAM | 1024 MB |
| Overlay | thin qcow2 on the shared bridge base; ~150 MB of emulator tree plus the golden |

The Alto never idles — the display task repaints 30 fields a second whatever is on
screen — so `SH_IDLE_PAUSE_SECS=60` is left explicitly ON in `tile.env.fixture`.
Do not copy `amiga`'s `SH_IDLE_PAUSE_SECS=0` here.

## Operating

```bash
ssh lab 'labctl ls'
ssh lab 'labctl shot alto /tmp/alto.png'
ssh lab 'labctl exec alto "uname -a"'    # the Debian KIOSK, not the Alto
curl -ksS -X POST https://192.0.2.10:8443/restore/alto
```

`labctl exec` reaches the kiosk, not the emulated machine: the Alto has no shell
and no network in this tile. To drive the Alto itself use `labctl type/key`
(paced at 66/66) or the tile's own `alto-drive.py`, which additionally leads
modifiers by a gap and can count ink in a rectangle of the framebuffer:

```bash
ssh lab 'python3 /data/vms/streamhost/tiles/alto/alto-drive.py \
  /data/vms/streamhost/tiles/alto/qmp.sock type 66 66 bravo'
ssh lab 'python3 /data/vms/streamhost/tiles/alto/alto-drive.py \
  /data/vms/streamhost/tiles/alto/qmp.sock ink 0 88 608 40'   # banner ink
```

## Rebuilding

```bash
# On the box, from a synced repo tree:
scripts/build-guests/tiles/alto.sh              # idempotent; re-syncs the kiosk
scripts/build-guests/tiles/alto.sh --force-app  # re-publish + reinstall ContrAlto
scripts/build-guests/tiles/alto.sh --force      # throw the overlay away and start over
```

The builder always cold-boots the live overlay and never passes `-loadvm`: an
internal qcow2 snapshot carries the **disk** as well as RAM, so restoring the
golden would silently revert the launcher the run just wrote. Only the production
launcher restores.

## Known gaps

- **No boot video.** A cold boot reaches the same Executive the golden restores
  to, so a clip is possible; it is simply not recorded yet. See
  `scripts/coldboot/alto-zero-input-prep.md`.
- **No Ethernet.** `HostPacketInterfaceType = None`. Two Altos talking to each
  other over PUP would be a wonderful exhibit and is not this one.
- **Smalltalk-76 is not on the shipped pack.** The Virtual OS Museum catalogues a
  Smalltalk-76 Alto pack that was never fetched; `nonprog.dsk` has the Bravo/Draw
  office story instead. A second pack is a future question, not a defect — see
  the variant policy in `docs/lab/research/home-computer-candidates.md` §3.
- **The lit pixel is faintly blue-green**, `0xffdffcff`, hardcoded in ContrAlto
  rather than the white a real P4 tube emitted. Left as upstream: it is the
  emulator author's phosphor choice, and patching a colour is not worth carrying.

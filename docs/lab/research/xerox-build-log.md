# Xerox build wave — shared agent log

Three agents are building three Xerox tiles in parallel, each in its own git
worktree. **Append to your own section as you learn something the others could
act on, and commit.** Read the other sections before you start and whenever you
are stuck — the three machines share an emulator lineage, a licence posture, an
input idiom and a media family, so a finding in one is very often a finding in
all three.

Feasibility background: [`xerox-add.md`](xerox-add.md). Virtual OS Museum
reference and its licence boundary: [`vom-reference.md`](vom-reference.md).

## Scope split

| Agent | Tile | Emulator | Slot / UDP |
|---|---|---|---|
| **A — alto** | Xerox Alto II | ContrAlto 2 (.NET 8) | 137 / 54137 |
| **B — star** | Xerox Star 8010 "Dandelion" + Pilot/ViewPoint 2.0 | Darkstar (C#/mono) | 138 / 54138 |
| **C — daybreak** | Xerox 6085 "Daybreak" + ViewPoint 2.0.5 | Dwarf/Draco (Java) | 139 / 54139 |

**Hard constraint from the operator:** each tile must emulate the *real vintage
machine*. The GlobalView-on-Windows-3.1 route (`xerox-add.md` §3 Route B) is
**rejected** — no second emulation layer, no Windows host. Each tile must also
reach a **graphical UI**, either at boot or via one simple documented command.

## Known-shared facts (read before you start)

- **MP 8000 is Pilot's normal run state, not a hang.** The bouncing-keyboard
  screen is "logged off — press a key". The wake key is **`Ctrl+N`** (Xerox
  NEXT) under Dwarf. One study lost 25 minutes calling this a stall.
- **`Tab` is not NEXT.** ViewPoint runs on Xerox Level-V keys (NEXT, OPEN,
  PROPERTIES, MOVE, COPY, AGAIN, UNDO, DELETE, HELP, SKIP, DEFAULTS). The logon
  sheet cannot be completed without NEXT. Agents B and C both need this;
  **build the `keyboardProfiles.ts` family once and share it.**
- **Two-button mouse** (SELECT / ADJUST) on Star and Daybreak; Alto is three
  (RED/BLUE/YELLOW).
- **Clicks need real dwell** — a zero-dwell synthetic click did nothing in the
  ViewPoint option sheet; press → ~400 ms → release actuated reliably.
- **Licence posture is identical for all three:** Xerox material is
  preservation-class. URL + measured sha256 + size + class in
  `docs/lab/ASSETS-MANIFEST.md`, **never the bits** — the repo is public, the
  gallery is passkey-private. A BSD licence on an emulator does not launder the
  Xerox software it ships.
- **VOM is a reference, never a source to copy.** Its scripts/metadata are
  CC BY-NC-SA and this repo is MIT + public. Read it to learn *which emulator
  and which image*; fetch from upstream; write our own launcher.

## Agent A — Alto

### The two focus layers, and which one actually bit (2026-08-10)

Both of the failure modes Agent C hit under Swing exist under Avalonia too, but
only one of them mattered here, and knowing which saves the next agent an hour.

- **Toolkit/component focus — REAL, and fatal.** ContrAlto routes the Alto
  keyboard through `AltoDisplay.OnKeyDown`, a `Focusable="True"` UserControl
  that only ever receives Avalonia focus because a user clicks it. Nothing
  clicks anything in a WM-less kiosk, so every keystroke was dropped before it
  reached the emulated keyboard and the Alto Executive just sat there blinking
  its cursor — indistinguishable from a dead emulator. Fixed in source rather
  than with a synthetic click: `AltoDisplay.OnLoaded -> Focus()`, in
  `scripts/build-guests/patches/contralto2-wmless-kiosk.patch`.
- **X input focus — NOT a problem, and here is why.** With no WM the X focus is
  `PointerRoot`, so key events go to the window *under the pointer*. The
  ContrAlto window covers the entire root (608x808+0+0), so the pointer is
  always over it and no `XSetInputFocus` is needed. This only bites a tile whose
  emulator window is smaller than the root. (The bridge base has no `xdotool`
  anyway.)

### Pacing: ContrAlto DOES follow the frame-quantisation model

Four rungs, same 20-character line, explicit `input-send-event` press/release
pairs (never `send-key`'s async hold-time), on the clone:

| hold/gap | landed |
|---|---|
| 16/16 ms | 15 of 20 |
| 33/33 ms | 20 of 20 |
| 66/66 ms | 20 of 20 |
| 120/120 ms | 20 of 20 |

So the playbook §5.1 rule holds for ContrAlto (33 ms is one Alto field) and the
400 ms Dwarf/Darkstar figure is NOT a fleet-wide constant — measure yours.
Shipping two fields, 66/66.

**Modifiers must LEAD by a full gap.** Pressing `shift` and the letter in one
QMP event lost the capital every single time: `Bravo` arrived as `ravo`, and the
Executive answered "There is no subsystem named ravo." — which reads exactly
like a missing file rather than a dropped keystroke. Press the modifier, wait one
gap, press the key, release the key, wait, release the modifier. With that,
35 characters of mixed case landed intact in Bravo, first try.

### Portrait geometry: there is no slop, and the study's 608x816 is not needed

`ALTO_DISPLAY_BITMAP_WIDTH` in ContrAlto is **608** ("rounded up so it's a nice
even multiple of 8 bits") around 606 visible pixels, and the control renders the
whole 608-wide bitmap. 608 IS a multiple of 8, so QEMU `-vga std` takes it
directly. The kiosk root is therefore exactly **608x808** — the Alto's own
picture, no letterbox, no painted surround, no 2 px slop.

The bridge base's `bochs-drm` advertises no such mode, but a custom one is
accepted verbatim; the tile launcher does
`xrandr --newmode alto608x808 33.00 608 640 704 800 808 811 821 838 -hsync
+vsync` then `--addmode`/`--output --mode`, and a QMP `screendump` comes back
`608x808`. No `cvt` in the guest, so the modeline is hardcoded. **This recipe
generalises**: any bridge tile whose emulator wants a non-standard canvas can
have it, as long as the width is a multiple of 8.

### Media: nothing to fetch, nothing to stage

The `dotnet publish` output ships `ROM/AltoI`, `ROM/AltoII` **and** `Disks/`
with eight packs including `xmsmall.dsk`, `bravox54.dsk`, `games.dsk`,
`nonprog.dsk`. Same shape as gt40's `lunar.lda`: the exhibit's content arrives
with the source the emulator is built from. Nothing is downloaded, staged or
committed.

**`nonprog.dsk` — the Non-Programmer's Disk — is the pack the exhibit wants.**
`xmsmall.dsk` has no Bravo and no Draw at all (its `?` listing is Chat, Ftp,
FileStat, Scavenger…), and it greets the visitor with
`// This USER.CM has NON-STANDARD parameters!`. `nonprog.dsk` carries
`BRAVO.RUN`, `DRAW.RUN`, `EMPRESS.RUN`, `Laurel.run`, the Helvetica font set and
a shelf of document templates, and its Executive renders in a proportional serif
face rather than a fixed one.

**Correction to `xerox-add.md` §1.2**: "Alto I says Executive/11 … OS 20/16;
Alto II says Executive/12 … 18/16" is a property of the DISK, not the machine.
Running `SystemType = TwoKRom` (Alto II XM) throughout, `xmsmall.dsk` reports
Executive/12 OS 18/16 and `nonprog.dsk` reports Executive/11 OS 20/16.

### Input: genuine absolute pointer, and all three buttons proven

`MouseMoveAbsolute()` is as good as the study promised. With a stock
`-usb -device usb-tablet` and no calibration, requested root coordinates land on
the Alto cursor within ~2 px, corners included: (300,400)->(302,402),
(100,700)->(101,700), (600,800)->(602,802).

The three buttons were proven with the machine's own canonical test, inside
Bravo 7.5, with a 400 ms dwell:

| host button | Alto button | Bravo behaviour, observed |
|---|---|---|
| left | RED | underlines ONE character |
| middle | YELLOW | underlines the whole WORD |
| right | BLUE | EXTENDS the selection to the pointer |

Middle-click reaches the guest intact through QEMU's `usb-tablet`. A middle
click in DRAW does nothing at all, so do not use DRAW as the middle-button
oracle — that is a Draw fact, not a transport fault.

## Agent B — Star / Pilot

_(append findings here)_

## Agent C — Daybreak / ViewPoint

_(append findings here)_

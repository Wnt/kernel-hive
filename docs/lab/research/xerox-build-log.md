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

- **MP codes are not a progress bar, and a still screen is not a dead machine.**
  Three separate near-misses in this project, all the same mistake:
  1. **MP 8000 on Draco** was called a stall for 25 minutes. It is Pilot's
     normal *run* state — the bouncing keyboard means "logged off, press a key".
     The wake key is **`Ctrl+N`** (Xerox NEXT).
  2. **MP 7800 on Darkstar** *was* a real stall — but the cause was the
     **Dec-1997 time lock**, not the emulator. TOD 1997-12-01 fixes it.
  3. **MP 7600 on Darkstar sat for ~8 minutes** on a blank white screen with
     zero disk I/O, matching every symptom of upstream issue #22 — then
     advanced on its own. **Slow, not hung.**

     *(Corrected: first reported as ~35 minutes, from a sense of elapsed time
     across work-turns rather than the box clock. Measured from file mtimes:
     start 02:05:06 → Set Time banner 02:09:49 → "Starting ViewPoint……" 02:12:28
     → MP 7600 02:14–02:20 → MP 7700 02:20:37. The qualitative finding is
     unaffected; the number was not defensible and is retracted rather than
     quietly changed. Every timing here now carries a box-clock timestamp —
     `MEASUREMENT-METHODOLOGY.md` §2 in miniature.)*

  Consequences, in order of how much time they save:
  - **A still screen is not a diagnosis.** A healthy MP step can take ~8 minutes
    with nothing visibly happening. Do not conclude "hung" from stillness alone.
  - **"No disk I/O" proves nothing here.** The 65 MB hard-disk image is fully
    page-cached after the first pass, so a *healthy* boot also shows zero reads.
  - Distinguish the three before diagnosing: a wrong TOD wedges, low speed
    crawls, and a logged-off desktop just waits for a keystroke.
  - **Use an oracle, not the framebuffer.** Where the emulator can log the input
    it actually received (Dwarf: `-logkeypressed`), that separates "the key never
    arrived" from "the key arrived and Pilot ignored it". Without it you are
    inferring causes from a static screen — which is how all three of the above
    happened.
- **`Tab` is not NEXT.** ViewPoint runs on Xerox Level-V keys (NEXT, OPEN,
  PROPERTIES, MOVE, COPY, AGAIN, UNDO, DELETE, HELP, SKIP, DEFAULTS). The logon
  sheet cannot be completed without NEXT. Agents B and C both need this;
  **build the `keyboardProfiles.ts` family once and share it.**
- **Synthetic input fails silently at TWO focus layers in a WM-less kiosk**, and
  the symptom is indistinguishable from a dead emulator. Both are now measured:
  - **X input focus.** With no WM, X focus is **`PointerRoot`** — keys go to the
    window *under the pointer*. So it is a non-issue when the emulator window
    covers the whole root (Alto: 608×808 on a 608×808 root, no `xdotool`
    needed), and it bites the moment your window is **smaller than the root**.
    That is the rule; `xdotool windowfocus` is the fix, not the explanation.
  - **Toolkit/component focus.** Confirmed on BOTH toolkits. Avalonia:
    ContrAlto routes keys through `AltoDisplay.OnKeyDown`, a Focusable
    UserControl that only gains focus from a click — in a kiosk nothing clicks
    it, so every keystroke is dropped. Swing: Dwarf's display panel likewise
    never fires its KeyListener. Fix either with one synthetic click inside the
    emulated screen, or properly in-source (Agent A patched
    `AltoDisplay.OnLoaded -> Focus()`).
  - **Use the emulator's own key log as the oracle** (Dwarf `-logkeypressed`):
    it separates "the key never arrived" from "the key arrived and was ignored".
- **Key pacing has TWO models — measure, never assume.** The playbook's
  "emulators sample input once per emulated frame" rule holds for some and not
  others: **ContrAlto is frame-quantised** (16/16 ms dropped 5 of 20 chars;
  33/33, 66/66, 120/120 all landed 20/20 → ship 66/66), while **Dwarf/Swing
  coalesces** and needs **400 ms hold + 150 ms gap**. Darkstar needs ~300 ms on
  the WinForms *top-level* window (the SDL child lands nothing). Three
  emulators, three answers.
- **Hold the MODIFIER too — the dwell law is not just for keys.** A partially
  applied shift, inconsistent from key to key, is the signature. On Dwarf's
  first sweep `Shift+;` → `;` and `Shift+a` → `a`, while in the *same* sweep
  `Shift+1` → `!`, `Shift+8` → `*`, `Shift+[` → `{`, `Shift+=` → `+` all shifted
  correctly. **Cause: batching the modifier and the key into ONE input event**,
  so both transitions land in the same instant and the toolkit can dispatch the
  key before the modifier state updates. Send shift as its own EARLIER event,
  held across the key:

  ```
  shift-down · 350 ms · key-down · 400 ms · key-up · 250 ms · shift-up
  ```

  That fixed every case at once on Dwarf: `Shift+a` → `A`, `Shift+;` → `:`.
  **The 350 ms lead is a safe recipe, not a threshold, and the two machines
  differ.** Bisected afterwards on Dwarf: leads of 150 / 250 / 350 ms ALL
  produce `:A`, so what fails there is a lead of *zero* (the batched event) and
  `SH_KEY_MIN_GAP_MS=150` is sufficient. Darkstar genuinely needs the long lead
  — 200 ms failed, 350 ms worked. Carry the rule, measure the number.
  A genuine keymap gap would not pass `" { } < > ? _ + | * ( )` while dropping
  the shift on `;` alone — so **suspect event shape before you suspect the
  keymap.** The SPA's shift latch already does the right thing (shift as a
  separate `sendKey`, paced by `SH_KEY_MIN_HOLD_MS=400`), which is why no colon
  button is needed in the Level-V family.
- **Never distinguish `:` from `;` by eye on a ViewPoint screen — test it
  functionally.** The bitmap font renders them nearly identically even at 400 %
  zoom, and Agent B lost time to that in *both* directions. The functional test
  is whether the field accepts the value: ViewPoint's own template menu inserts
  `user:star:xerox` and it is accepted, while a typed `star;star;xerox` is
  rejected. This matters because Desktop Creation demands an XNS three-part name
  (`name:domain:org`).
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
  emulator window is smaller than the root. (The bridge seed has no `xdotool`
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

The bridge seed's `bochs-drm` advertises no such mode, but a custom one is
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

### SHIPPED (2026-08-10): `alto`, slot 137, udp 54137

Live, streaming, golden-verified. Cost, measured on the live tile with the
daemon attached: host QEMU **732 MB RSS / 189 % of a core**, the streamhost
daemon **49 MB / 20 %**, and in-guest ContrAlto **177 MB / 162 %**. The encoder
runs the native **608x808** with no scaling (`[encode] geometry 608x808 tier=0
-> out 608x808`), at ~28.5 fps against a 30 fps cap.

Rest state: the **Alto Executive**, untouched, NOT inside Bravo — 10ae428's
Plus/4 ruling applies unchanged, and the application choice went into the
on-screen keyboard instead (?, BRAVO, DRAW, one Executive command each; LAUREL
is deliberately absent — the mail reader wants a Grapevine server this tile has
no Ethernet for, and answers with a blank page and an hourglass).

**Two traps that cost runs here, both likely to bite you as well:**

1. **`loadvm` leaves the guest PAUSED.** HMP `savevm` stops the guest, writes
   the vmstate and resumes, so the state INSIDE the snapshot is "paused" and a
   bare `loadvm` hands back a frozen guest. Every screen-based readiness check
   still passes, because the framebuffer shows the restored picture — and then
   nothing you type does anything. `labctl` sends `cont` for you; a bare QMP
   harness must do it itself.
2. **Bound your framebuffer thresholds ABOVE as well as below.** A black screen
   measures 24320 "ink" pixels in a 608x40 rect — the whole rectangle — so a
   `> 1500` readiness test declares a guest that has not started X yet READY,
   and the build then fails one line later with a message about something else
   entirely.

And one that is only embarrassing: the first version of the ContrAlto patch file
was cut from a diff taken **before** the focus fix was written. The tile built
from it looked perfect and typed nothing. If you carry a patch file, regenerate
it from the tree you actually proved, and diff the file count.

## Agent B — Star / Pilot

**Build rig (reproducible):** overlay chroot `xstarb` at
`/data/vms/soltest/XEROX-star-b/` — `bookworm-chroot` as read-only lower,
`apt install mono-complete mono-xbuild nuget libgdiplus xvfb imagemagick xdotool`.
Debian *bookworm* ships **mono 6.8.0.105**, not 6.12; it builds and runs
Darkstar fine. `nuget restore D.sln` → `xbuild /p:Configuration=Release D.sln`
→ **0 errors, 18 warnings, 3.8 s** at HEAD `7ab55ff3` (2026-04-08).

**Three Linux fixes, not two.** The study's two are right (delete the bundled
Windows `SDL2.dll`; add `SDL2-CS.dll.config` with
`<dllmap dll="SDL2.dll" target="libSDL2-2.0.so.0"/>`). The third is a
*launcher* fix: **Darkstar resolves its PROM/microcode paths relative to the
CWD** (`Path.Combine("IOP","PROM",name)`), so it must be started with
`cd <bin/Release>` first — from any other CWD it dies with
`FileNotFoundException: /IOP/PROM/537P03029.bin`. And **`-rompath` is not the
tree root** — it replaces the whole `IOP/PROM` prefix, so `-rompath .` makes it
look for `./537P03029.bin`. Simplest correct invocation: `cd bin/Release &&
mono ./Darkstar.exe -config <cfg>`, no `-rompath`.

**`AltBootMode = Rigid` is worth far more than "can save time".** With
`TODSetMode = SpecificDateAndTime` / `TODDateTime = 1997/12/01 09:00:00` and
`Start = true`, the machine went **0940 → MP 8000 and the Set Time Utility 2.0
banner in ~3 minutes** on a *72 %-loaded* box — not the 25–35 min the study
projected. The study's long first boot was the **TOD-1990 time lock plus
`DiagnosticRigid`**, not an inherent cost. (Framebuffer-verified.)

**MP 8000 + "System is running" is reached before the Set Time dialogue**, so
MP 8000 really is the run state and not a completion signal for boot.

**Keyboard: NEXT is `Home`, and the whole Level-V row is plain PC keys.**
Darkstar's own table (README §3.2) — `Again F1, Delete F2, Find F3, Copy F4,
Same F5, Move F6, Open F7/LCtrl, Props F8/RCtrl, Center F9, Bold F10,
Italics F11, Underline F12, Defaults NumLock, **Skip/Next Home**, Undo PgUp,
Defn/Expand End, Stop PgDn, Help Up, Margins Left, Font Backslash,
Keyboard Down`. So the SPA macro row for the Star emits ordinary qcodes; no
`Ctrl+letter` layer is needed (that is Dwarf's idiom, Agent C's tile).

**Keystrokes need DWELL, exactly like the clicks — and this is the single
biggest input finding for both Star and Daybreak.** Under Xvfb, `xdotool key`
(a ~12 ms XTEST press) landed **nothing** in the Set Time teletype: four
presses across four candidate focus windows produced one advance, which reads
as flaky focus but is not. `xdotool keydown Return; sleep 0.3–0.45;
xdotool keyup Return` on the **top-level `Darkstar` window** lands every time.
Focus target is the WinForms top-level (`xdotool search --name '^Darkstar$'`),
**not** the SDL child window — focusing the child (the 1088x860 one) lands
nothing. Turn X autorepeat off (`xset -r`) first or a 450 ms hold enters
several CRs. Practical consequence for the SPA: this is the §5.1
`SH_KEY_MIN_HOLD_MS` case with an unusually large floor — budget **≥250 ms
hold**, not two frames.

**Where the keys actually have to go, and why (Agent A's PointerRoot note,
checked against this rig).** The Xvfb root here is 1280x1024 and the Darkstar
window is **1091x915** — smaller than the root — so with no WM, X focus is
`PointerRoot` and keystrokes follow the pointer. But that is not the whole
story on this emulator: with focus set explicitly, the **WinForms top-level
`Darkstar` window** accepts keys and the **SDL child window (the 1088x860 one)
does not**. Darkstar embeds SDL with `SDL_CreateWindowFrom`, and the key
handling lives on the WinForms form, not on the SDL surface. So the rule for
this tile is: aim at the top-level window, *and* keep the pointer inside it.

**Set Time Utility, the whole dialogue, with `TODDateTime = 1997/12/01`:** five
prompts, all answerable with a bare CR — Time-zone offset (`-8`), Minute offset
(`0`), First day of DST (`98`), Last day of DST (`305`), then
`Current time: 1-Dec-97 1:06:53 / Do you wish to change the time? (Y/N): N`
→ `Starting ViewPoint......`. So the "interactive first boot" is **five
carriage returns**, not a data-entry session.

**The ViewPoint volume boot is SLOW, not hung — and telling the two apart takes
over half an hour.** After `Starting ViewPoint......` the machine restarts into
the ViewPoint volume. Measured against the box clock, on a ~72 %-loaded host:

| box clock | state |
|---|---|
| 02:05:06 | Darkstar started (`Start=true`, `AltBootMode=Rigid`, TOD 1997-12-01) |
| 02:09:49 | **Set Time Utility 2.0 banner** — 4 min 43 s from cold start |
| 02:12:28 | five CRs answered → `Starting ViewPoint......` |
| 02:13 | MP 0960, grey stipple |
| 02:14 – 02:20 | **MP 7600**, blank white page, zero disk I/O — ~6–8 min |
| 02:20:37 | MP 7700 |

Every symptom of the upstream issue-#22 hang, and it was simply the next step
of a slow boot. So `0910 → 7600 → 7700 → 7800 → 8000` is real, each step takes
minutes at ~50 % speed, and "no disk I/O" proves nothing — the 65 MB image is
entirely page-cached after the first pass. The study's `e5.png` "live ViewPoint desktop"
frame is **Draco/6085, not Darkstar**; the Star had not reached its desktop on
this box before this run.

**THE STAR REACHES THE VIEWPOINT 2.0 DESKTOP. Cold start to desktop: 22
minutes, on a ~72 %-loaded box.** Continuing the box-clock table above:

| box clock | state |
|---|---|
| 02:26:37 | **MP 8000 + the bouncing-keyboard screen** (logged off) — 21 min 31 s from cold start |
| 02:27:11 | **the ViewPoint 2.0 desktop**, after ONE `Home` (= Xerox NEXT) keypress with a 300 ms hold |

**There was no Logon Option Sheet at all.** With no XNS Clearinghouse on the
wire, this `ViewPoint-2.0-11-9-1990-18-38.img` wakes straight onto a logged-on
**Workstation Administration** desktop — grey stipple ground, a
`35176 Free Disk Pages` header strip, and a Workstation Administration window
offering Desktop Creation / Desktop Deletion / Desktop Changes. So the study's
warning that the logon sheet "cannot be completed without NEXT" is moot on this
image: NEXT is still needed, but only as the single wake keystroke.

Total interactive cost of a cold first boot is therefore **six keystrokes** —
five CRs through Set Time and one NEXT — and 22 minutes of waiting.

**Interactive responsiveness on the live desktop — the number that actually
decides this tile.** Measured by firing an action and polling the framebuffer
until it changes (an `import` grab costs 0.19 s, so treat that as the floor),
with the box at ~72 % load and Darkstar showing 45–52 f/s (58–67 % of real):

| action | latency to first repaint |
|---|---|
| pointer move (Star cursor follows) | **0.19 s** — at the measurement floor, i.e. immediate |
| click the `Desktop Creation` button (opens a form) | **1.08 s** |
| click `Start` (validates, posts a message) | **0.89 s** |
| click `Desktop Creation` again (collapses the form) | **0.59 s** |
| select the `Directory` icon on the user desktop | **0.78 s** |
| `OPEN` (F7) on it → the Directory window paints | **0.96 s** |

So the desktop is *slow but alive*: the cursor tracks the hand, and a button
takes about a second to answer. A real 8010 was not brisk either, so this reads
as period-authentic rather than broken — but it is measured at 58–67 %, not at
100 %, and the pinned-idle gate run is still owed.

**THE STAR'S MOUSE IS RELATIVE, AND THAT IS A TILE-DESIGN PROBLEM.**
`DWindow-IO.cs` computes `dx = x - DisplayBox.Width/2`, feeds
`IOP.Mouse.MouseMove(dx, dy)`, then `SDL_WarpMouseInWindow`s the host pointer
back to the centre — with `SDL_SetWindowGrab` confining it. There is no
absolute path. Every pointer tile in this gallery is absolute (`usb-tablet`),
and streamhost sends absolute coordinates; fed to Darkstar those become deltas
from the centre and the Star cursor runs away. **A Star tile needs either a
relative pointer path or a patched/agent-driven Darkstar.** Budget for it.

**A second mouse trap: the Star drops large deltas.** A single 985 px move
applied only ~127 px; **50 px steps at 120 ms apply 1:1**. Any pointer driver
for this machine has to walk, not jump.

**RETRACTED, then fixed: `:` IS Shift+`;` — the modifier needs the same dwell
as the key.** I first reported the colon as unreachable on the Star, because
`Shift+;` produced `;` while `Shift+a` → `A` and `" { } < > ? _ + | * ( )` all
came through. That looked like a keymap gap and it is not. Agent C hit the
identical symptom on Dwarf and found the cause: **the modifier is subject to
the same dwell law as the key.** With C's timing —

```
shift-down · 350 ms · key-down · 400 ms · key-up · 250 ms · shift-up
```

— Darkstar produces a colon. Proof, typed adjacent in one ViewPoint field and
read at 500 %: `B : N ; M` from `Shift+b`, `Shift+;`, `Shift+n`, plain `;`,
`Shift+m` — the colon has two dots and no descender, the semicolon has the
comma tail. My failing attempt used a 200 ms shift lead and a 300 ms hold; the
letters survived it and the punctuation did not, which is what made it look
selective.

Two lessons worth more than the colon:
- **Pace the MODIFIER, not just the key.** A chord is two dwells, not one.
- **Never distinguish `:` from `;` by eye on a ViewPoint screen.** At 400 % the
  two are near-identical in the Star's bitmap font; I called a colon a
  semicolon and then called a semicolon a colon. Test functionally (does the
  three-part name validate?) or set the two glyphs side by side at 500 %.

The SPA needs no new affordance for this: the shift latch already sends shift
as its own `sendKey` and `SH_KEY_MIN_HOLD_MS=400` paces it.

**THE ICONIC VIEWPOINT DESKTOP IS REACHABLE — and here is the exact route.**
The image's out-of-the-box state is a **Workstation Administration** desktop
(grey stipple, `Free Disk Pages` header, one window with Desktop Creation /
Deletion / Changes). That is a genuine logged-on ViewPoint desktop, but it is
an administrator's console, not the file-drawer desktop the Star is famous for.
Getting to the real one, all framebuffer-verified (box clock 02:41 → 03:07):

1. On the admin desktop, click **Desktop Creation**. It expands into
   `Name` / `Password` fields and an `Administrator` toggle.
2. **Use the little menu button beside `Name`** (press and hold — it is
   spring-loaded) and pick the template it offers, `user:star:xerox`. Typing
   the name by hand works too now that the colon is solved, but the template
   also tells you the machine's own default domain and organisation.
3. Edit it to a name that does not already exist — the shipped image already
   has `user:star:xerox`. `user:star:xerox2` is fine. **The caret in this field
   always sits at the end**: clicking mid-string does not move it, so append
   rather than insert.
4. Click into `Password` (clicking an EMPTY field *does* place the caret; NEXT
   does not move between fields in this sheet, contrary to the study's warning
   about the logon sheet), type a password, arm `Administrator`, click `Start`.
5. The machine **logs itself out** and returns to the bouncing keyboard.
6. `Home` (NEXT) now brings up the **real Logon Option Sheet** — Xerox
   1981-1988 copyright, `Name`, `Password`, `Default Domain`, `Default
   Organization`, and the header prompt *"Please type your user-name and then
   press <NEXT>"*. Set `Default Organization` to match the desktop you made,
   fill in name and password, click `Start`.
7. **The ViewPoint user desktop**: grey stipple ground, the `35168 Free Disk
   Pages` header with a `Help` button, and the **Directory** icon in the
   bottom-right corner — the same furniture Draco shows on the 6085. Selecting
   that icon and pressing `OPEN` (F7) gives a real Directory window listing
   `Workstation` and `Desktop`, with `Close` / `Redisplay` buttons.

Two hazards in that sequence, both of which cost me a cycle: `Start` needs the
pointer *precisely* on the button (a 57 px miss silently does nothing, with no
hover feedback to warn you), and the machine logs out at step 5 without asking.

**`xdotool windowclose` is NOT a clean exit, and it silently discards the
disk.** Darkstar writes the hard-disk image back only from
`Program.cs` → `system.Shutdown()` → `_hardDrive.Save()`, reached after the
main form's dialog returns `DialogResult.OK`. Destroying the X window from
outside gets WinForms far enough to kill the emulation thread and then throws
`Cannot call Invoke or BeginInvoke on a control until the window handle is
created` — the process dies **before** `Shutdown()`, and the image file's mtime
never moves. I lost an hour of desktop-creation work to this. **The only safe
shutdown is the `System → Exit` menu item.** For a tile this is mostly moot —
a bridge tile's golden is a QEMU snapshot of the whole kiosk VM, RAM included,
so Darkstar never has to flush — but any build script that relies on the `.img`
must drive that menu and then wait for the process to leave.

**Darkstar's own "100 %" is 77.4 fields/sec**, not 78: `DWindow.cs` computes
`(_frameCount / 77.4) * 100`. So the study's `>= 78 f/s` gate is the right
number to one decimal, and the percentage in the status bar is directly
comparable.

**Rig hygiene note:** `xvfb-alloc`'s exit trap did NOT fire for a rig launched
under `setsid nohup`, leaving three claimed displays alive after their emulator
had exited. `xvfb-alloc release <pid>` works; `xvfb-alloc release :N` silently
does nothing. Call `xvfb_release` explicitly at the end of a detached rig
rather than trusting the trap, and check `xvfb-alloc list` — its OWNER column
names the script that claimed each display, which is how I proved the three
strays were mine and not a sibling's.

**Speed, under a loaded box (not the gate run):** 22 f/s (28 %) during boot,
settling to **43–53 f/s (55–68 %)** at MP 8000, with the process taking ~178 %
CPU (emulation + SDL blit). Box was ~72 % busy on all 16 logical CPUs. The
quiesced pinned gate run is reported separately.

### THE STAR IS A LIVE TILE (2026-08-10) — and the pointer was never the blocker

Shipped as `star`, slot 138, UDP 54138, VMID 240, kiosk ssh 5840. Bridge tile on
the shared Debian kiosk base, built by `scripts/build-guests/tiles/star.sh`;
full write-up in [`docs/guests/star.md`](../../guests/star.md).

**The "needs a relative pointer path or a patched Darkstar" conclusion above was
wrong, and the correction is worth reading twice.** Six tiles already ship
`SH_POINTER=rel` (`qnx`, `nt351`, `amstradcpc`, `c64`, `freedos`, `msdoswin1`) and
the daemon has a documented bounded/paced relative backend. Darkstar's own scheme
— difference the host pointer against the DisplayBox centre, warp it back under
an SDL grab — is exactly what a relative kiosk pointer feeds correctly. Nothing
was patched and nothing was forked. Declared honestly as relative, the tile earns
the derived `Rel. pointer` badge, which exists for precisely this.

Measured through the deployed browser client, with the Star cursor located in the
QMP framebuffer: **gain is 1:1** (−336,+230 commanded → −336,+230 applied). The
caveat is the ORIGIN, not the gain — see the guest doc.

**Findings the other two Xerox tiles can use:**

- **`xset m 1 0` DOES NOT TURN OFF POINTER ACCELERATION under libinput.** The core
  pointer control reports `acceleration: 1/1  threshold: 0` while the device goes
  on applying its own adaptive profile. Measured ~1.8x on medium moves, which
  reads exactly like a broken relative path. The switch is an xorg.conf.d
  `InputClass` with `AccelProfile "flat"`. This cost a whole round of pointer
  measurements against a knob that was lying.
- **`loadvm golden` reverts the DISK too.** An internal qcow2 snapshot is RAM
  *and* disk, so every `apt-get install` and every config file written after the
  bake vanishes on the next reset — silently, while the framebuffer still looks
  right. Two pointer measurement rounds were invalidated by exactly this: the fix
  was in the guest, the reset took it away, and the numbers looked like the fix
  had not worked. **Re-bake after any in-guest change you intend to keep.**
- **Darkstar does not track the mouse until the display has been CLICKED once**
  ("Click on the display to capture mouse/keyboard" in its status bar), and
  **either Alt key RELEASES the capture again**. The kiosk arms it with a
  dwelled click at startup so the capture is inside the golden, and the tile
  remaps both Alt scancodes away (`SH_KEY_REMAP=0x38:0x46,0xe038:0x46`).
- **Turn X autorepeat off (`xset -r`).** Darkstar wants a ~300 ms hold, X repeats
  at 660 ms, Pilot repeats on its own. Agent A and C: check yours.
- **The emulator chrome does not have to be in the frame.** The X root is a custom
  1088x860 mode — exactly Darkstar's DisplayBox — and `launch.sh` moves the
  1091x915 WinForms window to (0,−29), so the System Menu and System Status bars
  fall outside the captured framebuffer. The visitor sees the Star screen and
  nothing else, and cannot reach `System → Exit`. `/root/starmp.sh` slides the
  window 26 px to read the MP code and slides it back.
- **This box is much faster than the 72 %-loaded measurements above suggested.**
  Cold boot inside the tile: Set Time banner in ~1 minute, logged-off screen at
  17 minutes, 42–45 fields/sec (54–58 % of Darkstar's own 77.4) at the desktop.
  Cost: **~144 % of a core for the whole QEMU tile, 1.6 GB RSS host-side, 292 MB
  for mono inside a 1536 MiB guest.**
- **The Desktop Creation route needed one correction to B's write-up.** The
  machine only logs itself out when a desktop is actually CREATED; re-submitting
  an existing name just reports "already exists" and sits there. Create a *new*
  name with `Administrator` armed. Also: the caret in the Name field is NOT
  always at the end — clicking mid-string puts it mid-string, so click past the
  end of the text before backspacing. And `Start` acts on whichever sub-form is
  expanded, so collapse Desktop Deletion before using it.
- **Shifted punctuation on Darkstar is FLAKY, not slow.** Fifteen shifted
  characters typed back to back all landed (`A : " < > ? _ + { } | * ( )`); the
  same chord embedded in a word did not, at leads from 200 ms to 700 ms, through
  XTEST *and* through QMP scancodes. Retracting the "350 ms works" number: it is
  not a threshold. Verify the glyph instead — and note that remapping the X
  keymap (`xmodmap -e 'keycode 47 = colon colon'`) makes the key produce
  **nothing at all**, because Darkstar's table is keyed on the layout it expects.

## Agent C — Daybreak / ViewPoint

**Status: ViewPoint 2.0.5 desktop reached and baked into a golden snapshot**
(2026-08-09). Draco is not merely alive, it is the cheap, boring one. Route
confirmed Tier 2. Tile id `daybreak`, slot 139, UDP 54139, ssh 5839.

### The route, end to end

Emulator-in-captured-Linux **bridge** tile, exactly the `amiga`/`plus4` shape:
a thin qcow2 overlay on `/data/vms/bridge/bridge-base.qcow2` whose
`/etc/bridge/launch.sh` runs `java -jar dwarf.jar -draco vp2.0.5`. No new
backend was needed — Dwarf is a Swing app, and the bare-X kiosk already in the
base is enough.

- **`openjdk-17-jre` from plain Debian bookworm runs Dwarf unchanged.** No
  Temurin tarball, no backports, no JRE staged into the overlay by hand — one
  `apt-get install`. (The study said Java 21; 17 is what the frozen base can
  reach, and it works.)
- **Media fetched from upstream, hashes reproduce the study's exactly**:
  `dist.zip` → `67f84b77…cf75` (509 198 B, BSD-3-Clause),
  `disks-6085/vp2.0.5.zdisk` → `02bdb53b…f872` (4 657 062 B, Xerox
  preservation-class). Both from `github.com/devhawala/dwarf/raw/master/…`.
- Boot to the logged-off bouncing-keyboard screen: **~90 s** from kiosk start.
- Logon → desktop: **~70 s** more. Idle at the desktop: **~226 MB RSS** for the
  JVM inside a 1536 MiB guest.

### The two traps that actually cost time — both are focus, not Pilot

The published correction is right that `Ctrl+N` is the wake key. It is not
sufficient. **On a bare-X kiosk with no window manager, `Ctrl+N` does nothing,
and the failure is silent in exactly the way that produced the original "MP 8000
stall" report.** Two separate focus layers must both be satisfied:

1. **X input focus.** No WM means nothing calls `XSetInputFocus`, so the Dwarf
   frame never becomes the focus window and X delivers the key to nobody. Fix:
   `xdotool search --name 'Xerox 6085' | xdotool windowfocus`.
2. **Swing component focus.** Even with the frame focused, Dwarf's display panel
   does not hold the component focus, so its `KeyListener` never fires. Fix:
   **one synthetic click inside the Mesa screen**. Until that click, `java -jar
   dwarf.jar … -logkeypressed` logs *nothing at all*; after it, every key is
   logged. That log line is the cheap oracle — if `-logkeypressed` is silent,
   the problem is focus, not Pilot, not the keymap, and not the emulator.

Both are now in the tile's `launch.sh`. **Agents A and B: if you are driving a
GUI emulator under bare X with no WM, assume this applies to you too** — and use
`-logkeypressed` (or your emulator's equivalent) to tell "key never arrived"
apart from "key arrived and was ignored", instead of staring at a framebuffer.

### Dwell: measured, and it is not 250 ms

B's warning about long holds is directionally right but the number does not
transfer. Measured on Dwarf/Swing:

- **key hold 400 ms, gap 150 ms → 5/5 characters** of a typed user name landed,
  and `Ctrl+N` actuated first time.
- The earlier zero-length `send-key` chord (press+release in one QMP event)
  landed **nothing**, which is what makes this look like a hang.

400 ms is what is shipped (`SH_KEY_MIN_HOLD_MS=400`). Swing coalesces, it does
not sample per emulated frame, so the two-frame rule from the playbook does not
apply here. Mouse clicks need the same ~400 ms dwell as the study said.

### The German keymap is a real blocker, and the fix is in the repo

Dwarf ships **only** `kbd_linux_de_DE.map`, and with a keymap file loaded
*there are no defaults* — every unmapped key is dead. On a US layout that
mis-seats `Y`/`Z` and the whole punctuation block. This tile ships a US map
(`kbd_linux_en_US.map`, generated by `scripts/build-guests/tiles/daybreak.sh`)
with the Level-V block unchanged from Dwarf's documented `Ctrl!<letter>` idiom.

### Level-V keyboard family — Agent C owns it, B reuses it

Per the coordinator: one Level-V family in `spa/src/ui/keyboard/keyboardProfiles.ts`
with a **per-machine keycode map**, since the two machines emit completely
different host keys for the same logical button (Daybreak: `Ctrl+letter`;
Star: plain PC function keys). Written by C; B consumes it.

### Logon, and what the visitor is looking at

There is **no Clearinghouse and no Dodo server**, so ViewPoint cannot find a home
File Service. That is not an error state to fix — it is the documented
standalone path: any user name plus any password, then ViewPoint offers *"Do you
want a new Desktop created for you?"* and builds a **temporary desktop**. This
tile logs on as `guest`/`guest` in domain `dev`, organisation `hawala` (the
disk's own defaults) once, at bake time; visitors never see the logon sheet
because the golden restores the running desktop.

The rest state is that desktop: the 50 %-dither grey ViewPoint desk, the message
area reading `91198 Free Disk Pages`, a `Help` button, and a single `Directory`
icon bottom-right. Sparse on purpose — it is the machine's honest empty state and
the Directory icon is its launcher (the `plus4` lesson: do not park a visitor
inside an application they cannot name or leave).

### Display

`largeScreen = true` → the 19" 6085 screen, **1152×861 monochrome**. The Dwarf
frame around it is **1152×913** (toolbar + Mesa screen + status line). The kiosk
therefore builds a **custom 1152×914 X mode** (`xrandr --newmode`, accepted by
QEMU std-VGA + modesetting) so the frame fills the captured framebuffer with no
grey gutter. Do not use a stock mode here — 1280×1024 leaves a large dead margin
on two sides.

### Answer for Agent B: the colon, and why it is not a keymap gap

**Yes — Dwarf types a literal `:`, and it is `Shift`+`;` (host `semicolon`),
exactly where you would expect it.** Proven in a ViewPoint text field (the
Directory Divider Properties "Icon label"), then compared against a plain `;`
typed immediately after it. Following your own rule I did not trust the glyph
by eye at first — but with the cursor moved away and the pair rendered
side by side, `:` (two dots, no descender) and `;` (dot plus comma tail) are
unambiguously different bitmaps, adjacent, in one field.

**The interesting part is what it took, and I think it is your actual bug.**
On the first attempt `Shift`+`;` produced `;`. So did `Shift`+`a` → `a`. But in
the same sweep `Shift`+`1` → `!`, `Shift`+`8` → `*`, `Shift`+`[` → `{` and
`Shift`+`=` → `+` all came out correctly shifted. **A partially-applied shift,
inconsistent key to key** — which is precisely the signature you are
describing on Darkstar: most shifted characters fine, `Shift`+`;` not.

The cause was the shape of the synthetic event, not the mapping. I was sending
the modifier and the key **in one QMP `input-send-event` batch**, so both
transitions land in the same instant and the toolkit sometimes dispatches the
key before the modifier state updates. Sending the shift as its **own earlier
event**, held across the key, fixed every case at once:

```
shift↓ · 350 ms · key↓ · 400 ms · key↑ · 250 ms · shift↑
```

With that, `Shift`+`a` → `A`, `Shift`+`b` → `B`, `Shift`+`;` → `:`. Same 400 ms
dwell law as everything else on these machines, now applied to the modifier as
well as the key. **Try that before touching the Darkstar keymap** — if your
XTEST helper batches the modifier with the key, or holds it for the same ~12 ms
that already failed you, this is the same bug wearing a different hat.

**How long a lead does Dwarf actually need? Measured: less than 150 ms — the
killer is a lead of ZERO, not a short one.** With the modifier as its own event
at leads of 150 / 250 / 350 ms, `Shift`+`;` then `Shift`+`a` produced `:A` every
time (`Directory:A:A:A` in one field). So the tile ships
`SH_KEY_MIN_GAP_MS=150` unchanged and the SPA's shift latch is safe on this
machine. **The two machines differ here and it matters:** Dwarf fails only when
the modifier and the key ride the same input event, while Darkstar needs a
genuinely long lead (200 ms failed, 350 ms worked). Do not carry one machine's
threshold to the other — carry the *rule* (modifier is a key, give it its own
event and its own dwell) and measure the number.

**Confirmed on Darkstar the same day, with a number worth keeping.** B applied
the timing above and the Star now types `B : N ; M` from `Shift+b`, `Shift+;`,
`Shift+n`, plain `;`, `Shift+m` — so the XNS three-part name, Desktop Creation
and the Logon Option Sheet are all unblocked there too. B's *failing* attempt
had used a **200 ms modifier lead with a 300 ms key hold**: letters survived
that, punctuation did not. That asymmetry is the whole trap — it reads as a
selective keymap gap rather than a timing problem. **The modifier lead has to be
genuinely long; 200 ms is not enough even where 300 ms is fine for plain keys.**
The cheap discriminator: a real keymap gap would not pass `" { } < > ? _ + | * (
)` while dropping the shift on `;` alone. (Both lessons are now promoted into
`docs/lab/ADD-NEW-OS-PLAYBOOK.md` §5.1 — they are not Xerox-specific.)

Consequence for the Level-V family: **no colon button is needed** in
`xerox-dwarf`, and probably none in `xerox-star` either. The SPA's shift latch
already sends shift as a separate `sendKey` and the tile's
`SH_KEY_MIN_HOLD_MS=400` paces it, which is the working pattern. I have left the
family without one; add it only if the timing fix does not resolve your case.

### Scene signature and shared-work status

- Level-V keyboard family: **written and pushed** — family `xerox-dwarf` in
  `spa/src/ui/keyboard/keyboardProfiles.ts`, built from `LEVEL_V_META` (shared
  labels/hints) + a per-machine `LevelVBinding` + `levelVRow()`. B adds a
  `STAR_LEVEL_V` table and a `'xerox-star'` family; nothing else changes. Keys a
  machine has no binding for are omitted automatically — Dwarf has none for
  SKIP, DEFAULTS or EXPAND, so those buttons are absent here and will appear
  only on the Star.
- Scene assembly signature taken by `daybreak`:
  **`pizzaBox | pizzaBoxD | crtD | keyboardE | paramMouseC`**. Pick a different
  body+monitor pair for the Star.

### Open risk — the JVM exit

The **unexplained JVM exit** from the first study did **not** recur. The
YES/START moment it was first seen at passed cleanly on the first attempt, and
the JVM survived every subsequent step: logon, golden bake, `loadvm` restores,
the Directory open, a shifted-punctuation sweep, and continuous idling. RSS is
flat at ~226–229 MB across the whole window with no upward drift, which is the
shape of a healthy JVM rather than one heading for an OOM.

Measured: **~71 minutes of observed liveness** across two windows — 02:02→02:39
on the prototype before the bake, 02:50→03:25 under the production daemon while
streaming — **35 one-minute samples, 0 of them non-active**, JVM RSS bounded at
**225 064–228 564 kB**. Whole-tile cost while streaming: **~17 % of one core**,
QEMU RSS ~1.65 GB. One unreproduced crash is still not the same as no crash, so
the next person to touch this tile should keep watching. Details in
`docs/guests/daybreak.md`.

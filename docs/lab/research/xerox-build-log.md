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
  3. **MP 7600 on Darkstar sat for ~8 minutes** (02:12→02:20 box clock) on a
     blank white screen with zero disk I/O, matching every symptom of upstream
     issue #22 — then advanced to 7700 on its own. **Slow, not hung.**
     *(Correction, Agent B: this was first logged as "~35 minutes". That figure
     was wrong — it came from counting work-turns instead of reading the clock.
     Timestamp every observation from the box's `date`, not from how long it
     felt.)*

  Consequences, in order of how much time they save:
  - **Do not call a Darkstar boot dead inside an hour.**
  - **"No disk I/O" proves nothing here.** The 65 MB hard-disk image is fully
    page-cached after the first pass, so a *healthy* boot also shows zero reads.
  - Distinguish the three before diagnosing: a wrong TOD wedges, low speed
    crawls, and a logged-off desktop just waits for a keystroke.
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

_(append findings here)_

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

**Speed, under a loaded box (not the gate run):** 22 f/s (28 %) during boot,
settling to **43–53 f/s (55–68 %)** at MP 8000, with the process taking ~178 %
CPU (emulation + SDL blit). Box was ~72 % busy on all 16 logical CPUs. The
quiesced pinned gate run is reported separately.

## Agent C — Daybreak / ViewPoint

_(append findings here)_

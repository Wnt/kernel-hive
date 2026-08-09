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
  3. **MP 7600 on Darkstar sat for ~35 minutes** on a blank white screen with
     zero disk I/O, matching every symptom of upstream issue #22 — then
     advanced on its own. **Slow, not hung.**

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

**Set Time Utility, the whole dialogue, with `TODDateTime = 1997/12/01`:** five
prompts, all answerable with a bare CR — Time-zone offset (`-8`), Minute offset
(`0`), First day of DST (`98`), Last day of DST (`305`), then
`Current time: 1-Dec-97 1:06:53 / Do you wish to change the time? (Y/N): N`
→ `Starting ViewPoint......`. So the "interactive first boot" is **five
carriage returns**, not a data-entry session.

**IN FLIGHT — the ViewPoint volume boot is where the Star actually stalls, and
it is MP 7600, not 7800.** After `Starting ViewPoint......` the machine
restarts into the ViewPoint volume and has now sat at **MP 7600 for ~30 min**
with the display a uniform blank page, the emulator healthy (32–53 f/s,
~175 % CPU, 233 MB RSS) and **zero disk I/O** in the interval. The study's
MP 7800 stall was the TOD-1990 time lock and is gone; this is a *different*
wall, and it is consistent with upstream issue #22 (ViewPoint boot hangs on
Linux at sub-100 % speed). Note the study's `e5.png` "live ViewPoint desktop"
frame is **Draco/6085, not Darkstar** — nobody has yet reached the ViewPoint
desktop on the Star on this box.

**Speed, under a loaded box (not the gate run):** 22 f/s (28 %) during boot,
settling to **43–53 f/s (55–68 %)** at MP 8000, with the process taking ~178 %
CPU (emulation + SDL blit). Box was ~72 % busy on all 16 logical CPUs. The
quiesced pinned gate run is reported separately.

## Agent C — Daybreak / ViewPoint

_(append findings here)_

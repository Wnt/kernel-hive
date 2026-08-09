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

_(append findings here)_

## Agent C — Daybreak / ViewPoint

_(append findings here)_

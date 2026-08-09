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

_(append findings here)_

## Agent C — Daybreak / ViewPoint

_(append findings here)_

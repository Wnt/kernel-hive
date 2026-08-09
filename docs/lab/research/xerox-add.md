# Adding the Xerox machines: Alto, Star, Daybreak/ViewPoint

Status: **research, 2026-08-09.** Nothing is built, no registry entry exists, no
slot is claimed. This is the feasibility study
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 expects before a
candidate enters the backlog.

Scope: Alto I, Alto II, the Star (8010 "Dandelion") / Pilot, and the Daybreak
(6085) / ViewPoint / GlobalView. **Only the Alto section below is complete** —
the Star and Daybreak studies were still running when this file was written and
their sections are placeholders. See "Open sections" at the end.

---

## 1. Alto — FEASIBLE, Tier 2, and it is ONE tile

Verdict: **build it, as a single `alto` tile** running Alto II XM under
ContrAlto 2. Alto I becomes placard prose.

### 1.1 The emulator: ContrAlto 2, verified on the box

[`jdersch/Contralto2`](https://github.com/jdersch/Contralto2) (BSD-3-Clause),
Josh Dersch's maintained successor to the Living Computers ContrAlto, commit
`e3681fbc30d129172b4c306aaee8c4e71ae1a458`.

| Question | Answer |
|---|---|
| Runtime | C#, **.NET 8**, Avalonia 11.1.3 |
| Builds here? | Yes — `dotnet publish -c Release -r linux-x64`, clean |
| Debian cost | **Zero apt packages.** Debian 12/13 ship no `dotnet-*`; a `--self-contained` publish is a **27 MB standalone tree** that runs with `DOTNET_ROOT` unset. The 334 MB SDK is build-time only and never enters the tile. |
| WM-less X root? | Yes — ran under Xvfb with no WM and no compositor |
| Acceleration? | No; software rendering on a GPU-less host |
| Cost | **171–185 MB RSS**, ~1.7–1.8 cores at 80–92 % of real Alto speed |

Booted to the Alto Executive in ~10 s, and to **Bravo 5.4A** — the first WYSIWYG
word processor — in ~48 s.

**The negative result that saves the next person a day: MAME's `alto2` does not
boot here.** The driver exists (`xerox/alto2.cpp`, status `good`), the romset
verifies clean from `alto2_cpu.zip`, and `chdman` converts the bitsavers packs
correctly — but across five packs and runs up to 120 s the framebuffer stays a
uniform white field, with the emulator task's PC pinned at 1. The same
`xmsmall.dsk` that fails under MAME boots to the Executive under ContrAlto.
So the KC 85 / Oric / BBC "just use MAME" precedent does **not** transfer.
UNVERIFIED whether this is a driver regression or a CHD-metadata subtlety.

Salto (C/GTK) was **not evaluated** — moot once ContrAlto worked, and it would
only be the fallback if the .NET bundle is objectionable.

### 1.2 Alto I vs Alto II: one exhibit

ContrAlto distinguishes them (`SystemType = AltoI | OneKRom | TwoKRom |
ThreeKRam`, separate microcode ROM sets) and both were booted. **A visitor sees
no difference** — same portrait bitmap, same Executive, same font. Alto I says
`Executive/11 … OS Version 20/16`; Alto II says `Executive/12 … 18/16`.

Under the §3 variant policy in
[`home-computer-candidates.md`](home-computer-candidates.md) that is a placard,
not a second stream: ~1 GB of a tight budget to change a banner digit. The real
Alto I story — the 1972–73 prototype run, microcode ROM vs RAM, Diablo 31 vs 44 —
is placard and poster material.

### 1.3 Media: no ROM staging at all

**ContrAlto ships both the microcode PROMs and eight disk packs in its own
repo** (`ROM/AltoI`, `ROM/AltoII`, `Contralto/Disks/`), and its `bcpl.dsk` is
byte-identical to bitsavers'. The media is plain `.dsk` — the CHD conversion is
a MAME-only tax.

Additional packs fetched and hashed on the box (all bitsavers,
`bits/Xerox/Alto/`): `xmsmall.zip` `f78b2c48…`, `bravox.zip` `4542ac4d…`,
`games.zip` `3c5b80af…`, `bcpl.zip` `1f359513…`, `allgames.dsk` `44cacf57…`,
`alto_firmware.zip` `33be7565…`. Smalltalk-80 sources (`st80src`) and
`mazeWar.dsk.gz` exist and were not fetched.

**Licence, read strictly.** CHM states PARC authorised it to provide the files
"to private individuals and non-profit institutions with the same rights granted
to CHM", non-commercial. That is a *file-archive* grant, not a public
redistribution licence, and it does not on its face cover the Diablo pack
images. Posture is unchanged and comfortable: private passkey-gated exhibit,
stream pixels only, **URL + sha256 + class in `ASSETS-MANIFEST.md`, never bits**.
The BSD-3 licence covers Dersch's code, not the Xerox microcode or the packs.

### 1.4 What the exhibit shows

Rest state: **the Alto Executive** — banner, three-line header, `>` prompt. Text,
but *the* text: the first thing anyone saw on the machine that invented the
screen everyone is looking at.

The 30-second interaction is typing a command (`Bravo`, `Draw`, `Neptune`) —
keyboard-only, no pointer skill needed.

**Open question for the operator.** Bravo is the headline but takes 26 s to
load. Baking the golden *inside Bravo* lands the visitor in the first WYSIWYG
word processor with no wait. That is the call `plus4` made and then **reversed**
in `10ae428` — the operator rejected a golden resting inside an application
because a visitor arrives mid-application with no idea what it is. The Alto case
is arguably different (the Executive is 26 s of nothing away from the point),
but it is the same question and the operator should decide the house style.

### 1.5 The two things that will bite the builder

**Portrait display.** Native **606 × 808 @ 30 Hz**. Three consequences:
- The SPA is probably free — `presentAspect.ts` is opt-in and the default
  `object-fit: contain` letterboxes correctly. Do **not** add an `alto` entry;
  square pixels are right. UNVERIFIED end to end.
- **The 3D scene is the real cost.** Every assembly in `machines.ts` models a
  landscape CRT. The Alto's tall tube in its pedestal is a **new model**, and it
  is the largest non-emulator line item in the add.
- **Kiosk geometry trap:** QEMU `-vga std` wants a width that is a multiple of
  8, and **606 is not**. Use a `608×816` root (2 px slop, window centred) or a
  larger portrait root with painted surround. The base `.xinitrc` forces
  1024×768, so this needs a per-tile override.
- **ContrAlto's `KioskMode = True` crashes at startup**
  (`InvalidOperationException: No parent window found` in
  `AltoUIViewModel.set_FullScreenDisplay` — the ctor toggles fullscreen before
  the window exists). Its menu and status bars must not reach the capture.
  Workaround: toggle fullscreen at runtime, or a one-line patch. The repo
  already patches emulators (`previous-wmless-window-borders.patch`).

**Input — and this is the best news in the study.** ContrAlto's UI calls
`MouseMoveAbsolute()`: it *warps the Alto cursor to the host pointer* rather than
feeding deltas. So this tile gets **`--pointer abs` with the standard
`usb-tablet` device set**, like `atarist`/`apple2` — not the relative-pointer
exception that cost NeXTSTEP a five-angle investigation. Three buttons are
required (RED/BLUE/YELLOW = host 1/2/3) — check the browser path delivers
middle-click. The five-key **keyset maps to F5–F9 and is not required** by any
candidate rest state; it is a placard fact.

**Automation is first-class:** ContrAlto has a scripting engine (`-script`) with
`Command`, `Type`, `KeyStroke`, `MouseMove`, `Wait` — better golden-bake tooling
than most tiles get.

### 1.6 Cost

Tier 2, same shape as `pdp11`/`amiga`: emulator built into the tile overlay with
a matching `bridge-base.sh` addition. Budget **~1.0–1.3 GB host RSS**; CPU is
**~1.7–1.8 cores**, noticeably hungrier than an 8-bit VICE tile — worth a
quiesce-window measurement before it joins a hot fleet.

### 1.7 Biggest risk, and the experiment that retires it

**The portrait geometry, end to end**: QEMU std-VGA (width ×8, and 606 is not) →
X root → an Avalonia window whose chrome must be suppressed by a code path that
provably crashes → capture → SPA letterbox → a 3D scene that has never modelled
a tall tube.

**Half a day, no golden, no registry entry:** clone `bridge-base.qcow2` into a
throwaway overlay, drop in the 27 MB ContrAlto tree, set the root to `608×816`,
start fullscreen past the crash, and take a QMP screendump. A chrome-free Alto
Executive with no letterbox slop proves the whole display chain below the SPA;
what remains is scene modelling and ordinary tile paperwork. Measure RSS and the
three mouse buttons on the same clone.

---

## 2. Star / Pilot — OPEN

Study in flight at the time of writing. The crux is expected to be **media**:
Star/Pilot/ViewPoint software is far scarcer than Alto software and Xerox never
released it the way CHM released the Alto stack. The emulator candidate is
**Darkstar** (also Josh Dersch). If no bootable image is obtainable the honest
answer is BLOCKED-ON-MEDIA, and the fallback the operator named — "or another
Pilot OS tile" — becomes the question.

## 3. Daybreak / ViewPoint / GlobalView — OPEN

Study in flight. Two routes, an order of magnitude apart in cost:
- **A: emulate the 6085.** Emulator maturity expected to be well behind
  ContrAlto/Darkstar.
- **B: GlobalView on hardware the gallery already emulates.** Xerox ported the
  ViewPoint environment to commodity hardware as GlobalView for Windows. The
  gallery already runs `win311`, `win95`, `win98se`, `win2000`, `winxp` and
  `nt4` as production tiles with proven goldens and builders to copy. If
  GlobalView 2.x runs on one of them this needs **no new emulator at all**, and
  it is a genuine Mesa/Pilot environment rather than a lookalike.

If Route B works it is very likely the cheapest way to get the Xerox desktop
lineage onto the wall, and it may be worth doing *before* the Alto.

---

## Open sections

| Section | State |
|---|---|
| 1. Alto | **Complete** — feasible, one tile, cheapest experiment identified |
| 2. Star / Pilot | Research in flight; fold the report in when it lands |
| 3. Daybreak / ViewPoint | Research in flight; fold the report in when it lands |

## Sources

- [Contralto2](https://github.com/jdersch/Contralto2) ·
  [ContrAlto (LCM)](https://github.com/livingcomputermuseum/ContrAlto)
- [bitsavers Alto disk images](https://bitsavers.org/bits/Xerox/Alto/disk_images/) ·
  [Alto firmware](https://bitsavers.org/bits/Xerox/Alto/firmware/)
- [CHM Xerox Alto file system archive](http://xeroxalto.computerhistory.org/index.html) ·
  [CHM Alto source code release](https://computerhistory.org/blog/xerox-alto-source-code/)
- [MAME `xerox/alto2.cpp`](https://github.com/mamedev/mame/blob/mame0276/src/mame/xerox/alto2.cpp)
- Evidence from this study: `/data/vms/soltest/XEROX-alto/` on the box (1.8 GB,
  inert — delete when the space is wanted).

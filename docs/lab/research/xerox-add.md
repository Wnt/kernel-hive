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

## 3. Daybreak / ViewPoint / GlobalView — FEASIBLE, Tier 2, and it is the CHEAPEST Xerox exhibit

Verdict: **build `gvwin`** — GlobalView 2.1 for Windows inside a QEMU Windows 3.1
guest. It was booted, logged into, driven by mouse and keyboard, and `savevm`/
`loadvm`-cycled in a single research session. Of the three Xerox candidates it is
the only one driven to a working desktop, and it is the smallest tile in the
lineup.

### 3.1 Why this is not a consolation prize

GlobalView is **not a reimplementation**. It is the real Mesa/Pilot environment
with a *software* Mesa emulator hosted on the PC — earlier versions needed a
hardware Mesa CPU board; 2.1 is pure software. It boots a **Pilot 15.3** virtual
disk (`C:\GVWIN001.DSK`, 52 MB). So the tile is a 1996 PC emulating a 1985
workstation, inside a 2026 host emulating the 1996 PC — which is itself the
placard.

### 3.2 Proven on the box

Pre-built image `davidar/gvwin` (MS-DOS + Windows 3.1 + GlobalView 2.1,
autostarts GV, credentials `user`/`pass`), run on a **qcow2 overlay** with
essentially the `win311` device set (`qemu-system-i386 -accel tcg -m 64 -smp 1
-machine pc-i440fx-11.0 -cpu pentium -vga std`, IDE, `ne2k_pci`).
`clone-guard check-launcher` passed.

| Step | Result |
|---|---|
| Cold boot → ViewPoint **Logon Option Sheet** | ~115 s; stable and idle-safe for ~40 min, no screensaver |
| Logon → **desktop** | ~45 s after clicking Start |
| Double-click → **Directory window** | `Workstation` / `Workspace` / `Network`, scrollbars, `Close`/`Redisplay` |
| `savevm golden` → `loadvm golden` | Restores the logged-in desktop bit-for-bit; 13.1 MiB VM state |
| **RSS** | **181–194 MB** with `-m 64` |

That memory figure is the headline: roughly **an eighth of a bridge tile**
(0.70–1.66 GB), about a seventh of `c64`. The cheapest exhibit per gigabyte in
the lineup.

### 3.3 What the exhibit shows — the Star's grammar, intact

A persistent **message area** across the top narrating the system in prose
(`Please type your user-name and then press <NEXT>`, `Icon could not be
opened.`, `23387 Free Disk Pages`); document and folder icons on a desktop that
is literally a desk, the paper icon with a folded corner; windows with a named
**title tab** instead of a title bar, and verbs as header buttons (`Close`,
`Redisplay`, `Start`, `Cancel`) instead of menus; property sheets as the
universal settings idiom. The direct ancestor of everything else on the wall,
looking like none of it.

Rest state: the logged-in desktop (proven stable, instantly restorable). The
30-second interaction is Directory → Workspace, one click per step, each
narrating itself in the message area.

### 3.4 Input — the one piece of real SPA work

- **Two-button machine** (SELECT / ADJUST → PC left/right). Declare a two-button
  **relative** pointer: the guest has a PS/2 mouse, Win3.1 has no USB, so there
  is no `usb-tablet` and this tile earns the `Rel. pointer` badge.
  Windows 3.1 acceleration measured as a **clean factor of 2**, so
  `move(target/2)` after homing lands pixel-accurate — verified over three
  clicks.
- **ViewPoint runs on dedicated Xerox Level-V keys** — **NEXT** (field advance;
  the logon banner instructs the visitor to press it), OPEN, PROPERTIES, MOVE,
  COPY, AGAIN, UNDO, DELETE, HELP, SKIP, DEFAULTS. **`Tab` is not NEXT.** Budget
  one `keyboardProfiles.ts` family for the Xerox function block — the most
  exhibit-defining piece of SPA work in this add. Dwarf ships explicit keymap
  files for exactly this reason.

### 3.5 The trap: GVWin's display config is bound to the Pilot disk

Do not hand-edit it. Three separate hangs prove the point:
- workspace raised to 1024×768 → Mesa **maintenance-panel codes** (8888 → 0606 →
  0223 → 9999) for 19 min, never reaching the logon sheet;
- VBE driver installed, workspace back at 640×480 → same, 8+ min;
- `[Display] Mode=1` → `Mode=0` (monochrome, the historically right look) → hard
  hang at **MP 7649**, 11 min.

Notably **Windows itself comes up perfectly at 1024×768×8** under the shipped
`win311` VBE recipe (`vbesvga.drv` v1.0-beta4) — it is GlobalView that refuses.
Mechanism UNVERIFIED, but the conclusion is actionable: display mode must be
chosen through **GVWin's own Setup at install time**, which reconfigures the
`.DSK`. As it stands the pre-built image is fixed at **640×480, 16 colour**,
with a magenta desktop background.

### 3.6 Route A — emulate the 6085 — is alive, but Tier 3–4

Assumption corrected: it is **not** true that nothing usable exists.
**Dwarf** (`devhawala/dwarf`, **BSD-3-Clause**, disks refreshed 2025-01-11) is a
maintained Java Mesa emulator with two relevant machines — **Draco** (6085 /
Daybreak / Dove) and **Duchess** (the Mesa machine from inside GVWin) — and it
ships a working ViewPoint 2.0.5 disk in-repo. Predecessors: Woodward's **Dawn**,
and `gcasa/Mesa`. (Darkstar is the 8010 Star — §2's subject, not this one.)

It starts: 1152×861 monochrome window, authentic Xerox toolbar, status line with
MP code and instruction counts, ~19 780 sectors read in ~3 min — then **parks at
MP 8000 on the bouncing-keyboard idle graphic** and never leaves, across ~25 min
and three input strategies. **Input reaching X is excluded** as a cause: Dwarf's
own toolbar buttons respond instantly. The missing-nethub hypothesis is also
excluded (the internal time responder answered, `network rcv: 1`). Remaining
candidates: the boot switches in `vp2.0.5.properties`, the shipped **German**
keymap default, or AWT canvas focus. The author's own readme warns Draco's
rigid-disk emulation is imperfect for Pilot.

Route A would also need a **new backend shape** — a JRE + Swing app in a
captured-Linux bridge — and bridge-class memory. Tier 3 if it is a config
one-liner, Tier 4 if it is Draco's disk emulation.

The 6085 media is licence-split and worth stating precisely: the *container* is
BSD-3, **the ViewPoint contents are not** — Xerox-copyright Pilot software, and
its Software Options are unlocked but **bound to processor id
`10-00-FE-31-AB-21`**, so changing the MAC re-locks the applications.

### 3.7 Media and licence

Posture unchanged and non-negotiable: private passkey-gated exhibit, stream
pixels only, **URL + measured sha256 + class in `ASSETS-MANIFEST.md`, never the
bits, and never a download affordance.**

| item | sha256 | class |
|---|---|---|
| `gvwin.img.xz` (github.com/davidar/gvwin), 85 642 196 B | `090e86ab…e9e1` | preservation-source |
| `gvwin.img` decompressed, FAT16, 268 435 456 B | `89bcd7e3…16d05` | preservation-source |
| `globalview.zip` — original GV 2.1 media, archive.org `win3_globalview_21` | not fetched (UNVERIFIED) | preservation-source |
| Dwarf `dist.zip` | `67f84b77…cf75` | **BSD-3-Clause**, redistributable |
| `vp2.0.5.zdisk` (ViewPoint 2.0.5) | `02bdb53b…f872` | preservation-source (Xerox) |
| `vbesvga-release.zip` v1.0-beta4 | `e4272c94…a770f` | free/open, already manifested |

MS-DOS + Windows 3.1 inside the image are Microsoft-licensed — the same
acceptance already made for `win311`. The archive.org item carries **no explicit
rights statement**; `softwarelibrary_win3_shareware` is a collection label, not
a licence.

### 3.8 Biggest risk, and the experiment that retires it

**Risk: the working artifact is a single opaque third-party disk image** of
Xerox-copyrighted software. Unknown provenance, unauditable contents, a display
config provably un-editable by hand, locked at 640×480/16-colour with a magenta
desktop and no path to the authentic monochrome look. Building a museum golden
on that means the tile is not reproducible from a hashed input.

**One afternoon retires all of it:** clone the **existing `win311` golden**
(`qemu-img convert -U -l golden` — never open the live disk) and install
GlobalView 2.1 **from the original media** through GVWin's own Setup, choosing
display mode and workspace size at install time. Gate on one framebuffer
screenshot of the ViewPoint desktop. That single run settles provenance,
resolution, and the monochrome question at once, and proves reproducibility from
a hashed input — with the pre-built image still there as fallback if it fails.

**Worth an hour if Route A is ever revisited:** run Dwarf's
**`duchess-gvwin-color`** config — the same GVWin Mesa machine driven natively by
Dwarf, no Windows and no QEMU. If Duchess boots where Draco stalls, Routes A and
B collapse into something simpler *and* higher-resolution than either.

### 3.9 Curatorial ordering

**Ship GlobalView first.** It is the cheapest Xerox exhibit by a wide margin, the
only one driven to a working desktop, and it needs no new emulator, backend or
capture path — `scripts/build-guests/tiles/win311.sh` is the template. Estimate
**1–2 days**. Alto (ContrAlto) and Star (Darkstar) are the deeper archaeology to
follow; the three are complementary, not redundant. If only one Xerox exhibit is
ever built, this is the one achievable this month.

Evidence: `/data/vms/soltest/XEROX-viewpoint/` on the box (595 MB, inert —
screenshots `s*.png` `g*.png` `h*.png` `m*.png` `routeA/*.png`, the `golden`
overlay, the Dwarf/JRE tree). Delete when the space is wanted.

---

## Open sections

| Section | State |
|---|---|
| 1. Alto | **Complete** — feasible, one tile, cheapest experiment identified |
| 2. Star / Pilot | Research in flight; fold the report in when it lands |
| 3. Daybreak / ViewPoint | **Complete** — feasible, Tier 2, **ship this one first** |

**Recommendation across the study so far:** `gvwin` (§3) then `alto` (§1). Two
tiles, ~0.19 GB and ~1.0–1.3 GB respectively, no shared dependencies, and
neither blocks the other.

## Sources

- [Contralto2](https://github.com/jdersch/Contralto2) ·
  [ContrAlto (LCM)](https://github.com/livingcomputermuseum/ContrAlto)
- [bitsavers Alto disk images](https://bitsavers.org/bits/Xerox/Alto/disk_images/) ·
  [Alto firmware](https://bitsavers.org/bits/Xerox/Alto/firmware/)
- [CHM Xerox Alto file system archive](http://xeroxalto.computerhistory.org/index.html) ·
  [CHM Alto source code release](https://computerhistory.org/blog/xerox-alto-source-code/)
- [MAME `xerox/alto2.cpp`](https://github.com/mamedev/mame/blob/mame0276/src/mame/xerox/alto2.cpp)
- [Dwarf — Mesa emulators (Draco/Duchess)](https://github.com/devhawala/dwarf) ·
  [gvwin pre-built image](https://github.com/davidar/gvwin) ·
  [archive.org `win3_globalview_21`](https://archive.org/details/win3_globalview_21)
- Evidence from this study: `/data/vms/soltest/XEROX-alto/` on the box (1.8 GB,
  inert — delete when the space is wanted).

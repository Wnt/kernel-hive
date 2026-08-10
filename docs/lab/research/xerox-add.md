# Adding the Xerox machines: Alto, Star, Daybreak/ViewPoint

Status: **research, 2026-08-09.** Nothing is built, no registry entry exists, no
slot is claimed. This is the feasibility study
[`ADD-NEW-OS-PLAYBOOK.md`](../ADD-NEW-OS-PLAYBOOK.md) §1 expects before a
candidate enters the backlog.

Scope: Alto I, Alto II, the Star (8010 "Dandelion") / Pilot, and the Daybreak
(6085) / ViewPoint / GlobalView. **All three sections are complete.**

**Short version:** all three are feasible and none is blocked on media. Ship
**`gvwin` (§3)** first — Tier 2, 0.19 GB, no new emulator — then **`alto` (§1)**.
The **Star (§2)** is real but gated on one 30-minute speed measurement, and it
lands on the same ViewPoint desktop `gvwin` already gives you. Full reasoning in
"Recommendation across all three" at the end.

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
- ~~**Kiosk geometry trap:** QEMU `-vga std` wants a width that is a multiple of
  8, and **606 is not**. Use a `608×816` root (2 px slop, window centred).~~
  **RETRACTED — measured, and the trap does not exist.** ContrAlto's own bitmap
  width is **608**, already a multiple of 8, so a `608×808` root is exact:
  **no slop, no letterbox, no painted surround.** Proven end to end with a
  chrome-free QMP capture of the Alto Executive. The `606` figure this study
  quoted was wrong. The base `.xinitrc` still forces 1024×768, so a per-tile
  override is still needed — that part stands.
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

## 2. Star / Pilot — FEASIBLE-WITH-CAVEATS, Tier 3, gated on one speed measurement

Verdict: **the 8010 Star is buildable and was booted here** — but Darkstar runs
at only **43–65 % of real-Star speed** on this host, and upstream attributes
ViewPoint boot hangs precisely to sub-100 % speed. That single number decides
between the Star and its successor.

**The expected blocker did not materialise.** Media is settled, fetched and
hashed on the box:

| file | size | sha256 |
|---|---|---|
| `bitsavers .../8010/8010_hd_images.zip` | 14 020 559 | `d9fb1136…a438e` |
| `ViewPoint-2.0-11-9-1990-18-38.img` | 65 433 601 | `a7ead97a…f7020` |
| `XDE-5.0.img` | 65 433 601 | `e37c61ed…3e5cb887` |
| `Interlisp-D-Harmony.img` | 65 433 601 | `bb297e2c…b278766` |

Preservation class — Xerox never released ViewPoint/Pilot and there is no
licence grant. URL + hash + class only. Note the emulator repo itself **ships
Xerox bits** (Dandelion IOP PROM dumps `537P030xx.bin`, CP microcode): BSD-2 on
Dersch's code, Xerox copyright on those files. No separate ROM hunt needed.

### 2.1 Darkstar builds and runs on Debian — with two undocumented fixes

`livingcomputermuseum/Darkstar`, HEAD 2026-04-08, still maintained. **C#, .NET
Framework 4.5, WinForms + SDL2** — and the SDL surface is embedded in a WinForms
window (`SDL_CreateWindowFrom`), so **Mono's WinForms X11 driver is a hard
dependency**. `dotnet`/CoreCLR is not an option.

Built clean in a Debian container: `mono-complete 6.12` + `mono-xbuild` +
`nuget restore` → `xbuild /p:Configuration=Release` → 0 errors, 2.8 s. There is
no `msbuild` in Debian; `xbuild` works. Cost in the overlay is ~155 packages
plus `libgdiplus`.

Two fixes the builder must carry, or it dies with `DllNotFoundException`:
delete the bundled Windows `SDL2.dll`, and add `SDL2-CS.dll.config` with
`<dllmap dll="SDL2.dll" target="libSDL2-2.0.so.0"/>`.

Runs under bare `Xvfb`, no WM (one non-fatal `BadMatch` on
`SDL_CreateRenderer`, then renders fine). No GL, so llvmpipe costs ~45 % of a
core purely for blitting — the same tax a bridge tile already pays.

### 2.2 The Dec-1997 time lock is the number-one boot gotcha

Xerox **time-locked** the software ("Product Factoring"). Darkstar's readme
publishes perpetual option keys and requires the TOD clock set to **December
1997**. Confirmed empirically, and it is not subtle:

- TOD `1990-11-09` → **boot stalled at MP 7800 for >12 min**, twice.
- TOD `1997-12-01` → proceeded normally.

### 2.3 First boot is interactive — which is exactly why the golden matters

Pilot has no text console; boot progress is a 4-digit **MP code** on an emulated
front-panel LED, climbing `0910 → 7600 → 7700 → 7800 → 8000`. Then Pilot runs
the **Set Time Utility**, a teletype-style dialogue that **needs keystrokes**,
then the logged-off bouncing-keyboard screen, then the **Logon Option Sheet**.
With no XNS Clearinghouse it offers a temporary desktop → the ViewPoint desktop.

First boot: roughly **25–35 min** at ~50 % speed (upstream says 10–15 at 100 %).
**A golden baked at the logged-on desktop erases all of it** — reset returns in
seconds and no visitor ever sees Set Time or the logon. Without that, a visitor
sees a black screen and a bouncing keyboard. This is the difference between an
exhibit and a fault report.

### 2.4 Input — the macro row is not optional, and this is now proven twice

The Logon Option Sheet **cannot be completed without the NEXT key**: clicking a
field does not move the caret, and typing without NEXT concatenates everything
into `Name`. Darkstar already defines the full Star mapping (`Again F1, Delete
F2, Find F3, Copy F4, Same F5, Move F6, Open F7, Props F8 …`); Dwarf maps the
same set to `Ctrl+letter`.

So the SPA needs a **~10-button per-machine macro row** — `NEXT/SKIP`, `OPEN`,
`PROPERTIES`, `MOVE`, `COPY`, `DELETE`, `AGAIN`, `UNDO`, `STOP`, `HELP` — well
within what it already does, and **shared with §3**, which found the identical
requirement independently. Build it once.

Two input details for the SPA path: **clicks need real dwell** (a zero-dwell
click did nothing in the option sheet; `mousedown; sleep 0.4; mouseup` actuated
reliably — relevant to the tap path in `INPUT-DEBUGGING.md`), and keys landed at
120–150 ms while a burst of `Return`s dropped, so expect the §5.1
`SH_KEY_MIN_HOLD_MS`/`GAP_MS` work.

### 2.5 Display — no surprises

1024×808 visible in a 1088×860 frame, 1-bit monochrome, **landscape ≈1.26:1**;
measured window 1091×915. Draco is 1152×861. Both squarer than 4:3, so the SPA
pillarboxes slightly. **None of the Alto's portrait problem** (§1.5).

### 2.6 Cost, and the decision

| | Darkstar / Star 8010 | Draco / 6085 |
|---|---|---|
| Tier | **3** | **2–3** |
| Effort | ~2–4 days | ~1–2 days |
| RSS | **258 MB**, **96 % of one core sustained** | **338 MB**, **3.5 % of a core idle** |
| Boot | 25–35 min first boot, interactive | **~60 s**, hands-off |
| Time lock | Dec-1997 TOD dance | none (internal time service) |
| Speed | **43–65 % of real** — the risk | no real-time requirement |

### 2.7 Biggest risk, and the 30-minute experiment that retires it

**A tile that boots on a quiet box and hangs when six MAME tiles are streaming
is worse than no tile.** Upstream issue #22 is literally "Darkstar stuck booting
ViewPoint on Linux" at low CPU, and the MP 7800 stall above is consistent with
it.

**One quiesce window, ~30 min:** run the already-built Darkstar pinned with
`taskset` to an asserted-idle core pair per `MEASUREMENT-METHODOLOGY.md`, boot
ViewPoint with TOD 1997-12-01 and `AltBootMode=Rigid`, and read `Fields/Sec` off
the status bar. **≥78 f/s → risk retired, build the Star. <78 f/s → ship Draco
instead** and label it honestly as the Star's successor.

Evidence: `/data/vms/soltest/XEROX-star/` (84 MB, inert) — the hashed zip and
frames showing MP codes advancing, the Xerox Set Time Utility banner, and the
live ViewPoint desktop on Draco.

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

**CORRECTION — Draco was never stalled.** The first study reported it "parking at
MP 8000 on the bouncing-keyboard graphic" and never leaving across ~25 min and
three input strategies, and concluded Tier 3–4. The §2 study then **drove the
same emulator to a live ViewPoint desktop**, and its screenshot's status bar
reads `8000`. So:

- **MP 8000 is Pilot's normal run state, not a hang.** The bouncing keyboard is
  the *logged-off screen* — "press a key to log on". The machine was healthy and
  waiting the whole time.
- The wake key is **`Ctrl+N`** (Dwarf maps the Xerox **NEXT** key there). Ordinary
  clicks and XTEST keys do not advance it — which is also why the first study's
  "input reaches X" check was true and irrelevant: Swing took the input, Pilot
  wanted a key it never received. Dwarf's shipped default keymap is **German**,
  which makes guessing worse.
- **`-draco vp2.0.5` boots to the logged-off screen in ~60 s** with
  `autostart = true`, under bare Xvfb, no WM, software rendering — not the ~3 min
  plus indefinite stall first reported.

Revised Route A cost: **Tier 2–3**, `openjdk 21` (the readme says Java 8; 21 ran
it unchanged), **338 MB RSS and 3.5 % of a core idling at the desktop**. It still
needs a new backend shape — a JRE + Swing app in a captured-Linux bridge — but it
is no longer an unsolved research problem.

Two real caveats remain: one **unexplained JVM exit** mid-session, not reproduced
(soak test before shipping), and the disk readme's warning that shutting down
from inside ViewPoint can corrupt the disk — which a `loadvm golden` tile
sidesteps entirely.

**The lesson worth keeping: a status code you cannot read is not evidence.** An
unfamiliar idle screen held for 25 minutes read as a hang, and the fix was one
keystroke. Cross-checking two independent agents on the same emulator is what
caught it.

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
| 1. Alto | **Complete** — feasible, Tier 2, one tile |
| 2. Star / Pilot | **Complete** — Tier 3, gated on one 30-min speed measurement |
| 3. Daybreak / ViewPoint | **Complete** — feasible, Tier 2, **ship this one first** |

## Recommendation across all three

**One Pilot exhibit, not two.** §2 and §3 both end at the same ViewPoint desktop
and would look nearly identical on the wall; §3's own study reached that desktop
on §2's emulator. Pick by cost:

1. **`gvwin` (§3) — ship first.** Tier 2, **0.19 GB**, no new emulator or
   backend, `win311.sh` is the template, boot→login→golden→reset proven.
2. **`alto` (§1) — ship second.** Tier 2, ~1.0–1.3 GB, genuinely different on
   screen (the 1973 machine, portrait tube), no dependency on the others.
3. **The Star (§2) — only if the speed measurement passes.** It is the famous
   machine and the frames are real, but at 43–65 % of real speed it risks
   hanging under fleet load, and Draco reaches the same desktop in 60 s at 3.5 %
   of a core. If §2.7 fails, the Pilot slot is already filled by `gvwin`.

**Shared work, build once:** the Xerox **Level-V macro row** (NEXT, OPEN,
PROPERTIES, MOVE, COPY, DELETE, AGAIN, UNDO, STOP, HELP). §2 and §3 discovered
independently that ViewPoint is unusable without it — `Tab` is not NEXT.

## Sources

- [Contralto2](https://github.com/jdersch/Contralto2) ·
  [Darkstar (8010 Star)](https://github.com/livingcomputermuseum/Darkstar) ·
  [ContrAlto (LCM)](https://github.com/livingcomputermuseum/ContrAlto)
- [bitsavers Xerox 8010 hd images](https://bitsavers.org/bits/Xerox/8010/) ·
  [bitsavers Alto disk images](https://bitsavers.org/bits/Xerox/Alto/disk_images/) ·
  [Alto firmware](https://bitsavers.org/bits/Xerox/Alto/firmware/)
- [CHM Xerox Alto file system archive](http://xeroxalto.computerhistory.org/index.html) ·
  [CHM Alto source code release](https://computerhistory.org/blog/xerox-alto-source-code/)
- [MAME `xerox/alto2.cpp`](https://github.com/mamedev/mame/blob/mame0276/src/mame/xerox/alto2.cpp)
- [Dwarf — Mesa emulators (Draco/Duchess)](https://github.com/devhawala/dwarf) ·
  [gvwin pre-built image](https://github.com/davidar/gvwin) ·
  [archive.org `win3_globalview_21`](https://archive.org/details/win3_globalview_21)
- Evidence from this study: `/data/vms/soltest/XEROX-alto/` on the box (1.8 GB,
  inert — delete when the space is wanted).

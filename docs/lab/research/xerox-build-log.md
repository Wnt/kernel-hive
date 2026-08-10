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

_(append findings here)_

## Agent B — Star / Pilot

_(append findings here)_

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
shape of a healthy JVM rather than one heading for an OOM. Soak numbers are in
`docs/guests/daybreak.md`.

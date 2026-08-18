# Debugging pointer input — read this before touching the input path

> **In flight:** [PEN-TAP-PLAN.md](PEN-TAP-PLAN.md) holds an agreed, not-yet-
> implemented plan to move these thresholds into client space. Read it first if
> you are here about pen taps registering as drags.

Input bugs in the gallery are reported as "it feels wrong", and the cause is
almost never where it feels like it is. This is the order to look, the tools
that answer each question, and the traps that have cost real sessions.

## The trap that costs the most: which code path is this?

A press arrives on **one of three** paths, and the choice is not made by the
visitor's hardware:

| Input | Path | Where |
|---|---|---|
| Mouse | mouse/pen branch | `useStreamInput.onDown` else-branch |
| **Stylus (S-Pen)** | **mouse/pen branch** | same — `pointerType` is `'pen'` |
| Finger | touch recognizer | `useTouchGestures` → `input/touchGestures` |
| Finger/pen on a PHONE exhibit | touch recognizer | `touchExhibit` is true |

`touchExhibit` (formerly the badly-named `isTouch`) means **the exhibit is a
touchscreen device** — android, postmarketOS, Sailfish — *not* that the visitor
is on one. For that, `env.isTouchDevice()` is the real device check. The two
names are one letter apart in meaning and opposite in effect.

**A stylus on a desktop exhibit therefore does NOT reach the touch recognizer.**
Two fixes were shipped to that recognizer on 2026-08-05 and changed nothing on
win311/IRIX, because the pen was never running that code. Tap quantisation lives
in `input/touchGestures.createTapQuantiser()` precisely so both paths can share
it; the stylus path drives its own instance through `input/penContact.ts`.

## Four telemetry sources, cheapest first

**0. `ptr` pointer telemetry — the raw event stream, PUSHED.** The UI records
every pointer event (plus `contextmenu`/`auxclick`) and posts it to `/clientlog`
every ~2 s, so a reproduction is captured with the phone in a pocket and the tab
in the background. Decode it into gestures:

```bash
ssh lab 'python3 /data/vms/streamhost/serve/pen-trace.py --since-min 15'
ssh lab 'python3 .../pen-trace.py --session ab12cd34 --moves'
#   131704  down      btn=1 pt=p (188,283)
#   132303  ctxmenu   btn=0 pt=p (187,283)  +599 ms into a live contact
```

Three things it is built to show, each of which cost a round of fixes to learn:
a **contextmenu's real delay** into its contact (~0 ms = an S-Pen barrel press,
~600 ms = Android's long-press — the event's own `timeStamp` cannot tell them
apart, because Chrome copies the originating pointerdown's stamp onto the
synthesized event); an **ORPHAN** (motion carrying a button with no pointerdown,
i.e. Android ate the press); and **no-lift** (a contact never released, which is
where a stuck guest button begins).

Source: `spa/src/input/pointerRecorder.ts`, armed by default while the pen work
is open; `?penrec=0` opts out. Its in-memory rings are still readable live with
`penRecorderDump()` through the operator eval plane — that path stays for poking
at a running tab, but it needs a FOREGROUND tab to answer its poll, which is
exactly what the push removes.

Mouse rows are dropped by default; for the relative-pointer bridge add
`?ptrrec=1` (or `window.__osgPtrRec = true`): mouse rows are kept and every
absolute move datagram adds a `w` row — the mapped guest point and the wire
`cseq`, which joins row-for-row with the daemon's `[input-tel rel] cseq=`
lines under `SH_INPUT_TELEMETRY=2` (`pen-trace.py --moves` prints both).

## Three further telemetry sources, cheapest first

**1. `pen-tap` / `drag-tel` / `hover-tel` in the client log.** No setup — the UI
already writes these. This answers "what did the browser see and decide?".

```bash
ssh lab 'grep pen-tap /data/vms/streamhost/serve/clientlog.jsonl | tail -20'
#   {"btn":0,"dbl":true,"x":223,"y":183}   <- dbl:true = a double-tap was RECOGNISED
```

`drag-tel` is one line per press/release with `from`/`to`/`bbox` (raw pointer
coords, before quantisation), `raw` (samples seen) and `fwd` (samples actually
sent). **`fwd=0` with `bbox=null` means the tap was clean** — the wobble was
swallowed, which is what a tap should look like. Uploads are batched ~5 s, so a
script must wait before reading.

**2. `SH_INPUT_TELEMETRY=1` on a station.** This answers "what did the DAEMON
receive?", which is the only way to prove a client fix reached the wire.

```bash
ssh lab 'mkdir -p /etc/systemd/system/streamhost@<tile>.service.d
  printf "[Service]\nEnvironment=SH_INPUT_TELEMETRY=1\n" \
    > /etc/systemd/system/streamhost@<tile>.service.d/input-telemetry.conf
  systemctl daemon-reload && systemctl restart streamhost@<tile>'
ssh lab 'journalctl -u streamhost@<tile> -f | grep input-tel'
#   [input-tel BTN win311] DOWN btn=0 mask=0x01 atMove=11
```

A double-tap should show **four** button lines, and the `atMove` counter is the
thing to read: **each click's own DOWN and UP must share one `atMove`.** If it
advances inside a click, the guest cursor moved while the button was held — that
is a drag, not a click, and no double-click can come of it. One move between the
two clicks (the second press's reposition) is expected.

```
DOWN atMove=4244  UP 4244   DOWN 4245  UP 4245     <- healthy
DOWN atMove=4064  UP 4065   DOWN 4065  UP 4067     <- cursor moving mid-click
```

**Remove the drop-in when you are done.**

**3. The framebuffer.** `labctl shot <tile>` is the only thing that proves the
guest ACTED. A click that reaches the daemon and does nothing visible is still a
failure.

## When a station "freezes": is it even the input plane?

Run `scripts/dev/input-wedge-repro/` FIRST. It drives keys straight into QEMU
over QMP on an isolated clone, so streamhost is not in the loop: a wedge there
is the guest or the emulator, and a clean run means the fault is above QEMU.

**Probe input LIVENESS, not framebuffer motion.** A station whose picture stops
changing is ambiguous — a game can legitimately stop animating, and reading a
static framebuffer as "the freeze" is what sent the 2026-08-17 win311
investigation through four wrong theories. The probe is Ctrl+Esc, which
Windows 3.x handles BELOW the focused app (it opens the Task List) and so
repaints even when a 16-bit app is wedged. Repaint = input alive.

```bash
NS=w311frz-a1 bash scripts/dev/input-wedge-repro/clone-setup.sh   # on labhost
/data/vms/sandbox/w311frz-a1/launch.sh
python3 keywedge.py --key left            # reproduces in ~6 s / ~44 key edges
python3 keywedge.py --key a --edges 200   # CONTROL: survives (not volume)
python3 keywedge.py --idle                # CONTROL: survives (not elapsed time)
```

The win311 result was root-caused on 2026-08-17: the guest ends up running with
the CPU interrupt flag clear, so timer and keyboard IRQs sit pending forever and
the WHOLE guest stops (the Clock stops too, not just the app). Full report,
evidence and the eleven hypotheses it killed:
[`win311-interrupts-disabled-freeze.md`](win311-interrupts-disabled-freeze.md).

Use `clockprobe.py` when a station has a clock visible: a passive probe beats an
injected one, because Ctrl+Esc cannot distinguish "input is dead" from "Windows
is dead" — it needs input to work in order to answer.

## Reproducing without the hardware

For a REAL stylus there is no substitute for the device: inject
`tests/e2e-live/pen-recorder.eval.js` into the live tab through the operator
eval plane (it works from a phone — an admin passkey session authenticates the
command poll, so no console is needed) and read the raw event stream back.

`tests/e2e-live/pen-doubletap-probe.mjs` drives a synthetic **pen** double-tap
through the deployed client — the real bundle, the real wire, the real guest:

```bash
cd tests/e2e-live
node pen-doubletap-probe.mjs "Windows 3.11" 218 178      # display name, guest x y
PROBE_GAP_MS=180 PROBE_OFFSET_PX=5 node pen-doubletap-probe.mjs ...
```

It emulates a touch context, opens the station the way the live suites do (click the
`.os-card`), and dispatches `PointerEvent`s with `pointerType: 'pen'`. Caveat
worth keeping in mind: a synthetic pen is not a real one. It reproduced the
transport behaviour faithfully but not the exact wobble/timing distribution of a
hand-held stylus, so a green probe is necessary, not sufficient.

## What the guest end does to your timing

Some stations cannot be driven naively:

- **`SH_WARPD_BUTTONS=qemu` stations (win311, os2warp, templeos)** split the planes:
  buttons ride the instant PS/2 path, motion rides a warpd agent over a serial
  socket. `SH_WARPD_BUTTON_DELAY_MS` (80 ms on win311) makes the daemon *hold
  each button* until the cursor has provably caught up — and **every reposition
  re-arms that hold**. That is why a clean tap releases with NO coordinates: the
  cursor is already there, and re-sending it only held every click open ~81 ms.
  It is also why pen HOVER is muted for the double-tap window after a contact —
  moves and buttons ride separate streams, so a queued hover sample was being
  applied between the two clicks, moving the cursor off the pixel.
- **`SH_ABS_PACE_MS` / `SH_WARPD_PACE_MS`** pace absolute moves (30 ms on the old
  GUI stations) — see the 2026-07-26 drag investigation.
- **QMP `abs`/`click` does nothing on a warpd station.** The guest has no working
  absolute pointer — that is *why* it runs an agent. Verified by screenshot:
  the framebuffer is byte-identical after `cdrv.py … abs x y`. Do not use QMP to
  "check" pointer behaviour on those stations.

## Thresholds, and what they are sized against

All in `input/touchGestures.TAP`, guest pixels. Two references, not taste: what
the GUEST will accept, and how big the thing being clicked is.

| Knob | Value | Sized against |
|---|---|---|
| `tapPx` | 24 | **One icon.** Era icons are 32x32 on a ~75 px grid, so a contact that stays inside the icon it started on has not "moved" in any sense the user meant. Also near Android's 8dp touch slop. Under it nothing is forwarded and the release lands on the press point; over it, every sample flows and it is a drag. |
| `doublePx` | 32 | **One icon wide**, comfortably inside the 75 px grid pitch: two taps within it were aimed at the same icon, and a tap on the neighbour is never snapped onto it. |
| `doubleMs` | 500 | **The guests' own timers** (below). |

Rough double-click intervals the guests themselves use:

| Guest | Default |
|---|---|
| Windows 3.x - 11 (`DoubleClickSpeed`) | ~500 ms |
| macOS | ~500 ms |
| GTK (`gtk-double-click-time`) | 400 ms |
| Qt (`doubleClickInterval`) | 400 ms |
| Xt / Motif — CDE, IRIX 4Dwm | **200-250 ms** |

(Approximate, from the platform defaults rather than measured here.) Note what
this means: OUR window only decides whether to snap the second tap onto the
first. The **guest** still has to pair them with its own timer, so on a Motif
desktop a leisurely double-tap can be snapped by us and still refused there.
That is a guest-side limit the client cannot paper over — the fix there is the
guest's own mouse control panel.

Windows also enforces a double-click DISTANCE (`SM_CXDOUBLECLK`, 4 px). Snapping
both clicks onto one pixel is what satisfies that, and it is why the position
work matters more than the timing work.

Measured S-Pen reality with a **steady hand in a calm room** (win311/IRIX,
2026-08-05): taps land **4-12 px apart**, **170-210 ms** apart, each wandering
**1-5 px** while down. Those are best-case numbers — one-handed on the move,
the same gesture scatters several times as far, which is why the thresholds
above are deliberately loose rather than fitted to that data.

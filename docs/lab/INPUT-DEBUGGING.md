# Debugging pointer input — read this before touching the input path

> **Pen taps registering as drags?** That was tap quantisation, and it shipped
> in 2026-08 — [PEN-TAP-PLAN.md](PEN-TAP-PLAN.md) is the record of the completed
> change (`spa/src/input/tapQuantiser.ts`), not pending work. Read it for the
> thresholds and the measurements behind them.

Input bugs in the gallery are reported as "it feels wrong", and the cause is
almost never where it feels like it is. This is the order to look, the tools
that answer each question, and the traps that have cost real sessions.

## Check this first: is the guest awake?

**A paused guest accepts every input event and reacts to none of them.** It is
the single most common cause of "input is dead" in this lab, and until
2026-08-24 nothing anywhere said so — QEMU's monitor acks `sendkey` on stopped
vCPUs, `input-send-event` returns `{"return": {}}`, and the screendump you take
afterwards shows a screen that never changed. That is indistinguishable from a
wedged guest, and it sent several 2026-08-23 investigations after the emulator
before anyone checked `query-status`.

streamhost idle-auto-pauses **every** station 60 s after its last browser
session (`SH_IDLE_PAUSE_SECS`; only `daybreak` opts out). So any tool driving a
station with no visitor attached is, by default, driving a frozen guest.

```bash
ssh lab 'labctl health <station>'      # "QEMU state: paused (idle-paused)"
```

### What the code now guarantees

**Input is a wake, and the wake is verified.** Nothing queues an event for
later — a click replayed seconds after it was made lands at a coordinate the
client has long since moved on from, and that is the same false evidence one
layer up. Instead:

| Plane | Behaviour |
|---|---|
| Browser session (`input::handle`) | `idle::wake_for_input()` runs before every record. One relaxed atomic load on a running guest; on a paused one it `cont`s and only then injects, so the event lands on a running guest at the point it was made. |
| Browser session, wake FAILS | The record is dropped and **said out loud**: `[idle] INPUT DROPPED (#n): guest is idle-auto-paused and the wake failed`. The reconciler retries `cont` every 5 s, so it self-heals. |
| `labctl type/key/sh/exec/mctl/shot/reset` | `common.ensure_running()` resumes **and verifies** with `query-status` (or `/proc` state, on the SIGSTOP stations). A guest that will not wake is **exit 4** with a message naming the pause — never a silent fall-through. |
| `scripts/dev/qmp-type.py` | Wakes + verifies before the first key, and asserts the guest is *still* running after the last one, so the screendump it prints cannot be a picture of a guest that missed half the sequence. |
| Anything else you write | `scripts/lib/guest_wake.py` — `wake()`, `assert_running()`, `WakeLease` / `hold_lease()`. Use it. |

### The folklore this replaced

The workaround passed between agents during the 2026-08-23 wave was:

> send `cont` and your input events back-to-back on ONE QMP connection, because
> a separate `cont` followed by a separate call still loses the race

That was a real race, and it is now **fixed rather than dodged**. The daemon
re-asserts a believed pause every 60 s (`HEAL_EVERY`), which with zero sessions
landed in the *middle* of a driver's sequence and swallowed everything after it.
A driver now takes a **wake lease** — it touches
`/run/streamhost/wake/<station>.lease` (`SH_WAKE_LEASE`) while it is driving, and
the reconciler treats a fresh mtime exactly like a live visitor: it neither
pauses nor re-asserts a pause under it. `labctl` takes the lease for the
lifetime of the command; `guest_wake.WakeLease` is the context manager for
everything else.

The lease is mtime-based on purpose. A driver that dies leaves a lease that
expires by itself (`LEASE_TTL`, 90 s), so the worst case is one station running
90 s longer than it had to — **idle auto-pause is not weakened**, which matters:
it is worth about 10% of a core per station, continuously.

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

## "The pointer is perfect but clicks are wrong" — check the button allowlist

A sink can route MOTION and not route BUTTONS, and the symptom looks like
anything except that. `apply_move_abs` hands motion to whatever router exists,
unconditionally; the type=2 button branch only routes to a sink named in
`InputRouter::routes_buttons`. A backend missing from that list therefore gets
its moves through the sink's ordered queue and its clicks around it, straight
down the classic D-Bus PS/2 path — **two injectors on one guest pointer**.

The press then fires immediately, while the sink is still walking the cursor to
the point the click was aimed at (`ptr-move-step` at a time, one engine window
each). The guest sees **press-at-A, motion, release-at-B: a drag.** Links and
toolbar buttons tolerate that often enough to look healthy; an HTML form field
never takes keyboard focus from it.

**So it is reported as a keyboard bug.** aix432, 2026-08-30: "Netscape suddenly
stopped reacting to keyboard input, terminal text entry still works". Nothing
was wrong with the key path — QMP `sendkey` proved F10, Esc, Tab and Alt-F all
reached Netscape, and text typed straight into the Find dialog fine. What no
click could do any more was give a form field focus.

**The one-line check**, before anything else, on a station whose sink traces:

```sh
ssh lab 'journalctl -u streamhost@<station> --since "-1h" \
  | grep "\-trace\] tx" | sed "s/.*tx [0-9]* //" | awk "{print \$1}" | sort | uniq -c'
```

Motion verbs and no button verbs, while `[input] class stream tag=2
(mouse-button)` appears in the same log, is this bug and nothing else.
`routes_buttons_invariant_every_pointer_sink_takes_its_edges` now fails the
build for the next sink that forgets.

## The button verbs ARE there and the keyboard is still "broken" — suspect the CHECKPOINT

The section above ends "and nothing else". That was too strong, and aix432 cost
a second afternoon proving it: on 2026-08-31 the same station produced the same
operator sentence — "keyboard entry into Netscape is broken after a golden
restore" — with the button verbs present, acked, and reaching the guest. The
wire was clean. What was wrong was baked into the golden.

**The discriminator ladder**, cheapest first, and it is short:

1. **Type into a chrome widget** — a URL bar, a menu, a modal dialog. If the
   characters appear, the keys reach the app and the whole input plane is
   exonerated in one step.
2. **Click the CONTENT area, then press the app's menu key** (F10 in Netscape 4).
   No menu means the keys are no longer reaching the app AT ALL, and the thing
   that stopped them was the click — not the key path, not the sink, not the
   scancode set.
3. **Restore the PREVIOUS checkpoint into a sandbox clone and repeat.**
   `checkpoint-guard` keeps a verified byte copy of every checkpoint it replaces
   (`<disk>.cpg-bak-<stamp>`), which makes this a five-minute experiment: same
   launcher, same device set, same binaries, one variable. If the old checkpoint
   works, a RECAPTURE is the regression and no code change can fix it.

**Why a click can destroy keyboard focus and a picture cannot show it.** The
pointer converged, the click landed at the right pixel — the page's own submit
button visibly depressed while the edge was held — and the app still stopped
taking keys. Keyboard focus is X-server and toolkit state, not pixels; a
screenshot of a restored guest can look perfect and be unusable. That is the
same lesson `sunos414` taught from the other side (`SetInput: select` swallowed
every keystroke on a golden in which no window had ever been clicked), and it is
why [`checkpoint-guard`](checkpoint-guard.md)'s restore proof — "the framebuffer
moved and came back" — is not an acceptance test for an exhibit.

**Never conclude "typing works" from a chrome widget.** The 2026-08-30
investigation typed `khtest` into Netscape's Find dialog, saw it land, and
declared the key path innocent. It was innocent. The exhibit was still broken,
because the thing a visitor types into is a form field in the PAGE, and that is
a different widget under a different focus owner. Prove the widget the operator
named.

### A confirmed position is not a held one — the general property

Routing the edge to the sink is one way to make a click atomic with its
position. It is not the only one, and the fleet now has a second: `sunos414`'s
`x11warp` sink CANNOT inject an edge at all (its X server has no XTEST), so it
warps, reads the position back with `XQueryPointer`, and only then lets the edge
go down the D-Bus PS/2 path.

**A readback on its own does not buy atomicity.** Between the confirming query
and the moment the edge lands, nothing holds the pointer: a concurrent
`apply_move_abs` can be applied in that window, and the confirmation was true
when taken and false when the edge arrived — a click at the wrong place through
a check that passed. Retrying the confirmation does not help; retrying a stale
truth just re-confirms it faster. What the retry covers is a warp that has not
landed **yet**, which is a different failure.

So the question to ask of any two-channel pointer is not "did you verify?" but
**"what excludes a concurrent motion apply for the duration of confirm ->
inject?"** On `sunos414` there is a real answer: under `x11warp` the worker ARMS
on a confirmed readback and stops draining its move slot entirely until
`input.rs` signals `edge_done()` after the injection returns (bounded at 600 ms,
counted and logged if it expires). Moves keep arriving and keep updating browser
truth; they are simply not APPLIED. A sink that verifies without HOLDING has
documentation, not a guarantee.

**But be precise about what that rests on, because it is not enforced.** The
hold excludes a second motion only because motion reaches this guest through
exactly one path. Today that is true for a checkable reason —
`apply_move_abs` returns immediately after `router.try_move(...)` whenever a
router exists, so a routed station never reaches the D-Bus injection at all (on
`sunos414` that also means there is NO relative fallback: a `BackendDown` move is
dropped and counted, and the pointer stops until the guest's X server is back).
What is *not* true is that anything checks this. **Nothing in the code asserts
"no other component may move this guest's pointer."** The single-injector rule is
a convention enforced by launcher discipline and review, and every one of these
would break the exclusion silently, with the armed window still dutifully armed:

- a second sink, or a resume/reconnect path that re-homes the pointer by its own
  route rather than through the sink's queue;
- a `labctl` pointer helper, a QMP `input-send-event` / `mouse_move`, or an
  install-phase driver aimed at a live station;
- a future fallback that reroutes motion to D-Bus when the primary sink is down
  — the most likely one, because it looks like an improvement.

The failure mode is the worst kind: nothing errors, the confirmation still
passes, and the click simply lands somewhere else, occasionally. **If you add a
motion path to a station whose sink declares `VerifiedWarp`, the declaration
becomes false and no test will tell you** — the discharge table records a claim,
not a proof (see its own comment).

**Which is why the obvious repair is forbidden.** `sunos414` has no fallback: when
its X server is down the move is dropped and the pointer stops until X returns
(`on-backend-down=motion-stops` in its STAT, stated so nobody has to infer it
from a rising `backend-down` counter). Adding "reroute motion to D-Bus while the
sink is down" is the single most likely way anyone breaks the exclusion, because
it reads as an improvement. Weigh the two failures: **a pointer that visibly
stops is diagnosable in seconds; a click that occasionally lands in the wrong
place on a station reporting itself healthy is the failure this machinery exists
to prevent.** The worse-looking behaviour is the safer one. A safe version would
have to engage only when the sink is down AND no edge is armed, with an explicit
handoff rather than two live movers — a deliberate design, not a patch.

And be precise about what a success means. An ack can report ACCEPTANCE or
APPLICATION and they are not the same claim: on the mgactl wire `MOVEA` acks in
~100-200 us (accepted) while `DOWN1`/`UP1` acked at 5637 us and 35559 us,
because an edge acks when it **applies**. A sink that hands its edge to a
channel it does not own can only witness the handoff. Its telemetry must say so
rather than let a reader assume the stronger claim.

## Where a guest RIGHT button is allowed to come from

Three gestures legitimately produce one, and `input/penRightClick.contextMenuAction`
is the pure decision that guards two of those. Anything else reaching the guest
as button 2 is a bug. The last two rows are the ones that must produce nothing
extra:

| Gesture | Route | Result |
|---|---|---|
| ⊕ **Right-click badge**, then tap | `TouchControlBadge` → `recognizer.setArm` | one-shot right press/release, and it can be press-DRAG-released |
| **S-Pen barrel** during a contact (≤ `BARREL_WINDOW_MS`, 250 ms) | native `contextmenu`, `pointerType: 'pen'` | `'convert'` — the live contact becomes a right-button HOLD, released on lift |
| **S-Pen barrel** with the tip off the glass | native `contextmenu`, `pointerType: 'pen'`, nothing held | `'synth'` — a standalone right-click, held `rightHoldMs()` so Motif/CDE actually posts its menu |
| **Finger long-press** | native `contextmenu`, `pointerType: 'touch'` | `'ignore'` — nothing goes to the guest |
| Real **mouse** right-click | pointerdown(button 2); the `contextmenu` that follows is de-duped within `RIGHT_SUPPRESS_MS` | one right-click, never two |

**`pointerType` is read FIRST, and this is why.** `heldContact` in that function
is `penDownBtn.size > 0` in the caller, and a **finger contact is not in
`penDownBtn`** — the touch recognizer owns it. So a finger long-press used to
look identical to a hovering pen (`heldContact === false`), take the `'synth'`
shortcut *before* the 250 ms barrel gate was consulted, and inject a right-click
on top of the left button the recognizer was still holding — the guest saw
buttons 1+3 at once. Reported on Android at `/os/rhapsody` and fixed 2026-08-24
by giving the function the event's own `pointerType`. Do not re-derive the
pointer kind from the absence of a tracked contact; the two are not the same
question.

**The arm badge is the only touch route to a right button, deliberately.** A
gesture the OS also owns cannot be borrowed for a guest button without stealing
it from the OS, and a long-press is the OS's.

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

Four things it is built to show, each of which cost a round of fixes to learn:

- **`pt=` on a contextmenu — read this before the timing.** `p` is a pen, `t` is
  a finger, `-` is a UA that dispatched a plain MouseEvent. Chrome-Android tags
  these events with the originating pointer's type, and a finger has no barrel
  button, so `pt=t` on a `ctxmenu` row means the OS long-press and nothing else.
- **A contextmenu's real delay** into its contact, once `pt` says it is a pen:
  ~0 ms is the S-Pen barrel, ~600 ms is Android's long-press. The event's own
  `timeStamp` cannot tell them apart, because Chrome copies the originating
  pointerdown's stamp onto the synthesized event.
- An **ORPHAN** — motion carrying a button with no pointerdown, i.e. Android ate
  the press.
- **no-lift** — a contact never released, which is where a stuck guest button
  begins.

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

## The corner teleport: `ABS->REL recv=(0,0)` with a button

On a **relative-pointer station** (`PTR rel` — the daemon converts an absolute
target into PS/2 deltas), one line in the daemon log settles an entire class of
"the cursor jumped to the top-left corner" report. Turn it on with
`SH_DEBUG_INPUT=1` alongside the telemetry drop-in above:

```
[input-tel BTN rhapsody] DOWN btn=0 mask=0x01 atMove=97
[input]                  ABS->REL recv=(0,0) off=(0,0) scale=2.09 -> target=(0,0)
[input-tel rel]          rehome pin=4280 target=(0,0)
[input-tel BTN rhapsody] UP btn=0 mask=0x00 atMove=184
```

**Read it as: the CLIENT SENT (0,0).** The daemon did not decide to go to the
corner — it was told to, and the `rehome pin` line is the consequence, not the
cause. Nothing on the daemon side is implicated: the bridge honoured a target it
was given. Two things this log rules out, both of which cost a wrong theory once:

* **It is not "the tap was the first motion".** `atMove=97` says 97 move samples
  had already been delivered. The glide worked.
* **It is not the rel-bridge triggers.** `SH_REL_PACED`, `SH_REL_HOME_ON`,
  `SH_REL_QUANTUM` and `SH_POINTER` were all unset — the daemon was on defaults.

**Where a client-sent (0,0) comes from.** A button record carries the position
the edge happens at (see `spa/src/three/streamClient/inputWire.ts`), and a caller
that gives no position gets the client's last absolute one substituted. A rel
station ships every sample as a type-4 RelMotion and **never sends an absolute
position at all**, so that cache stays empty for the whole session — and an empty
cache used to read as the literal corner. `input/trackpad.ts` omits a rel
station's button coordinates on purpose; the omission was being undone one layer
below it. The fix is that an unknown position is now written as a **3-byte button
record** (type, button, down — no point, no `cseq`), which `input.rs` case 2
applies no position from, because it takes a carried point only from a record of
11 bytes or more.

So the signature is worth memorising in both directions:

| On the wire | Means |
|---|---|
| button record, 11 bytes, `x=0 y=0`, on a **rel** station | a fabricated position — the corner teleport |
| button record, 3 bytes | "click where the guest's own cursor is" — correct on a rel station |
| button record, 11 bytes, `x,y` = the sprite | correct on an **abs** station |

It fires **once** per reload or resume, not on every tap, and that is diagnostic
too: after the first one the daemon's `last_abs` IS (0,0), so the next button at
(0,0) is suppressed as a no-op move and nothing further jumps.

**Sniffing the client half.** The daemon log says what arrived; to see what the
browser sent, patch `WritableStreamDefaultWriter.prototype.write` in a Playwright
`addInitScript` before any app code runs and record every chunk. Reliable input
records arrive length-prefixed (`u16` LE, then the self-describing record), and
datagrams arrive raw, so one hook catches moves and buttons alike. Drive the
gesture with `Input.dispatchTouchEvent` over CDP — and **dismiss the touch
coachmark first** (`Got it`), or it swallows every contact and the probe reports
a silent wire.

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

## Finding the pointer in a frame, without a human looking at it

`scripts/dev/cursor-locate.py` turns a framebuffer capture into pointer
coordinates. Rule 9 says the framebuffer is the only proof a guest reacted, and
that rule is expensive the moment a check needs more than a handful of frames —
so this makes "where is the cursor" a command rather than an eyeball.

```bash
python3 scripts/dev/cursor-locate.py learn a.ppm b.ppm      # two frames, cursor moved
python3 scripts/dev/cursor-locate.py find  frame.ppm        # -> "x y glyph-id"
python3 scripts/dev/cursor-locate.py track *.ppm            # -> CSV
python3 scripts/dev/cursor-locate.py check frame.ppm 512 384 --tol 1
```

**It is an EXACT matcher, not a correlation matcher, and that is deliberate.** A
guest cursor is a hard-edged sprite with a 1-bit mask, blitted at integer
coordinates with no scaling or antialiasing, so every opaque pixel either equals
the template or this is not the sprite. The payoff is that it cannot report a
confident wrong answer: it says one position, or `NOTFOUND`, or `AMBIGUOUS`.
Evidence that quietly guesses is worse than none. It also needs only numpy and
PIL, which every box here already has, where OpenCV is not installed anywhere.

The corollary is that it must be pointed at **screendumps** (QMP `screendump`,
PPM), never at the H.264 stream — the encoder's ringing breaks the exact match
and it will honestly tell you it found nothing.

Two things to know before trusting a result:

- **It reports the sprite ORIGIN, not the pointer.** The guest draws the sprite
  at `pointer − hotspot`, and the hotspot is per-glyph software state no picture
  contains. Pass `--hotspot X,Y` when you know it (on `aix432` the engine
  reports it in `STAT`).
- **Learning assumes only the cursor moved**, which a real desktop rarely
  honours — the first attempt here drowned in 16385 changed pixels because
  Netscape repainted between frames. It says which cluster defeated it, and
  `--at X,Y` learns from a box at a position the caller already knows, which is
  the normal path on a busy exhibit.

Validated on `aix432`, the one station with an independent oracle: against the
Matrox hardware-cursor registers it located the sprite **pixel-exact (±0) in
every frame**, having never seen the registers — and returned `NOTFOUND` rather
than a wrong answer on a frame carrying a glyph it had not been taught.

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
- **QEMU's Sun mouse (sunos414) keeps a dx/dy ACCUMULATOR that drains only 127
  per sync**, so a big relative injection bleeds 127 px into *every* later event
  — including a button-only one, which walks the pointer mid-click through any
  check that already passed. Zero-valued relative events are dropped by QEMU and
  do NOT drain it; a residue needs real +/-1 events, one sync each. It never
  arises while the station runs `x11warp` (that sink sends no relative motion at
  all), only on the fallback path. Measured evidence and the exact numbers are
  in [`../guests/sunos414.md`](../guests/sunos414.md#the-sun-mouse-accumulator-a-127-pixel-trap-on-the-fallback-path).
- **That guest's Y axis is INVERTED** relative to QEMU relative input — a
  positive `dy` moves the guest pointer UP — and OpenWindows ships pointer
  acceleration `2/1` threshold `15`. Anything that reckons deltas on sunos414 is
  neither 1:1 nor sign-aligned unless it accounts for both.

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

# Rhapsody DR2 absolute pointer — writing the guest's own coordinate

**Status: implemented on branch `rhapsody-abs` (2026-08-30), not yet deployed.**
Angle `guest-ram-write` of the `rhapsody` pointer problem. This page is the
record of *why* and of how to redo the measurement; what ships is
[`docs/guests/rhapsody.md`](../guests/rhapsody.md) §pointer,
`streamhost/qemu-patches/0007-kh-ramabs-guest-ram-absolute-pointer.patch` and
the station's launcher + fixture.

Sibling records: [`NEXTSTEP-ABSOLUTE-POINTER.md`](NEXTSTEP-ABSOLUTE-POINTER.md)
(the station that won with a real tablet), and the two closed-loop stations
`irix` and `aix432` ([`docs/guests/aix432.md`](../guests/aix432.md) §"The
pointer is a closed loop").

## The result in one line

Rhapsody DR2 keeps its **own** pointer coordinate in guest RAM, so the browser's
absolute pixel is simply **written there** and published with one small relative
event — no control loop, no gain, no hotspot, no adapter change and **no golden
recapture**. Measured on a sandbox clone: the guest's coordinate equalled the
commanded pixel at **every** target, and `cursor-locate.py` matched the drawn
sprite at `err=+0,+0` with `--tol 1` at six targets including two screen edges,
two window frames and the OmniWeb page.

## Why not the two routes that already exist here

**Not a native absolute device (the `nextstep` win).** That win was Previous
emulating a SummaGraphics MM 1201 digitiser on the **NeXT's own SCC serial port
B**, driven by NeXTSTEP 3.3's `InstallTablet.app` kernel server. It is
m68k-NeXT-hardware specific and there is no such device on this machine.
Rhapsody DR2 for Intel has **no USB stack at all**, so `usb-tablet` has no
driver to bind; it has no VMware tools, so `vmmouse` is out; and Configure.app's
Pointing Device list is PS/2 / bus / serial mice — all relative. Do not re-run
this search: the NeXT lineage does not carry a tablet onto x86.

**Not a closed loop over a hardware cursor.** That needs the guest's display
driver to drive an adapter's hardware cursor and the device model to hold the
position. Even where it works it costs the hardest part of the whole exercise —
a per-glyph **hotspot**, which must be measured, and which as a guessed value
behaves as a magnet rather than a small error. It would also have meant an
adapter swap here, and an adapter swap changes the device set, which invalidates
the golden. None of that is necessary once the guest will simply tell you where
its pointer is.

## The sensor, and how it was found — redo this in about an hour

Established **entirely from outside the emulator**: no patch, no trace build, no
C. That is the point — a negative result would have cost almost nothing.

1. Clone the station under `/data/vms/sandbox/` with the SAME device set so
   `loadvm golden` restores (only the netdev backend differs: `user` instead of
   the retronet tap).
2. Place the pointer at four framebuffer-verified positions. Position it however
   you like — a diff against a reference frame with the pointer parked elsewhere
   is enough to read the sprite back.
3. At each position, stop the VM and take a full guest-physical RAM dump with
   QMP `pmemsave` (64 MB here, so four dumps is nothing).
4. Search every byte offset, in `int16`/`uint16`/`int32`/`uint32`, for an address
   where `value - observed` is the **same constant at all four positions**. A
   constant bias is exactly what a pointer coordinate looks like: the constant
   absorbs the hotspot, or is zero when the value is the pointer itself.

That search returned, with no ambiguity:

| guest-physical | what it is |
|---|---|
| **`0x0050fdac`** | `Point{int16 x, int16 y}` — the **input**. Writing it moves the pointer. |
| `0x00eae020` | an exact copy that **follows** it. Writing this one alone does nothing. |
| `0x00eaee24`…`0x00eaee46` | the cursor's damage rectangles (`x, x+16, y, y+16`) — noise for this purpose, but a useful confirmation that the sprite is 16×16. |

`0x0050fdac` holds the **pointer**, not the sprite origin: at every target it
equals the commanded pixel exactly, while the drawn sprite sits at
`pointer − hotspot` with a hotspot that is `(1,1)` for the arrow, `(3,3)` for the
Bookmarks-window glyph and `(6,1)` over the OmniWeb page. **That is the whole
argument for this route**: the hotspot is real, it is per-glyph, and it never
enters the control path.

Reading it live needs nothing special either — HMP `xp /4xb 0x0050fdac` over the
station's existing QMP socket.

## Writing it: the write is not enough, and the publish is not exact

A write alone repaints nothing. The window server redraws the cursor when an
**input event** arrives, not when memory changes — confirmed directly: after a
write, the coordinate reads the new value while the framebuffer still shows the
old position, indefinitely. So each write is followed by a **publish**: one
small relative PS/2 event, with the write pre-compensated by the delta the event
is expected to produce.

The publish is *not* deterministic, and designing around that is load-bearing.
DR2's PS/2 driver scales by ~0.478 px/unit through a fractional accumulator:

| injected units | measured pixels (40 trials each, from a written start) |
|---|---|
| 1 | alternates 1, 0, 1, 0 |
| **2** | **1 px ×38, 0 px ×2** |
| 3 | 1 px ×23, 2 px ×16, 0 px ×1 |

Two units is therefore the publish quantum, and the ~5 % that publish 0 px are
caught by **reading the coordinate back** and re-issuing the absolute write.
That is a re-issued write, not a loop step: there is no gain to get wrong and
each attempt is complete in itself. In the proof sweep four of six targets landed
in one round, one in two, one in three.

The nudge direction is chosen **away from the nearer screen edge** on each axis,
so the pre-compensated write is never off-screen and the guest's own clamp can
never eat the publish. That is what makes `(0,0)` and `(1023,767)` land exactly.

## Fail closed — the address is bound to the golden

This is the one genuinely dangerous property of the route and it is designed
against rather than commented about. `0x0050fdac` is **not** an architectural
constant, and it must not be read as one merely because it shares a `method`
name with `macos753`. That station's addresses are **architectural low-memory
globals** — properties of the machine, durable across any rebuild. This one is
a property of **one RAM snapshot**. It is fixed only because `loadvm golden` restores RAM verbatim, so it
is valid for the life of **that checkpoint** and no longer. A write to a stale
address is not a pointer bug — it is memory corruption in whatever structure now
occupies the page, and it would surface later as "the guest randomly
misbehaves", to someone who has never heard of any of this.

So `kh-ramabs` **verifies before it will write anything**:

1. the value at the address must already be a plausible on-screen point;
2. **every write is read straight back**, and a write that does not read back is
   a hard failure;
3. a probe publish (re-stating where the guest already is, so the visitor sees
   nothing) must land where it was aimed.

Step 2 is not belt-and-braces, and it is the one that is easy to leave out. A
write to unbacked guest-physical memory is **silently discarded**. Without the
read-back, the probe would then read the guest's real, untouched pointer, find it
exactly where it wanted it, and declare the address good — a false positive that
would have passed every target in the sweep below. **Proving the write landed is
the half of verification that a probe cannot supply.**

Step 3 cannot pass from a standing start either, which is the other half of the
same lesson: the probe writes a deliberately WRONG value (the target minus the
nudge), so the guest has to actively turn it into the right one. Quiescence
fails the probe rather than passing it.

Until both hold, `verified` is false, **every** `MOVEA` is refused with an error,
and `STAT` answers `pos=unknown`. Refusing is the right outcome: the station
falls back to its relative path, which is merely worse. `absolute: true` stays
earned — the read-back is in the shipped path, not only in the proof.

**Re-baking the golden requires re-deriving the address.** Redo §"The sensor"
above; it is about an hour. The address and the golden it was derived against are
recorded together in `registry/stations/rhapsody.json`
(`runtime.qemu.pointerRamAddress`), and the device's own verification failure
message says so too.

## What ships, and the install order

| piece | where |
|---|---|
| QEMU device | `streamhost/qemu-patches/0007-kh-ramabs-guest-ram-absolute-pointer.patch` → `hw/misc/kh-ramabs.c`, built into `/opt/qemu-rhapsody` |
| launcher | `-chardev socket,id=ptr0,path=$D/ptr.sock` + `-device kh-ramabs,chardev=ptr0,addr=0x0050fdac,…` |
| daemon | `SH_INPUT_BACKEND=ramabs`, `SH_RAMABS_SOCK=<dir>/ptr.sock` |
| registry | `stream.pointer.method = qemu-guestram-abswrite`, `backend = ramabs`, `absolute: true`, `spa.pointerRel: false` |

**Install order is binding**: the **QEMU binary before the launcher**
(`-device kh-ramabs` is an unknown device on an older binary and QEMU refuses to
start), and the **streamhost binary before the env fixture**
(`SH_INPUT_BACKEND=ramabs` is unknown to an older daemon).

**Rollback is two lines**: drop the `-device kh-ramabs` line from the launcher
and set `SH_INPUT_BACKEND=dbus-rel` with `SH_CURSOR_SCALE=2.09` in the fixture.

**No golden recapture.** `kh-ramabs` registers no `VMStateDescription` and models
no hardware, so it adds no section to the migration stream; the device set and
`deviceSetId` are unchanged and the golden baked 2026-08-23 still restores.

## The proof (rule 9)

Three observers at every target — **commanded**, the **sensor** (the guest's own
coordinate) and **located** (`cursor-locate.py`'s exact glyph match on a QMP
screendump). Two of your own readings agreeing is not the claim; only the
commanded target separates "consistent" from "correct".

```
  (1, 1)       screen edge - top-left        sensor=(1, 1)       PASS err=+0,+0 id=e63fa3be82bc
  (1009, 752)  screen edge - bottom-right    sensor=(1009, 752)  PASS err=+0,+0 id=e63fa3be82bc
  (482, 84)    window frame - Space Jam      sensor=(482, 84)    PASS err=+0,+0 id=e63fa3be82bc
  (155, 76)    window frame - Bookmarks      sensor=(155, 76)    PASS err=+0,+0 id=c10b0ab605bc
  (500, 400)   web content (glyph swap)      sensor=(500, 400)   PASS err=+0,+0 id=3759b1ce8de5
  (880, 650)   desktop background            sensor=(880, 650)   PASS err=+0,+0 id=98f480249409
  (1023, 767)  true corner                   sensor=(1023, 767)  sprite clipped; sensor + picture
  per-glyph hotspot: e63f STABLE (1,1) · c10b STABLE (3,3) · 3759 STABLE (6,1) · 98f4 STABLE (1,1)
```

Plus a click at a commanded pixel that visibly repaints: press/release at
`(80,127)` raised the guest home window and switched the active application —
**265 062** pixels changed, bounding box `(79,1)-(1015,673)` — and the pointer
was still at exactly `(80,127)` afterwards.

Note the hotspot table: the arrow's `(1,1)` is stable across three widely
separated targets *including both screen edges*, and the three other glyphs each
report their own stable value. That is the measurement that would have been the
hard part of a closed loop, obtained here for free and needed by nothing.

## Two traps worth keeping

- **`cursor-locate.py` rejects any placement that falls outside the frame**, so
  learning a template at a screen corner captures a *clipped* sprite, which then
  matches the full arrow everywhere and turns every later `find` into
  `AMBIGUOUS`. Learn templates only at fully-drawn positions; report the true
  corner with the sensor and a picture instead.
- **Learning the same glyph over two different backgrounds** yields two template
  ids that both match — harmless for position (they agree) but it reports as
  `AMBIGUOUS`. Build the bank incrementally and skip the learn when `find`
  already resolves the frame.

## The paused-clock hazard does not apply here, and it is worth saying why

The closed-loop stations run their engine on a `QEMU_CLOCK_VIRTUAL` window,
which does not tick while the guest is stopped — so a drain against a stopped
runstate loops forever. `rhapsody` also starts `-loadvm golden -S`, but **there
is no engine window**: `kh-ramabs` acts on the wire, and its read-back timer is
on `QEMU_CLOCK_REALTIME` with an explicit stopped-runstate branch that writes the
coordinate and waits rather than spinning. The hazard was never "the guest is
paused", it was "the engine's window is on the virtual clock".

# win311 freezes because the guest ends up with interrupts disabled

**Status: root-caused, not fixed. Reproducible in ~16 seconds.**
Filed 2026-08-17.

## Summary

Sustained keyboard input to Windows 3.11 leaves the guest running with the CPU
interrupt flag (`IF`) clear and never re-enabled. The timer and keyboard IRQs
sit pending forever, so the whole guest stops responding while QEMU happily
keeps executing instructions. Only restoring CPU state (`loadvm`) recovers it.

It is **not** a streaming fault. The repro drives keys straight into QEMU over
QMP, with streamhost entirely out of the path.

## What the operator sees

A station that "freezes mid-game". Specifically:

- The picture stops dead — no stutter, no gradual slowdown, just a clean stop.
- Mouse cursor frozen, keyboard dead, every app frozen at once.
- The exhibit looks alive: no crash, no error, the VM is still "running".
- **"Restore to golden" fixes it**, and sometimes has to be done twice, because
  a restore that lands while the fault is being re-triggered comes back dead.
- Easiest to hit in SkiFree, because it is played by holding direction keys and
  therefore generates far more key edges per minute than typing does.

## Reproduce it

Tools live in [`scripts/dev/input-wedge-repro/`](../../scripts/dev/input-wedge-repro/).
Everything runs on labhost.

### On an isolated clone (preferred — never experiment on a live station)

```bash
NS=w311frz-a1 bash scripts/dev/input-wedge-repro/clone-setup.sh
/data/vms/soltest/w311frz-a1/launch.sh

python3 keywedge.py --key left      # start screen: wedges in ~44 key edges, ~6 s
python3 midgame.py                  # mid-run: wedges in ~70-110 key edges
```

`keywedge.py` bakes a `skifree` snapshot on first run so every trial starts from
an identical state; `midgame.py` bakes `skifree-mid`, a run already in progress.

### On a station with the Clock open beside SkiFree

This is the highest-quality probe and the one that identified the fault. Open
**Clock** (Main group) and **SkiFree** (Gallery Games) side by side, dragging
SkiFree right so the two do not overlap, then:

```bash
python3 clockprobe.py --calibrate    # confirm both regions are being read
python3 clockprobe.py                # drives kp_4/kp_1/kp_2/kp_3/kp_6
```

Recover with `labctl reset <station>`.

## Why the Clock matters

Every other liveness check in this directory **injects** a key and asks whether
the screen reacts. That is circular when the question under test is whether
input works at all: "input is dead" and "Windows is dead" produce an identical
answer, and reading a static framebuffer as "the freeze" is what produced four
successive wrong theories during the investigation.

The Clock is **passive**. Its display advances with no input whatsoever, so
hashing the clock face answers "is Windows still scheduling and painting?"
independently of "does the keyboard still arrive?". Read alongside SkiFree's own
`Dist`/`Speed` counters (the clock inside SkiFree stays `0:00:00.00` in
free-style — do not rely on it), the two regions separate three states:

| clock | SkiFree HUD | meaning |
|---|---|---|
| ticking | advancing | healthy |
| ticking | frozen | the app is wedged, Windows is alive |
| **frozen** | **frozen** | **this bug** — the guest is wedged |

## Evidence

From the live station, 85 key edges of `kp_4 kp_1 kp_2 kp_3 kp_6` (~16 s):

```
game stopped advancing after 85 key edges
  vm_running=True   clock_still_ticking=False
```

Then, from the wedged guest versus a healthy one:

| | wedged | healthy |
|---|---|---|
| `pic0` IRR | **`03`** — IRQ0 (timer) + IRQ1 (keyboard) pending | `00` — serviced promptly |
| `pic0` ISR | `00` — nothing in service, **no missing EOI** | `00` |
| `pic0` IMR | `88` — IRQ0/IRQ1 **not masked** | `88` |
| `EFL` IF bit | **clear in 10/10 samples** | set in 4/10 samples |
| `EIP` / `CS` | advancing through varied 16-bit ring-3 code | advancing |
| `query-status` | `running: true` | `running: true` |

Two unmasked interrupts pending, nothing blocking them at the PIC, and the CPU
never takes them — because `IF` is clear and stays clear.

That single fact accounts for every symptom simultaneously: clock frozen (no
timer IRQ), game frozen (no timer IRQ), keyboard dead (IRQ1 pending forever),
mouse cursor frozen, VM still executing, and `loadvm` curing it because the
snapshot restores a CPU state whose `IF` is set.

## Ruled out, with the evidence that ruled it out

| Hypothesis | Killed by |
|---|---|
| Streaming / encoder / ABR | QMP framebuffer grabs are pixel-identical to the browser; repro drives QMP directly with streamhost out of the path |
| Idle auto-pause | no `[idle]` event during the freeze; `query-status` says `running` |
| CPU starvation from host load | starvation degrades gradually; this stops cleanly, and the guest keeps executing |
| A wedged 16-bit app holding the Win3.x input queue | the **Clock stops too**, so it is not confined to one app |
| Mouse / warpd path | SkiFree is keyboard-driven, and the keyboard dies too |
| Key VOLUME | 200 edges of `a` (a key SkiFree ignores) survives; 44 edges of `left` wedges |
| Elapsed time | idle control with zero keys survives the same wall-clock |
| Extended (0xE0) scancodes | `kp_4` is not extended and wedges; `home` is extended, not an arrow, and wedges |
| A lost key-up / stuck key | holding `left` for 6 s mid-game keeps animating; wedge still occurs with clean down/up pairs |
| streamhost key pacing | `SH_KEY_MIN_HOLD_MS`/`GAP_MS` are both 0 for win311, so the pacing path is inert |
| The probe being wrong | Ctrl+Esc via `send-key`, via `input-send-event`, and Alt+Tab all fail, against a baseline where all three work |
| Recovering on its own | still dead after 98 s of probing |

## Open question

**Who clears `IF` and never restores it?** Two candidates, not yet separated:

1. **Guest-side** — a Windows 3.11 keyboard ISR path that executes `CLI` and
   loses its `STI` under input pressure. A 30-year-old bug we are only now
   driving hard enough to hit.
2. **Emulator-side** — TCG mis-restoring `IF` around interrupt delivery. This
   would make it a QEMU fault, and would fit the operator's report that the
   station behaved fine about a week before 2026-08-17.

The cheap discriminator for (2) is to run the same repro against a different
QEMU build. Both live entirely in clone territory.

Also untested: whether streamhost's key path makes the fault easier or harder to
hit. The harness deliberately bypasses it, so it makes no claim either way.

## Related

- [`INPUT-DEBUGGING.md`](INPUT-DEBUGGING.md) — which input path a press takes,
  and the telemetry sources
- [`STREAM-DEBUGGING.md`](STREAM-DEBUGGING.md) — for the other class of
  "it froze" report, where the fault really is in the streaming plane

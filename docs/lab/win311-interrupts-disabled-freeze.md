# win311 freezes because the guest ends up with interrupts disabled

**Status: root-caused, not fixed. Reproducible in ~16 seconds.**
Filed 2026-08-17.

## Steps to reproduce

Tools: [`scripts/dev/input-wedge-repro/`](../../scripts/dev/input-wedge-repro/).
All commands run on labhost.

```bash
# 1. Stand up an isolated clone (never experiment on a live station).
NS=w311frz-a1 bash scripts/dev/input-wedge-repro/clone-setup.sh
/data/vms/soltest/w311frz-a1/launch.sh

# 2. Launch SkiFree and hammer its direction keys, watching CPU interrupt state.
cd scripts/dev/input-wedge-repro
python3 irqprobe.py --qmp /data/vms/soltest/w311frz-a1/qmp.sock --launch
```

`irqprobe.py` opens SkiFree from the Program Manager scene, starts a run, then
sends held `kp_4 / kp_1 / kp_2 / kp_3 / kp_6` edges — the keys the game is
actually played with — and after each round samples `EFLAGS.IF` and the 8259.

By hand, the same thing: open the station, start SkiFree, and hold/release the
numpad direction keys for ~15 seconds.

### What should happen

The guest keeps running. The skier turns with each key, `Dist` and `Speed`
advance in SkiFree's HUD, the Clock keeps ticking, and the desktop stays
responsive. `EFLAGS.IF` is set in some samples and `pic0 irr` settles to `00`
as interrupts are serviced.

### What happens instead

After **~60–110 key edges (about 16 seconds)** everything in the guest stops at
once:

- the picture freezes — no stutter, no gradual slowdown, a clean stop
- the mouse cursor stops moving, and **every** key is ignored from then on
- the Clock stops too, so it is not confined to SkiFree
- QEMU keeps executing: `query-status` says `running`, `EIP`/`CS` keep advancing
- it never recovers on its own (still dead after 98 s of probing)
- **`labctl reset <station>` is the only fix** — and sometimes has to be run
  twice, because a restore landing while the fault is re-triggered comes back
  dead

```
[COLD] baseline: IF set 5/8, pic0 irr=01, wedged=False
[COLD] round  1:   61 edges -> IF 0/8, irr=03, wedged=True
[COLD] vm_running=True
```

## Root cause

The guest ends up executing with the CPU interrupt flag (`IF`) clear and never
re-enables it. The timer and keyboard IRQs are raised, unmasked and never taken.

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

That single fact accounts for every symptom at once: clock frozen and game
frozen (no timer IRQ), keyboard dead (IRQ1 pending forever), mouse cursor
frozen, VM still executing, and `loadvm` curing it because the snapshot restores
a CPU state whose `IF` is set.

**It is not a streaming fault.** The repro drives keys straight into QEMU over
QMP, with streamhost entirely out of the path.

## How to measure it

Use `irqprobe.py`. It reads the fault itself and needs no scene, no app layout,
no snapshot and no injected key, so it works on a cold-booted guest:

    wedged  ->  EFLAGS.IF clear in EVERY sample, AND pic0 IRR non-zero
    healthy ->  IF set in some samples, IRR settles to 0

The pixel-based probes in this directory came first and are weaker, for reasons
worth knowing before writing another one:

- **A static framebuffer is not a freeze.** A game can legitimately stop
  animating — a skier who crashed, an idle app. Hashing the whole screen
  conflates that with a wedge. `midgame.py` hashes SkiFree's HUD instead, whose
  `Dist`/`Speed` advance only while the game logic runs. (Its `Time` stays
  `0:00:00.00` in free-style — do not use the clock inside SkiFree.)
- **An injected liveness probe is circular.** Ctrl+Esc asks "does input work?"
  by using input, so "input is dead" and "Windows is dead" give the same answer.
- **A passive probe fixes that.** `clockprobe.py` puts the Windows **Clock**
  beside SkiFree: it advances with no input at all, so it answers "is Windows
  alive?" independently. That is what showed the clock stops too, retiring the
  theory that one wedged 16-bit app was holding the Windows 3.x input queue.

## Ruled out, with the evidence that ruled it out

| Hypothesis | Killed by |
|---|---|
| **The golden vmstate carries the fault** | a **cold-booted** guest (`COLD=1 launch.sh`, no `loadvm`) wedges identically — 61 edges, `IF 0/8`, `irr=03` — confirmed across two power-cycles and two seeds. Re-baking the golden would not fix this. |
| Streaming / encoder / ABR | QMP framebuffer grabs are pixel-identical to the browser; the repro drives QMP directly with streamhost out of the path |
| Idle auto-pause | no `[idle]` event during the freeze; `query-status` says `running` |
| CPU starvation from host load | starvation degrades gradually; this stops cleanly, and the guest keeps executing |
| A wedged 16-bit app holding the Win3.x input queue | the **Clock stops too**, so it is not confined to one app |
| Mouse / warpd path | SkiFree is keyboard-driven, and the keyboard dies too |
| Key VOLUME | 200 edges of `a` (a key SkiFree ignores) survives; 44 edges of `left` wedges |
| Elapsed time | idle control with zero keys survives the same wall-clock |
| Extended (0xE0) scancodes | `kp_4` is not extended and wedges; `home` is extended, not an arrow, and wedges |
| A lost key-up / stuck key | holding `left` for 6 s mid-game keeps animating; the wedge still occurs with clean down/up pairs |
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
QEMU build. That lives entirely in clone territory.

Also untested: whether streamhost's key path makes the fault easier or harder to
hit. The harness bypasses it deliberately, so it makes no claim either way.

## Other reproduction modes

```bash
python3 keywedge.py --key left      # start screen: ~44 key edges, ~6 s
python3 keywedge.py --key a --edges 200   # CONTROL: survives (not volume)
python3 keywedge.py --idle                # CONTROL: survives (not elapsed time)
python3 midgame.py                  # from a run already in progress
python3 clockprobe.py --calibrate   # Clock+SkiFree layout, passive probe
```

`keywedge.py` bakes a `skifree` start snapshot on first run and `midgame.py` a
`skifree-mid` one, so trials start from identical state.

## Related

- [`INPUT-DEBUGGING.md`](INPUT-DEBUGGING.md) — which input path a press takes,
  and the telemetry sources
- [`STREAM-DEBUGGING.md`](STREAM-DEBUGGING.md) — for the other class of
  "it froze" report, where the fault really is in the streaming plane

# win311 freezes because the guest ends up with interrupts disabled

**Status: FIXED 2026-08-17** — the win311 station boots a patched SeaBIOS
(`-bios /data/vms/streamhost/firmware/bios-256k-int16if.bin`) and its golden
was re-baked on it. Stock ROM: wedges at 61 key edges every run; patched ROM:
915 + 732 + 366 edges across three seeds without a wedge, idle CPU unchanged.
The [Root cause](#root-cause) section below is the ring-3 fingerprint that was
filed first; [Who clears IF](#who-clears-if--the-answer) is the answer, and
[The fix](#the-fix) is what shipped. Filed 2026-08-17.

## Steps to reproduce

Tools: [`scripts/dev/input-wedge-repro/`](../../scripts/dev/input-wedge-repro/).
All commands run on labhost.

```bash
# 1. Stand up an isolated clone (never experiment on a live station).
NS=w311frz-a1 bash scripts/dev/input-wedge-repro/clone-setup.sh
/data/vms/sandbox/w311frz-a1/launch.sh

# 2. Launch SkiFree and hammer its direction keys, watching CPU interrupt state.
cd scripts/dev/input-wedge-repro
python3 irqprobe.py --qmp /data/vms/sandbox/w311frz-a1/qmp.sock --launch
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

## Who clears IF — the answer

Neither of the two candidates the report named. It is a **BIOS-contract
mismatch between SeaBIOS and the IBM AT BIOS**, hit through DOS **POWER.EXE**,
which the rtts WfW 3.11 base loads from `CONFIG.SYS` for CPU idling.

Read straight off `-d int,exec,cpu -dfilter 0x0..0x100000` on a wedging clone
(the "IF=0 at VMM's V86 breakpoint" event happened 26 times in one 20 s run;
each time it recovered only if a timer IRQ happened to land while the VMM was
in ring 0, and the last one did not):

1. On a key edge WfW's keyboard driver (`01b7:06d8`) polls the BIOS type-ahead
   buffer: `INT 30h` → VMM → **`Exec_Int 16h, AH=01h`** into the System VM's
   V86 half. The VMM enters V86 with **IF=0**, as a real INT would.
2. POWER.EXE hooks INT 16h to detect idle polling (`02c1:06a8`, checks
   `AH=01/11`). Its idle path (`02c1:06e5`) chains the BIOS through a stub
   `pushf; call far [old16]` (`03aa:01e4`) — **IF is still 0 at that pushf**.
3. **SeaBIOS** (`src/kbd.c`, `dequeue_key`) sets ZF in the saved frame and
   returns via `iretw`, i.e. **with the pushed IF (0)**. The **IBM AT BIOS**
   executes `STI` on entry and returns from the check-keystroke functions with
   `RET 2`, i.e. **always IF=1**. That is the contract DOS TSRs were written
   against.
4. POWER then does `pushf` (IF=0) … `cli; read PIT; sti` … `popf` (IF back to 0)
   … **`retf 2`** (`02c1:0720`) — the standard "return my flags, not the
   caller's" idiom, which hands ZF *and IF=0* to the VMM's V86 breakpoint
   (`fe4e:1637`, `EFL=00023042` in the log; the healthy path — same poll, POWER
   deciding *not* idle — arrives with `EFL=0002324x`).
5. `Exec_Int` semantics: the client flags come back to the caller. The VMM
   returns to the protected-mode ring-3 keyboard driver with **IF=0**
   (`01df:6f9a EFL=00000046`). Ring 3 runs at IOPL=0, so no ring-3 code can set
   IF (`popf` silently ignores it; `sti` traps to the VMM, which only sets IF if
   its virtual IF says so, and it now says 0).
6. Anything that re-enters the VMM (an idle `INT 2Fh`, a trapped `cli/sti`
   pair) opens a window in which a pending timer IRQ gets serviced and IF comes
   back — which is why Notepad-scale use survives. **SkiFree runs a
   `PeekMessage` loop and never yields**, so once IF is 0 nothing traps, nothing
   is serviced, and the fingerprint above is permanent.

Why the "worked a week ago" report does not contradict this: the fault needs
POWER's *idle* branch to be taken during a keyboard poll (26 of ~5000 polls in
the trace), *and* the foreground app to be non-yielding. Type in Notepad all
day and it self-heals within a tick.

Why not simply drop POWER.EXE: it is what makes the station idle at ~35 % of a
core instead of 100 % (measured on cold-booted clones: no `POWER.EXE` → 100 %,
`POWER STD` → 100 %, `POWER ADV` → 34–36 %). WfW 3.11's VMM does not HLT on its
own; POWER's `INT 2Fh/1680h` hook → APM CPU-idle is the only idle path.

## The fix

**Make SeaBIOS honour the AT BIOS contract for INT 16h/AH=01h,11h**: set
`F_IF` in the returned flags for the non-blocking dequeue. One hunk:
[`streamhost/qemu-patches/seabios/0001-kbd-check-keystroke-returns-with-interrupts-enabled.patch`](../../streamhost/qemu-patches/seabios/0001-kbd-check-keystroke-returns-with-interrupts-enabled.patch),
against SeaBIOS `rel-1.17.0` (the exact release pve-qemu-kvm ships prebuilt as
`/usr/share/kvm/bios-256k.bin`), built with QEMU's `roms/config.seabios-256k`.

- Build + install: `scripts/provision/build-seabios-int16if.sh` (on labhost) →
  `/data/vms/streamhost/firmware/bios-256k-int16if.bin` + `.sha256` +
  `.provenance.txt`.
- Launcher: `streamhost/stations/win311/qemu-streamhost.sh` passes
  `-bios $BIOS` and refuses to start without the file; registry device ledger
  carries the `-bios $BIOS` row (`registry/stations/win311.json`).
- Builder: `scripts/build-guests/tiles/win311.sh` bakes its golden on the
  patched ROM and refuses to bake without it.
- Repro tool: `clone-setup.sh` mirrors the live `-bios`; `BIOS=stock` boots
  QEMU's own ROM and reproduces the freeze again.

**Gotcha that will bite the next firmware change: the ROM bytes are part of
the vmstate.** `pc.bios` is a RAM block, so `-loadvm golden` of a golden baked
on the stock ROM restores the *stock* ROM whatever `-bios` says — measured: the
guest's F-segment matched the stock image byte-for-byte (minus runtime
variables) under `-bios <patched> -loadvm golden`. So the golden was re-baked
from a **cold boot** on a clone with the production launcher, cursor parked at
the old golden's position through the serial agent (`M 337 290`), scene proved
pixel-identical to the previous golden before `savevm`, then the two disks were
swapped into the station dir (`*.bak-stockbios-20260817T161217Z` are the
rollback). `scripts/lib/checkpoint-verify.sh --capture` would NOT have done
this — its recapture path loads the existing golden as the seed and would have
carried the old ROM along.

Acceptance, all on the freshly baked golden restored via the production
launcher: `irqprobe.py --launch --rounds 6 --seed 11` → 366 edges, never wedged;
dirty (SkiFree running) → `loadvm golden` → pixel-identical to the previous
golden; guest F-segment matches the patched image; live station after
`labctl reset win311`: `running`, IF set 6/8, `irr=00`, scene identical.

Upstream: the patch is written to be sent to SeaBIOS as-is (the same chain
would leave a real-mode DOS program with IF=0 after any INT 16h poll that took
POWER's idle branch — it survives there only because SeaBIOS's own `yield()`
opens an `sti; nop; cli` window on the *next* poll).

Still untested, and now moot for this bug: whether streamhost's key path makes
the fault easier or harder to hit.

## Other reproduction modes

All of these need `BIOS=stock` on the clone's `launch.sh` now (and `COLD=1`, or
a golden baked on the stock ROM — see the vmstate gotcha above); on the patched
ROM they survive.

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

- [`../../streamhost/qemu-patches/seabios/`](../../streamhost/qemu-patches/seabios/)
  — the SeaBIOS patch; `scripts/provision/build-seabios-int16if.sh` builds and
  installs it
- [`INPUT-DEBUGGING.md`](INPUT-DEBUGGING.md) — which input path a press takes,
  and the telemetry sources
- [`STREAM-DEBUGGING.md`](STREAM-DEBUGGING.md) — for the other class of
  "it froze" report, where the fault really is in the streaming plane

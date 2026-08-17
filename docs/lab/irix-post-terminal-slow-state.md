# Does the IRIX exhibit stay slow after a visitor uses a terminal?

**No. Measured 2026-08-03: it does not reproduce.** The ASID + `tlbwi` storm is
real, but it is strictly concurrent with a terminal that is *drawing*. It ends
inside the first 90-second window after the drawing stops, it does not come back
when a terminal is merely open on the desktop, and thirteen further minutes of
idle read exactly like a desktop that had never seen one.

## Why this was worth a workstream of its own

An earlier campaign reported that after a terminal had been used the guest sat at
147,000–166,000 ASID-change + `tlbwi` events per **emulated** second — higher
than during the scroll itself — while IRIX's own `sar` called the machine idle,
holding roughly 42% instead of 85% for ten minutes or more. It was never seen on
a freshly parked desktop (35–80 events/s there).

Had that been real it would not have been one more optimisation candidate; it
would have invalidated the measurements. Every speed number on this exhibit,
including the 2026-08-03 baseline, is taken on a desktop parked minutes earlier
and never touched — i.e. on the *fast* state. An exhibit that spends its visitor
hours 2x slower than the state we benchmark is being tuned at the wrong
operating point. So the question was "is it real, and what is it", not "how do we
fix it".

## What was measured

Four runs, all on the shipped binary (`0db27300…`) and, except where noted, the
shipped seed `irix65-apps-v3.chd`, with the production flag set (`-video none`
+ shm publish, `-sound none`, `-frameskip 6`, the shipped `irixagent.lua`) plus
`-nothrottle` and one console getty line. Windows are cut **within** each run
from that run's own emulated-time trace; nothing is differenced across runs.

| run | pair | what it is |
|---|---|---|
| r1 | 3,11 | **null control.** No terminal is ever started. Eleven windows over 17 minutes. (Seed `v3-serial`, `f8c67f03…`.) |
| r5 | 6,14 | scroll, then the terminal is **killed**; eight idle windows over ~13 minutes |
| r6 | 3,11 | same, and after `post4` an xwsh is **reopened and left idle** on the desktop for `post5`–`post8` |
| r2/r3/r4 | — | discarded before any window was believed; see "three ways this rig lied" |

Each window is measured twice back to back: a **speed** sub-window with nothing
attached, then a 30 s **census** sub-window with kernel uprobes counting the
guest's ASID changes and TLB writes. Separate, because a uprobe is a trap per
hit — at 40k hits/s that is a few percent of host time, and a speed figure taken
while probing is a measurement of the probes.

### r5 — terminal killed after the scroll

| window | cycnorm% | GHz | IPC | foreign% | asid/emu-s | tlbwi/emu-s |
|---|---|---|---|---|---|---|
| pre1 | 118.03 | 2.485 | 1.381 | 7.8 | 53 | 59 |
| pre2 | 134.41 | 2.492 | 1.380 | 8.1 | 51 | 56 |
| **scroll** | **42.12** | 2.491 | 1.856 | 8.3 | **25 855** | **27 953** |
| post1 | 91.21 | 2.469 | 0.935 | 104.8 | 52 | 59 |
| post2 | 90.75 | 2.471 | 0.935 | 104.8 | 51 | 57 |
| post3 | 90.70 | 2.493 | 0.932 | 101.3 | 52 | 58 |
| post4 | 90.89 | 2.494 | 0.935 | 101.4 | 52 | 58 |
| post5 | 90.99 | 2.494 | 0.936 | 104.8 | 51 | 57 |
| post6 | 91.37 | 2.493 | 0.938 | 104.1 | 51 | 57 |
| post7 | 123.19 | 2.477 | 1.259 | 21.2 | 78 | 87 |
| post8 | 104.68 | 2.477 | 1.074 | 51.6 | 51 | 57 |

### r6 — terminal reopened and left idle from post5

| window | cycnorm% | GHz | IPC | foreign% | asid/emu-s | tlbwi/emu-s |
|---|---|---|---|---|---|---|
| pre1 | 116.58 | 2.485 | 1.381 | 7.7 | 51 | 57 |
| pre2 | 136.51 | 2.490 | 1.398 | 9.9 | 51 | 56 |
| **scroll** | **36.00** | 2.472 | 1.608 | 23.9 | **25 187** | **27 286** |
| post1 | 132.18 | 2.476 | 1.358 | 11.6 | 51 | 57 |
| post2 | 130.05 | 2.482 | 1.336 | 15.6 | 85 | 96 |
| post3 | 128.39 | 2.479 | 1.316 | 13.0 | 51 | 57 |
| post4 | 129.73 | 2.483 | 1.328 | 11.2 | 52 | 58 |
| post5 † | 128.22 | 2.484 | 1.341 | 13.6 | 52 | 58 |
| post6 † | 116.69 | 2.462 | 1.195 | 22.3 | 52 | 58 |
| post7 † | 118.59 | 2.471 | 1.216 | 27.9 | 51 | 57 |
| post8 † | 125.43 | 2.483 | 1.287 | 12.1 | 51 | 57 |

† an 80x40 xwsh open on the desktop, its shell asleep. Injected at 21:07:30,
between `post4` and `post5`, and photographed in `shot-post6.png`.

### r1 — the null control

Eleven windows, no terminal ever: `asid` 51–53/emu-s and `tlbwi` 57–59/emu-s
throughout, one 81/91 excursion. cycnorm wandered between 92.03% and 132.38% at
a rock-steady 2.45–2.49 GHz — driven entirely by `foreign%`, which ran from 7.1
to 106.7. That control is the single most useful row in this document: see
"what the original observation probably was".

## What the storm actually is

It is a terminal *drawing*, and nothing else. Guest-PC sampling (the Lua
sampler, ~50 Hz, mapped through the guest symbol table the `guest-pchist`
campaign pulled out of the guest) gives, for r6:

| window | guest image mix | top routines |
|---|---|---|
| pre2 | kernel 100% | `idler` 33.3%, `idle` 33.1%, `idlerunq` 32.6% |
| scroll | kernel 50.7%, libX11 24.9%, Xsgi 15.5%, `fm` 4.9% | `_XTranslateKey` 11.5%, `rex3PolyGlyphBltP4C` 10.4% |
| post1 | kernel 94.3%, libX11 2.8%, Xsgi 1.7% | the three idle-loop routines, 90.5% between them |
| post6 † | kernel 99.95% | the three idle-loop routines, 98.5% between them |

The scroll window is an X client and an X server taking turns: `xwsh` writes,
`Xsgi` blits glyphs (`rex3PolyGlyphBltP4C`), and IRIX switches between them
thousands of times a second. **Every one of those context switches is an ASID
change**, and MAME's `mips3com_asid_changed` answers each by walking all 48 TLB
entries and calling `tlb_map_entry` on every non-global one, which is up to 96
`vtlb_load` calls rewriting the software page table. That is the amplifier the
brief asked about, and it is genuinely there in the code
(`src/devices/cpu/mips/mips3com.cpp:63`).

**But it is not what makes the scroll slow.** From the r5 numbers: an emulated
second costs 1.85e9 host cycles at the 135% idle rate and 5.95e9 at the 42%
scroll rate, so the scroll adds ~4.1e9 cycles per emulated second. Spread over
the 53,808 asid+tlbwi events measured in the same regime, each event would have
to cost ~76,000 cycles to account for it. A 48-iteration loop does not cost
76,000 cycles. The events are a **marker** of the terminal drawing, not its
price; the price is in the glyph blits and the Newport MMIO behind them. Anyone
proposing to optimise `mips3com_asid_changed` should size it against that
arithmetic first.

## What the original observation probably was

Two things, and the evidence for each is in this repo.

1. **The "idle" windows were not idle.** The campaign that produced the
   147k–166k figure drove its arms through a telnet session that
   `v100-terminal-draw-cost/arm.sh` deliberately holds open for the whole
   measurement window — its own comment says so, and says a scroll window with
   no terminal reads 82%. Its `idle` arm is a *held login session*, not a parked
   desktop. "A terminal was used" and "a session is open" were never separated
   in that data. This rig separates them: the control channel is a console getty
   and the terminal is a background job, so the post windows have no session in
   them at all — and r6 shows that even a real terminal *window*, open and
   visible, costs nothing while it is not drawing.
2. **The speed metric was reading host contention.** r1 moved 92% ↔ 132% with
   nothing changing inside the guest, purely with `foreign%` on the claimed core
   pair; r5's post windows sat at 90.7–91.4% at `foreign%` ≈ 104 and jumped to
   123% the moment the pair cleared. The earlier campaign's results.jsonl
   records `load0`/`load1` of 7–14 on every one of its slow "idle" rows. An
   85% → 42% drop is well inside what a busy SMT sibling does to this emulator
   (the standing figure is 39%) without any guest-side state at all.

The `sar`-says-idle part of the report is consistent with both: the guest *was*
idle. So was ours — `uptime` inside the guest read `load average: 0.00` in every
post window.

## Three ways this rig lied before it told the truth

Recorded because each one produced a plausible, wrong run, and the next person
to drive this guest over a serial console will hit all three.

1. **The v3-serial seed's in-guest exec agent does not answer.** `irixexec.py`
   times out on `PING` on `/dev/pts/*` for that image. The console getty on
   `/dev/ttyd1` (`-ioc2:rs232b pty`) does answer, on the *shipped* v3 seed,
   which is strictly better fidelity anyway.
2. **The emulated IOC2 UART drops characters on a whole-line write.**
   `PATH=/usr/bin:/usr/sbin:...` arrived in the guest as
   `PATH/u/b:/usr/bi/sn:sr/bsd/u/e:$TH` and the shell answered `not found`.
   Short lines (`root`) survive, which is why the capture channel never hit it.
   The fix is a 20 ms per-character gap (`CSEND_GAP`). Note the two directions
   fail differently: with pacing, **input is clean and output is still lossy**,
   so commands are reliable and their captured output is not — which is why
   every claim here is backed by a framebuffer screendump rather than by console
   text.
3. **root's login shell on this image is csh.** Every line of the workload is
   Bourne: `DISPLAY=:0.0 cmd` is a syntax error there and `>/dev/null 2>&1` is
   an "Ambiguous output redirect". Both fail *quietly* from the rig's side — the
   first run past this point measured a bare idle desktop and labelled it
   `scroll`. `slowrig.sh` now sends `exec /bin/sh` before anything else, and the
   scroll windows are screendumped so a missing terminal cannot pass unnoticed.

Two further rig defects were found and fixed: the uprobe event group has to be
per-run (two concurrent runs share one binary inode, and a shared group name
makes the second run's install fail with `EEXIST` and either run's teardown
silently disarm the other's), and `cmd_stop` has to re-derive that group or it
disarms nothing.

## What this means for the rest of the campaign

- **The baseline stands.** Idle-desktop measurements are not measuring an
  unrepresentative state; there is no second, slower steady state to correct
  them against.
- **`foreign%` is not optional.** The one number that moved speed by 40 points
  in these runs was occupancy of the claimed core pair. Any A/B that does not
  assert it is not a measurement.
- **Nothing to fix, so nothing was changed in the emulator or the station.** The
  live station service stayed stopped throughout; `/data/vms/streamhost/` was read
  only to this work.

Evidence, raw: `/data/vms/sandbox/slowstate-7c1d/run/{r1,r5,r6}/` — `perf.csv`,
`trace.txt`, `phases.txt`, `cpustat.txt`, `census-*.csv`, `pc-*.log`,
`console.log`, `provenance.txt` and a framebuffer PNG per window.

# ITS wave — MIT Incompatible Timesharing System on a SIMH PDP-10

Issue #61 · Lane B (record wave 2026-09-21) · branch `its-live` (from `its-work`)

**STATUS 2026-09-20: PROVEN ON THE FRAMEBUFFER.** The station boots, renders a
live DDT session, takes XTEST keys, and resets deterministically without
touching its seed. Current state lives in
[`docs/guests/its.md`](../guests/its.md); this file is the wave record.

The earlier stand-down (load wall, nothing proven, no guest ever run) is
resolved: the build completed and every open question below was answered by
measurement.

## Allocation ledger (atomic, `wave.sh alloc its`, 2026-09-20T12:14Z)

| Station | Session | Slot / UDP / VMID | X display | retronet |
|---|---|---|---|---|
| its | its-live | 216 / 54216 / 216 | `:116` (claim `display/:116`) | — (none: terminal-only exhibit) |

Slot moved 210 → 216: the first attempt's numbers had been released at
stand-down and taken by siblings in the meantime. Container uid base `2424832`
(37×65536) — clear of medley 1966080, indyr4400 2031616, vision 2162688, perq
2359296, vax43bsd 2490368, lisa 200000.

## Measured facts

| Fact | Value |
|---|---|
| upstream | `https://github.com/PDP-10/its.git` |
| pinned commit | `0f7d67997f9f5d30208e117e73272031e74f16b9` |
| vendored SIMH | submodule `4d38373206cd7c0ce8b94f5e16bd4429cb96430f` |
| **`rp0.dsk`** | 317132800 B · `7974e21b959164ebbe8125643b6932cc895111e268550119befcd6fce4401a90` |
| **`pdp10`** | 1548856 B · `6173472cb707d9ed34654e5fdbde5c84b7e59011c3c2221fe58d86f8620b3e10` |
| build wall | **2 h 24 min** (12:18Z → 14:42Z) — see "the build is not 30 minutes" |
| container root | `/data/vms/streamhost/assets/its/rootfs`, 364 MB, uid 2424832 (reused from the stood-down run; the tile's step 2 is idempotent) |
| boot to live session | **32 s**, launcher return to return |
| visitor terminal | 80x31 xterm, DejaVu Sans Mono `-fs 14` = 964x748 px, `+30+10` |
| readiness token | `SYSTEM JOB USING THIS CONSOLE` on the PDP-10 console |
| ITS version built | `DB ITS.1652. DDT.1549.` |

## The four things this wave learned

**1. The build is not 30 minutes.** The stood-down run's "~30 min" was an
extrapolation from a run killed at 22 minutes, and it is wrong. The full
`make EMULATOR=simh` took **2 h 24 min** on a box whose run queue sat between
40 and 130 for most of it — the tile boots a PDP-10 and assembles ITS, Maclisp,
Macsyma, Emacs and the INFO tree inside it, at a few MIPS. Budget hours, not
minutes, and expect long silent stretches: the console goes quiet for ten
minutes at a stretch while MIDAS runs. Check `/proc/<pid>/exe` and the disk
mtime rather than the log to decide whether it is alive.

**2. The DSKDMP dance DOES apply, and the earlier handoff said it did not.**
That handoff read the generated `out/simh/boot`, saw it end in `b rp0`, and
concluded ITS boots unattended under `EMULATOR=simh` and that the upstream
README's `DSKDMP` / ESC-G dialogue belongs to the KLH10 path. Reading the
config was not the same as booting it: `b rp0` loads DSKDMP, which prints
` DSKDMP` and waits. Three variants were raced:

| ini | result |
|---|---|
| `expect "DSKDMP" send "its\r"; go` | DSKDMP sits forever, no further output |
| two rules, ESC-G on an `after=` timer | the ESC raced the filename: DSKDMP read `$`, then `Gits`, and answered `FNF` twice |
| `expect "DSKDMP" send delay=200000 "its\r\033G"; go` | `Salvager 261`, then ITS in operation |

Finding 3 of the shared runtime survives intact and is in fact the point: SIMH
answers the dialogue itself from the ini, so there is still no pty/expect
supervisor and the simulator stays the single supervised process.

**3. Chaosnet is load-bearing.** The first contained boot dropped the `ch`
device on the grounds that an unreachable peer is pointless. ITS reached
`Salvager 261` and then:

```
CHAOSNET INTERFACE NOT RESPONDING (CHECK THE BREAKER ON THE UNIBUS)
BUGHALT.  FIND A WIZARD OR CONSIDER TAKING A CRASH DUMP.
```

The kernel wants the *interface*, not a peer. With `ch` enabled and its peer
never answering, ITS boots and merely complains that it could not set the clock
from the network. Both ports are container-private behind `--private-network`.

**4. ITS does not greet a terminal that connects to a DZ line.** Its boot
chatter goes to the PDP-10 console, not to line 0, so an exhibit that just
opens a telnet client shows a black terminal. `^Z` is what opens a session —
the upstream README's own instruction once the console banner has appeared — so
the launcher types it once at bring-up, gated on lit pixels. This is the same
class of problem as vax43bsd's getty CR, and the same fix.

## Runtime

`streamhost/stations/its/x11-runtime.sh` (outer, contained) +
`nspawn-inner.sh` (prologue) + `shared-terminal-runtime.sh` (the lane's shared
engine, byte-identical to `docs/lab/record-wave/shared-terminal-runtime.sh`,
which vax43bsd proved end to end). The station's own copies of the medley
containment logic were replaced by that engine rather than debugged cold. The
outer launcher's per-PID `/proc/*/exe` loop was replaced with the single-fork
`find -lname` form before it was ever run — vax43bsd measured the slow form at
13.4 s per scan, enough to blow the unit's 90 s start-pre timeout.

## Proofs (framebuffer, 2026-09-20)

| Proof | Result |
|---|---|
| rest scene | PASS — `DB ITS.1652. DDT.1549.` / `Welcome to ITS!` / `Happy hacking!` at a DDT prompt, nothing clipped |
| keyboard | PASS — `:LISTF` over XTEST echoed byte-perfect, ITS answered; `:LISTF SYS;` printed the real system directory, 1977–1987 timestamps, behind a `--More--` pager |
| deterministic reset | PASS — scrolled to 49472 lit px, relaunch returned the greeting at 13586 |
| seed integrity | PASS — seed sha256 byte-identical before and after; the work copy diverges within one session, the seed never does |
| pointer | N/A — the exhibit publishes none |

## Open

- **Emacs is unexercised.** The station's headline software is reachable
  (`:EMACS`) but has never been run here, and a DZ line in ITS is a scrolling
  printing terminal rather than an addressable screen, so a full-screen Emacs
  may need `:TCTYP` set first. The on-screen keyboard already carries `^X`.
- **The clock is wrong.** ITS cannot set its time (no Chaosnet peer answers) and
  says so at boot. `:PDSET` would fix it per session; whether the exhibit should
  do that at bring-up is a taste call nobody has made.
- **Row count is cosmetic, and chosen for looks.** 80x31 fills the root; ITS
  itself does not know or care. If Emacs is ever made to work, revisit.

# `irix-bench` — the IRIX measurement and verification rig

Everything that answers "is this MAME build faster, and is it still correct" for
the IRIX tile. The rules these scripts enforce are written up once, canonically,
in **[`docs/lab/MEASUREMENT-METHODOLOGY.md`](../../../docs/lab/MEASUREMENT-METHODOLOGY.md)**;
read that before using any of this. The baseline every claim is judged against
is [`docs/lab/irix-baseline-2026-08-03.md`](../../../docs/lab/irix-baseline-2026-08-03.md).

## Speed

| script | what it does |
| --- | --- |
| `irixbench.sh run\|stop\|shot` | boots a clone with production flags plus `-nothrottle`, drives the login, and measures **within-run** windows. Claims a core pair, records `foreign%`, and kills through `clone-guard`. |
| `bench-agent.lua` | loads the production `irixagent.lua` verbatim and adds one periodic writing `<host_epoch> <emulated_seconds>` twice a second — the trace every window is derived from |
| `workloads.sh` | drives the interactive regimes (terminal scroll, drag) so W1/W2 are reproducible |
| `bwin.py` | per-window `cycnorm% / GHz / IPC / foreign%` for one run |
| `bpair.py` | paired ratios across interleaved rounds, with CI |
| `bsum.py` | run summary |
| `blockrate.sh` | DRC block-compilation rate, for the recompilation-churn questions |

`bwin.py`'s `foreign%` is a **gate, not a decoration**: a busy SMT sibling costs
MAME 39%, so a window with meaningful foreign occupancy on the claimed pair is
not a sample and must be discarded rather than averaged in.

## Correctness

| script | what it does |
| --- | --- |
| `verify-prodclone.sh` | boots a candidate binary under the tile's **exact** production configuration (its launcher, its `tile.env`, both watchdogs, throttled) and screendumps on a schedule |
| `rawrun.sh` | runs the raw production command line with one flag added or removed — the bisector for a production-only failure |
| `shmpng.py` | renders the shm framebuffer MAME publishes to PNG; the output channel for every "it worked" claim |

A binary can be green in the bench rig and broken on the exhibit. The corrected
MIPS3 fastram build was exactly that: measurably faster and framebuffer-correct
in the rig, and it stops IRIX at its own memory diagnostic once the tile's
`-ioc2:rs232a pty` is present. `verify-prodclone.sh` is what catches that class;
`rawrun.sh` is what localises it to the flag pair.

## Namespacing

Every script takes its work root from the environment (`IRIX_BENCH_ROOT`,
`RAWRUN_ROOT`, an explicit outdir) and refuses to run outside
`/data/vms/soltest`. Concurrent agents must pick **unique** roots, **unique**
core pairs (claimed in `/data/vms/soltest/corepairs`), unique tap slots
(`tapnet.sh claim`) and unique displays (`xvfb-alloc`). Kill only through
`clone-guard kill-pidfile`.

# IRIX tile — measurement baseline, 2026-08-03

The reference point every later IRIX performance claim is judged against, plus
the rig that produced it. Written first, before any of the six improvement
workstreams ran, so that "did it get faster" has an answer that predates the
answerer.

Rig: `scripts/build-guests/irix-bench/`. Raw data and the production-state
snapshot: `/data/vms/soltest/irix-baseline-b7f2/` on the box.

## 1. Box conditions when the baseline was taken

Recorded so a later result can be judged against known conditions rather than
against an assumption that the box was quiet.

- `labhost`, 16 logical CPUs, load average 0.59 / 0.68 / 1.91 at 18:56 EEST.
- **Zero tile services running.** All 31 `streamhost@*` units `inactive (dead)`,
  including `streamhost@irix`. Nothing was started to take this baseline; every
  measurement below comes from a clone.
- **Zero IRIX MAME processes**, zero taps allocated (`/run/irix-taps` empty),
  zero core-pair claims (`/data/vms/soltest/corepairs` empty), no `taskset`
  pins anywhere on the box.
- One `Xvfb :1` — the shared dev desktop. Left alone.
- The only real CPU consumer was **a co-located VM at ~29.5% of one
  core**, which is a permanent fixture of a different project and expected.
- Also present but near-idle: the WebRTC bridge, the HTTPS server, `pvestatd`,
  a Chrome instance belonging to a sibling agent's unrelated session.

The live tile directory showed a launch at 18:35 and files last written 18:44,
i.e. the tile had been run and stopped earlier that day. It was **not** running.

## 2. Production state snapshot (rollback + diff reference)

Full file: `/data/vms/soltest/irix-baseline-b7f2/PRODUCTION-SNAPSHOT.md5`.
The deploy workstream needs this to prove what it replaced.

| what | md5 |
| --- | --- |
| `assets/irix/mame/sgi` (**shipped binary**) | `0db273009ecd1d41634b5527c8fa6be8` |
| `assets/irix/mame/sgi.prev-21040adb` | `21040adbbd1e34324eb87c61ae122c2c` |
| `assets/irix/mame/sgi.prev-78347002` | `78347002bbb5ced11b495007ac781198` |
| `assets/irix/mame/sgi.prev-a33944d3` | `a33944d3259876fb3c6309271d4a64bf` |
| `assets/irix/mame/sgi.taptun-e513fbb6` | `e513fbb69299ae56a0db70ad2adba636` |
| `irix65-apps-v3.chd` (**shipped golden**) | `368fcfb9b56fb4165a4e456238dc1a18` |
| `irix65-apps.chd` | `09e51dbc9080e90785149bbec7a0dd64` |
| `irix65-apps-v3-serial.chd` | `f8c67f03ccb19ee979d7aadbd60499d7` |
| `irix65-apps-v4.chd` | `0a2118af48852b74df546afb235ab305` |
| `irix65-apps-v5.chd` | `b8a20bbe27593889995ab57978ca75ae` |
| `irix65-apps-v6.chd` | `e5777f6e2a48edf5831e13ca0233075a` |
| `irix65.chd` (bare base install) | `430bf0badd61fb35e28c69c7e3bba83a` |
| tile `x11-runtime.sh` | `b1cd3d2142b34974e07068bebace5548` |
| tile `tile.env` | `978b6b371ba0d53f8fdaa5bac71ccfed` |
| tile `irixagent.lua` | `566edbbd22e03488141a168ea1fd40ad` |
| tile `fbstat.py` | `bfa823b5fe8fc482edafd3d9c1dff71c` |
| tile `fetch-assets.sh` | `c7750c575225c1c8c77ad9d8a31d5248` |
| asset `irixagent.lua` | `401b60779fe1fd5e9f487d0612ba6ca0` |
| asset `nvram/indy_4610/eeprom` | `827f263ef9fb63d05499d14fcef32f60` |
| asset `nvram/indy_4610/rtc` | `f417704f093ef1ef60438c22ab15b855` |
| asset `uicfg/ui.ini` | `28c9624b643a5d3de39658cb0e5dda25` |

All seven goldens are `chmod 444` and carry the `i` (immutable) attribute.
`tiles/irix/disk.chd` is **not** a golden — it is the per-launch writable copy
and its md5 changes on every boot; recorded only to show it was a copy of v3.

Repo correspondence: `main` at **`650f0f6`** ("feat(irix): namespaced tap slots,
and a MAME that honours MAME_TAP_IFNAME"), clean tree.

**Watch out — the shipped binary is not the newest one staged.** `sgi`
(`0db273…`, 01:57) predates `sgi.taptun-e513fbb6` (03:32), so the MAME the
exhibit currently runs does **not** carry the `MAME_TAP_IFNAME` change that
`650f0f6` describes. Whoever deploys next has to decide that deliberately
rather than discover it.

## 3. Measurement method

`scripts/build-guests/irix-bench/irixbench.sh` boots a clone of the production
golden with the production binary and production flags, drives the login, and
measures **within-run** windows.

- **Metric**: `cycnorm% = emulated_secs / (cycles / 2.5e9)`. Never MAME's own
  "Average speed %".
- **Achieved GHz** (`cycles / task-clock`) is reported next to every figure.
  cycnorm does not ignore a clock change, it inverts it.
- **Within-run windowing only.** `bench-agent.lua` loads the production
  `irixagent.lua` verbatim and adds one periodic that writes
  `<host_epoch> <emulated_seconds>` twice a second. Every window is converted
  through that trace, inside the run that produced it. Cross-run differencing
  is invalid on this exhibit: IRIX boot diverges from ~t=120 s.
- **One core pair per run**, claimed in `/data/vms/soltest/corepairs`. Both
  logical CPUs of the pair are sampled once a second from `/proc/stat`, and the
  analyser reports `foreign%` — CPU burnt on the pair by anything that is not
  this MAME. A busy SMT sibling costs MAME ~39%, so this is an assertion, not a
  decoration.
- **Framebuffer, never logs.** State detection and every "it worked" claim goes
  through `shmpng.py`, which renders the shm mapping MAME publishes.

### Production fidelity, and the one deliberate difference

Same binary, same golden, same `-video none` + shm publish, same `-sound none`,
same `-frameskip 6`, same `irixagent.lua`. The rig adds **`-nothrottle`**.

The tile itself runs throttled (`x11-runtime.sh` passes no `-nothrottle`), which
clamps every regime at 100% of real time. An idle desktop that can do 140% is
indistinguishable from one that can do 105% under throttle, so a throttled run
cannot measure a speed at all in the regimes that matter. `--throttle`
reproduces the shipped behaviour when what is wanted is the shipped behaviour.

The consequence is worth stating plainly for the five workstreams that follow:
**a gain in any regime already at or above 100% buys host-CPU headroom, not
visible speed.** Only the sub-100% regimes are visible to a visitor.

### shm framebuffer signatures (re-measured here)

`irix-park-desktop.sh` measured its signatures on the **x11** path, where the
emulated frame is scaled into a 1272x954 window inside a 1280x1024 root with
black borders. This rig reads the **shm** mapping: the exact 1288x1024 emulated
framebuffer, no borders, no resample. The numbers move, and reusing the x11
thresholds silently never detects the login chooser.

| state | x11 grab (mean / sd) | shm mapping (mean / sd) |
| --- | --- | --- |
| iconlogin chooser | 0.658 / 0.226 | **0.702 / 0.167** |

Desktop readiness stays content-based — the Toolchest crop — because full-frame
statistics cannot separate "logged in, session still starting" from "desktop
ready" on either path.

## 4. Two rig defects found and fixed while building it

Recorded because both are the kind that quietly poison somebody else's numbers.

1. **The pidfile named the wrong process.** `perf stat -- …` forks MAME as a
   grandchild through `taskset` and the glibc bundle's loader, so the recorded
   `$!` is perf. Killing it left **five orphaned MAMEs at 100% of a core each**
   — on a shared box, with five sibling agents about to start measuring. The
   rig now resolves the emulator's own PID (excluding the wrappers by
   `/proc/<pid>/comm`; at the time the emulator reported `ld-linux-x86-64`
   rather than `sgi`, because it was exec'd through the bundle's loader — that
   indirection was retired 2026-08-07 and `comm` is now `sgi`), and `stop`
   verifies afterwards that
   nothing named after the run survived.
2. **The settle floor was measured from the wrong instant.** Typing into the
   iconlogin panel too soon after it paints reproducibly panics the guest
   (`PANIC: bad istack`, the same stack pointer every time). The floor has to
   run from when the panel **first appeared**, not from process launch —
   elapsed-since-launch passes the floor before the machine has come up.

## 5. What could NOT be measured, and why

The brief asked for four workloads. Two of them cannot be driven on the golden
the exhibit actually ships, and the honest thing is to say so rather than
substitute something easier and label it a scroll.

- **W1 terminal scroll** (`find /usr -print` in a winterm) and **W2 window drag
  during that scroll** need a shell inside the guest. Golden **v3 has no guest
  networking** — that landed in v5 (`irix-net-bake.sh`) — so there is no exec
  channel into the shipped image at all. The only input path is the Lua agent,
  whose motion verbs (`MOVE`, `MOVEP`) are **relative deltas**; landing the
  pointer on a named Toolchest menu item needs closed-loop absolute positioning
  against the framebuffer. That exists for the XTest era
  (`scripts/build-guests/irix-apps/point.py`) and has no shm-path equivalent.
  Building one is a real piece of work, not a baseline detail.
- **W3 Netscape** additionally depends on a session restore that is
  **non-deterministic between boots of the same image** (see the "Netscape
  autostart" section of `irix-tile-issue20-handoff.md`). Even with a driving
  channel, a Netscape workload on v3 is not a reproducible one.

The route to all three is known and cheap to state: bake the pointer
positioning against the shm path, or measure on **v6** (which has networking)
and accept that it is a different image from the one on show. Either is a
follow-on, not a baseline.

## 6. The numbers

Ten runs, two interleaved rounds with the core pairs swapped between them
(round 1 on 1,9 / 2,10 / 4,12 / 5,13 / 6,14; round 2 in the reverse order).
Two runs hit the known black-screen cold-boot hang and were discarded — **2 of
10 boots**, which is itself a number worth carrying forward.

| window | regime | n | median cycnorm% | CI95 | IQR | GHz | IPC |
| --- | --- | --- | --- | --- | --- | --- | --- |
| emu 40-110 s | cold boot, active | 8 | **93.84** | [92.47, 94.95] | 2.16 | 2.493 | 1.500 |
| emu 110-180 s | console → chooser | 8 | **150.65** | [148.46, 152.66] | 4.06 | 2.494 | 1.532 |
| idle 4Dwm desktop | 90 s held, post-login | 5 | **152.67** | [134.11, 155.25] | 12.10 | 2.494 | 1.562 |

Achieved clock was **2.493-2.494 GHz on every kept run** — one round-2 run read
2.514 GHz, and it is exactly the run that scored lowest on cycnorm (134.11%).
That is the inversion in miniature, on this box, in this cohort: do not read a
cycnorm delta without reading the clock beside it.

Three round-2 idle windows were **discarded for foreign CPU on the claimed pair
(17.4%, 18.1%, 19.5%)** rather than averaged in, which is why the idle row is
n=5 and its interval is wide. The foreign load was not a sibling agent — the box
was still mine — it was the harness itself: five concurrent runs plus unpinned
`ssh`/`python3` polling land on the pairs. Round 1, polled less aggressively,
sat at 4-9%. **Poll less, or pin the poller**, when the deltas being chased are
small.

### What this means for the five workstreams that follow

- The **only sub-100% regime measured is cold boot** (~94%). Everything a
  visitor sits in front of — the idle desktop, and by extension the transition —
  is already **above 100%**, where the tile's throttle binds. A win there is
  host-CPU headroom, not visible speed. Say which one you are claiming.
- The two workloads a visitor actually notices (terminal scroll ~45-49%,
  Netscape ~56%, per the earlier campaign) are **not in this baseline** — see
  section 5 for why, and do not quietly substitute the idle number for them.
- `foreign%` and achieved GHz are on every row for a reason. A result reported
  without both is not comparable to this table.

Raw data, per-run tables and provenance:
`/data/vms/soltest/irix-baseline-b7f2/RESULTS.md`, with per-run directories
(`perf.csv`, `trace.txt`, `phases.txt`, `cpustat.txt`, `provenance.txt` and the
framebuffer PNGs) beside it.

### Evidence

Desktop readiness was confirmed on the real framebuffer for every kept run —
`shot-desktop.png` and `shot-idle.png` in each run directory show the 4Dwm
Toolchest, `UnixRoot`, `blender1.0` and `dumpster` at the exact 1288x1024
emulated resolution, read out of the shm mapping with no X server in the loop.

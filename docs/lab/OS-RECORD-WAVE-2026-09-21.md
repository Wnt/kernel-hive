# OS record wave — week of 2026-09-21

Tracking epic: #62

## Objective

Maximize the number of **honestly live, interactive operating-system stations** landed during the week. Optimize for *completed exhibits*, not for starting all fifteen at once.

Every child already has:
- a prep branch,
- exhibition prose,
- an integration seed,
- draft builder/runtime files,
- registry/SPA override notes.

The lab session should therefore begin at the first framebuffer proof, not at research.

## The rule that makes the record attempt work

**Land cheap wins before spending a long pole on the hard stations.**

A station counts only when its actual emulator/device set, framebuffer, input and reset path are proven. Do not hold a finished easy station behind a difficult sibling.

The previous nine-station wave showed that landing windows serialize and cost real time. Run the gate **before** joining the landing queue and keep a steady queue of already-proven stations.

## Recommended execution order

### Lane A — shortest likely paths

Start these immediately and independently:

| Station | Branch | First proof | Why first |
|---|---|---|---|
| Linux 0.12 | `linux012` | two-floppy QEMU boot → shell | tiny text guest, no pointer/network |
| CP/M 2.2 | `cpm22` | MAME Kaypro → `A>` | tiny immutable floppy guest |
| RISC OS 3.11 | `riscos3` | MAME A310 → Desktop | ROM-resident, existing MAME-native path |
| MSX2 / DOS2 | `msx2` | openMSX → DOS2 prompt | mature emulator, immutable assets |
| Palm OS | `palmos` | MAME Palm → Launcher + stylus | may be nearly drop-in if current driver behaves |

These should not wait on any shared terminal infrastructure.

### Lane B — heritage terminal family

Use **MVS as the pathfinder** for the common terminal/container plumbing, then immediately relay the working shell to the other three.

| Station | Branch | Emulator | Visitor terminal |
|---|---|---|---|
| MVS 3.8j | `mvs38` | Hercules | x3270 |
| Multics | `multics` | DPS8M | xterm/telnet |
| 4.3BSD/VAX | `vax43bsd` | SIMH VAX | DZ telnet |
| ITS | `its` | SIMH PDP-10 | TCP 10004 |

The common contract is in `docs/lab/record-wave/shared-terminal-runtime.sh`.

When the first station proves:
- Xvfb socket exposure,
- nspawn containment,
- process supervision,
- terminal crop,
- reset/relaunch,

copy the measured fix immediately to all three sibling sessions.

### Lane C — conventional but installation-heavy

Run after Lane A has produced landing candidates:

| Station | Branch | Main wall |
|---|---|---|
| early Mac OS X | `macosx` | PPC install + pointer + golden restore |
| webOS | `webos` | reproduce SDK OVA hardware in QEMU |
| PC-98 | `pc98` | Japanese Windows install/video/input |
| Symbian S60 | `symbians60` | EKA2L1 firmware profile + phone keys |

These are good record candidates, but each can consume a worker for substantially longer than a text/ROM station.

### Lane D — deliberately last

| Station | Branch | Reason |
|---|---|---|
| Psion Series 5 | `psion5` | emulator race itself is unresolved |
| Symbolics Genera | `genera` | world/VLM/X environment has the most moving parts |

Start these early only if spare workers exist. Never let them consume the worker needed to land a completed Lane A/B station.

## Worker start sequence

For every station:

```bash
scripts/dev/wt.sh new <id>-work --from origin/<id>
cd ../<id>-work
cat docs/lab/integration-seeds/<id>.md
cat docs/lab/integration-drafts/<id>/builder.sh
cat docs/lab/integration-drafts/<id>/runtime.sh
```

Then allocate only what that station truly needs:

```bash
scripts/dev/wave.sh alloc <id> [--x11warp] [--retronet]
```

Do **not** mechanically add retronet or x11warp:
- text/ROM systems with no period network story should stay simple;
- host-X11 emulators need their X display, but not necessarily guest x11warp;
- add retronet only if it belongs in the intended first device set.

Run the exact scaffold command already written in the issue/integration seed **after** allocation.

## Parallelism

- One wave session owns one station.
- A station may race up to three emulator/device theories; kill losers on the first decisive framebuffer.
- Watch the repo load rule: 1-minute load above 50 means reduce concurrency.
- The coordinator relays only cross-wave findings and watches load.
- Allocation and landing order belong to `wave.sh`, not chat messages.

## Landing strategy

The goal is a **continuous landing queue**.

As soon as a station has:
1. final runtime/device set,
2. framebuffer proof,
3. input proof,
4. deterministic reset,
5. poster/registry values updated from measured facts,
6. green local gate,

it joins the landing queue. Do not wait for its wave siblings.

Before queueing:

```bash
python3 scripts/stations-registry.py generate
python3 scripts/stations-registry.py validate
(cd spa && npx vitest run)
git status --short
```

Then:

```bash
scripts/dev/wave.sh land begin <id>
scripts/dev/station-land.sh <id> ...
```

The previous record wave lost many landing-window minutes to gates and conflicts. Pay those costs **before** taking the window.

## Definition of a record-count station

Minimum honest exhibit:
- real OS/emulator reaches the intended scene,
- visitor can interact with it,
- reset deterministically returns to that scene,
- registry/poster/hero describe what is actually running,
- station is on main and live in the gallery.

Optional features that are not historically relevant must not become blockers. Do not invent a browser, audio device, mouse or network for a machine whose museum story does not need one.

## Cross-wave findings that must be relayed immediately

Post to the sibling sessions when any of these is discovered:
- shared nspawn/Xvfb socket fix,
- terminal emulator font/crop/key mapping,
- MAME native binary regression or required pin,
- QEMU PPC/mac99 restore issue,
- SDL/OpenGL requirement on the no-GPU host,
- source archive/file naming mismatch,
- keyboard pacing below the fleet floor,
- a reset path that corrupts writable guest media.

A fix discovered once should cost the wave once.

## Upstream pins captured during prep

These are immutable starting points captured on 2026-09-19. A worker may move a
pin only when the pinned revision demonstrably fails on labhost, and should
record the reason in the station wave doc.

| Component | Commit |
|---|---|
| Arculator fallback | `c88f1f5fa6acf92d69fb3b5f932f60262c9ce3a7` |
| CloudpilotEmu fallback | `dae0b272e86888e903defb39ce914e8d28284545` |
| TK5/Hercules helper repo | `023dc1a434d4ec8d3c7fc8d7e87f0ec205fbab77` |
| DPS8M | `83d7252b829f2bbc497b45ff0fc9a96d1335c347` |
| WindEmu fallback | `c3e6c955425cf3607f7261a9a75a28b745219eb8` |
| EKA2L1 | `bbbf621830e10ef7b3abb12a5518f9562e520b31` |
| Open SIMH | `a1f57fa3738ed31148d31126ba1a7278ff845c6d` |
| OG2VLM | `616d06c1a1c5de3a50762caa49160694afc65d37` |
| webOS emulator archive repo | `e93a3b9aa15876a0c3a2fc17b4d67440d9eaba85` |
| NP2kai | `28fe8af77e1e9d9f3f88434ca35b19ce0c21ae97` |
| openMSX | `02a50c8805d21639188e081b173992f0fde0851d` |
| PDP-10 ITS | `0f7d67997f9f5d30208e117e73272031e74f16b9` |

The station draft builders for DPS8M, SIMH, OG2VLM, NP2kai, openMSX and ITS now
default to these exact refs rather than `master`.

## Final fleet pass

After the last station lands:
- regenerate/publish runtime manifests,
- run the fleet verification sweep,
- update the weekly release-note facts,
- refresh the collection count from the registry rather than hand-writing it,
- seed cross-station contacts only for stations that actually join the IM plane.

## Record-wave dashboard

Use #62 as the roster. A station moves through:

`PREP READY → SMOKE → INPUT/RESET → GATE GREEN → LANDING QUEUE → LIVE`

Do not use “almost done” as a state.

# Glossary — the canonical vocabulary (2026-08-11)

One term per concept, chosen by the operator 2026-08-11 to replace a set of
drifted near-synonyms. **Prose uses these words everywhere.** Identifiers,
env vars, paths and stored artifact labels migrate in stages (see
[`docs/lab/research/terminology-migration-2026-08.md`](lab/research/terminology-migration-2026-08.md));
until a stage lands, docs keep the OLD name inside code fences and backticked
literals — a literal must always name the thing as it exists on labhost
today. `docs/history/` is a record and is never re-worded.

| Term | Means | Replaces |
|---|---|---|
| **station** | One exhibit unit: a guest OS + its streamhost daemon + its per-station files. 60 production stations + 2 posters. | tile |
| **kiosk** | The bridge subtype of station: a Debian guest running an emulator full-screen (linapple, VICE, …). | bridge tile, bridge kiosk |
| **seed** | A **cold disk image** — filesystem only, boots from scratch (e.g. `irix65-apps-v9.chd`, the qcow2 disk masters). | golden (disk sense), golden image, base |
| **checkpoint** | A **captured full machine state** — RAM + devices + paired disk — that resumes instead of booting (QEMU `savevm` state; MAME `.sta` + pause-window-paired disk). | golden (state sense), golden snapshot/savestate |
| **capture / recapture** | Creating / regenerating a checkpoint (or a seed). | bake / rebake |
| **scene** | The curated desktop a visitor sees when a station wakes — what a checkpoint captures (apps open, cursor parked, clock hidden). | fixture (desktop sense) |
| **`*.env.fixture`** | The per-station env stanza file appended verbatim to the station's env. The FILE keeps this name (operator decision); the word "fixture" otherwise retires. | — |
| **UI** | The React front-end (`spa/`, directory renames in stage 3). | SPA |
| **pause / resume** | The idle mechanism: no visitors → the guest is paused (QMP stop or SIGSTOP), first session resumes it. `stop`/`cont` appear only as literal QMP verbs. **start-paused** = launching already at the checkpoint, paused. | freeze/thaw, freeze/wake, quiesce, instant-resume, launch-frozen |
| **instant-ready** | The fleet feature: launch restored-to-checkpoint and paused, first session resumes. | instant restore (feature sense) |
| **labhost** | The physical Proxmox machine. "host" is reserved strictly for host-vs-guest contexts. | the box, the lab (machine sense) |
| **launcher** | Any per-station process-starting script (`qemu-streamhost.sh`, `x11-runtime.sh`). | runtime (script sense) |
| **reset** | The visitor-facing umbrella action ("put the station back"). **restore** = loading a checkpoint specifically; **relaunch/restart** = process-level mechanisms. | (overlapping use of all four) |

**Stored labels lag by design:** the QEMU snapshot label `golden`, the
`golden.sta` / `provenance-golden.md5` / `golden-manifest.json` filenames and
`IRIX_STATE=golden` are opaque labels baked into ~60 artifacts; they rename
only at natural recapture moments or in migration stage 5 — never sed a
label an artifact answers to.

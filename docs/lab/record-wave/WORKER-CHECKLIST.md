# Record-wave worker checklist

Use this with the station's own issue + prep branch. It is deliberately short:
the detailed emulator instructions already live in
`docs/lab/integration-seeds/<id>.md`.

## Before touching labhost

- [ ] Read the station issue.
- [ ] Work from `origin/<id>`, not main.
- [ ] Read:
  - `docs/lab/integration-seeds/<id>.md`
  - `docs/lab/integration-drafts/<id>/builder.sh`
  - `docs/lab/integration-drafts/<id>/runtime.sh`
  - `docs/lab/integration-drafts/<id>/registry-overrides.md`
  - `docs/lab/spa-drafts/<id>.md`
- [ ] Read `ADD-NEW-OS-PLAYBOOK.md §0`; do not reread the whole repo.
- [ ] Decide whether this station genuinely needs `--retronet` or `--x11warp`.
- [ ] Create the worktree/session.

## First lab actions

```bash
scripts/dev/wt.sh new <id>-work --from origin/<id>
cd ../<id>-work
scripts/dev/wave.sh alloc <id> [needed flags only]
# run the exact scaffold command from the issue/integration seed
```

Then:

- [ ] Copy/adapt draft builder/runtime into the scaffold-created final paths.
- [ ] Fill registry/SPА fields from `registry-overrides.md`.
- [ ] Promote the exhibition draft into the scaffold-created poster.
- [ ] Stage media and immediately record:
  - exact filename,
  - byte size,
  - SHA-256,
  - emulator/source pin.
- [ ] Commit the allocation/scaffold/media facts before racing theories.

## Smoke proof

The first proof is deliberately small:

- [ ] Emulator starts with the proposed device set.
- [ ] Intended screen appears.
- [ ] Capture path shows the real guest pixels.
- [ ] One meaningful input changes those pixels.
- [ ] Save the screenshot/frame that proves it.

Do not install optional software, networking, audio or polish before this proof.

## If the first theory fails

- [ ] Write what the framebuffer/log actually showed.
- [ ] Race at most two alternate theories alongside it.
- [ ] Kill losing runners on the first decisive frame.
- [ ] If the wall is shared with another station, relay it immediately.
- [ ] Do not keep a broken runner alive “for later”.

## Before building the final reset scene

Freeze the **complete intended first-release device set**. Adding a NIC, pointer
device or different virtual controller after a QEMU checkpoint usually means
rebaking it.

For relaunch-style host applications:
- immutable assets remain read-only,
- visitor-writable media is copied/reflinked into work on every launch,
- relaunch wipes the work copy.

## Scene / museum proof

- [ ] Rest scene matches the exhibition note.
- [ ] No emulator menus, host shells or warnings are visible.
- [ ] Poster “What you're looking at” paragraph uses measured facts.
- [ ] Hero is captured from the actual final scene.
- [ ] Registry display name/year/arch match the actual winner, not the prep guess.

## Input proof

For pointer stations:
- [ ] at least five targets distributed across the usable screen,
- [ ] clicks land on the intended target,
- [ ] drag if the exhibit needs it.

For keyboard-only stations:
- [ ] normal text,
- [ ] modifiers/special keys used by the demo,
- [ ] fleet pacing or a measured slower floor.

Phone/terminal stations must expose historically necessary soft/PF/control keys
through the on-screen keyboard rather than hidden host shortcuts.

## Reset proof

- [ ] Make a visible change.
- [ ] Reset.
- [ ] Confirm the original scene returns.
- [ ] Repeat from a fresh process, not only in-process.
- [ ] Confirm writable media did not corrupt the immutable seed.

## Ready-to-land gate

Do all expensive/local checks **before** taking the landing window:

```bash
python3 scripts/stations-registry.py generate
python3 scripts/stations-registry.py validate
(cd spa && npx vitest run)
git status --short
```

A station is ready to queue only when:
- [ ] runtime is final,
- [ ] input proven,
- [ ] reset proven,
- [ ] docs/poster final,
- [ ] hero final,
- [ ] gate green.

## Landing

```bash
scripts/dev/wave.sh land begin <id>
scripts/dev/station-land.sh <id> ...
```

Do not hold the landing window while investigating a failing gate.

## Report after landing

Post:
- main commit,
- measured viewable/golden/landed times,
- emulator/device set,
- one screenshot,
- any shared finding another wave can reuse.

Then release sandboxes/claims per the normal wave teardown.

## Before merging a PAUSED branch (added 2026-09-20)

The 2026-09-20 run paused ten stations mid-flight. Five of the pushed branches
(`linux012-work`, `cpm22-work`, `riscos3-work`, `msx2-work`, `its-work`) carry a
registry row with `lifecycle: production, enabled: true` for a station that has
**never booted as a station**. That is not a mistake by those workers — playbook
§0 tells you to scaffold `--like <sibling> --production` precisely so `validate`
is green on the spot, which is correct when the station lands in the same
session. It becomes a landmine the moment the wave pauses instead.

Merging such a branch to `main` and running `box-deploy.sh --apply` enters the
station into the streamhost, signaling, reset and UI lineups, so the gallery
lists an exhibit that does not exist.

Before merging any paused wave branch:

- [ ] `python3 -c 'import json;d=json.load(open("registry/stations/<id>.json"));print(d["lifecycle"],d["enabled"])'`
- [ ] If it is `production True` and the station has no framebuffer proof, either
      finish the station or flip the row down before the merge.
- [ ] Flipping `production` → `candidate` can break `validate` against the
      generated scene shards (see [[spa-scene-tables-are-sharded]] and
      `spa-scene-rows.py`). Regenerate; never hand-edit a generated file.
- [ ] Re-read the branch's own `docs/lab/<ID>-WAVE.md` — the worker recorded
      what is proven versus assumed there, and only a framebuffer counts.

`palmos-work`, `multics-work` and `macosx-work` already ship their rows as
`candidate/false` deliberately, and `mvs38-work`/`vax43bsd-work` have no registry
row at all; those five are safe to merge on this axis.

## Rule 5 traps that actually bit, same run

Three of ten workers tripped AGENTS.md rule 5. Cite these concretely in a brief
rather than citing the rule number:

- `pkill -x Xvfb` inside `ssh lab` killed the Xvfb of **every** `SH_CAPTURE=x11`
  station on the box (medley, lisa, vision, perq, amix), not just the author's.
- A cmdline `grep`/`pkill -f` reap matches the very `ssh`/`labrun` session running
  it and kills the session — two separate workers did this.
- Resolve processes by `/proc/<pid>/exe` (or `/proc/<pid>/stat` for a session id),
  never a cmdline match, and scope the match to your own sandbox/asset path.

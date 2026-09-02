# Add a new OS station — the 10-minute fast path

Read this INSTEAD of [`ADD-NEW-OS-PLAYBOOK.md`](ADD-NEW-OS-PLAYBOOK.md) when the
operator asks for a station *fast*. Target: **viewable at `/os/<id>` in 5 min,
fully featured (listed, golden, poster, type-in demo) in 10.** The playbook is the
reference for the *why* and the traps; open a section only when a step below fails.
Operator rules that make this legal: move fast, operator validates; a restoring
golden is enough proof; the framebuffer is the only proof a guest reacted.

## Why this exists: the bootos retro (2026-09-02, 45 min → should be 10)

One coordinator + 4 parallel agents, nothing waited on the operator, still 45 min.
Where the time went and what the fast path does instead:

| Sink (bootos) | Cost | Fix in this path |
|---|---|---|
| Reading playbook + sibling entries before touching anything | ~6 min | Read THIS page; one sibling entry, `grep` not read |
| Scaffold leaves validate failures (no poster md, no hero webp, demoProgram rules) | ~5 min | Scaffold, commit with placeholders the validator accepts, let streams fill; fix the scaffold at the root when you meet a new one |
| Golden stream: key-pacing bisect | ~7 min | SKIP. Ship the fleet floor **40/40** for QEMU keyboard stations; measure only if characters drop |
| Golden stream: audio proof ceremony | ~4 min | SKIP. Declare `stream.audio`; operator hears it |
| Guest doc with ~15 TODO placeholders filled at integration from agent reports | ~4 min | Streams write their own facts into the doc sections they own; docs stream writes prose only |
| Separate TS+Python gate run, then the pre-push gate ran the same stages | ~5 min | Push; the pre-push gate IS the gate |
| Hand-rolled single-station emit (`manifest` has no `--only`, relative-path failure), `current` symlink by hand, `manifests` failing inside `labrun` (nested ssh) | ~6 min | `scripts/dev/station-up.sh <id>` (single-station emit + binary symlink + start + manifests + `labctl gen` + checks, run from CT950) |
| One cross-stream fact copied wrong by 3 streams (360K vs 720K in 4 files) | ~3 min | The ledger states measured facts (`stat -c %s` the image), never copies from a README |
| Merge conflict in the registry blurb | ~1 min | Only the spa stream edits visitor-facing prose |

## Minute 0–3: spine (you, alone)

```bash
scripts/dev/wt.sh new <id> --from origin/main            # full stack + KH_SESSION=<id>
# stage media: fetch, hash, keep the byte size — it is a ledger fact
ssh lab 'mkdir -p /data/assets-staging/<id> && cd /data/assets-staging/<id> && sha256sum * > MANIFEST.sha256 && stat -c "%n %s" *'
# smoke boot in YOUR sandbox with the intended device set (see vom-reference.md for the emulator/machine)
scripts/dev/labrun <<'EOF2'
cd /data/vms/sandbox/<id> && qemu-img convert -O qcow2 /data/assets-staging/<id>/<img> smoke/disk.qcow2
# launch exactly as the launcher will (dbus display, -qmp unix:smoke/qmp.sock, namespaced port), then:
python3 /data/vms/streamhost/serve/qmp-type.py --sock smoke/qmp.sock 'dir\n' && qmp screendump smoke/frame.ppm
EOF2
# PUBLISH THE SMOKE RIG NOW — this is the 5-minute target: operator watches /os/<id>
ssh lab "python3 /data/vms/sandbox/<id>/repo/scripts/dev/darklaunch-station.py publish <id> --rig /data/vms/sandbox/<id>/smoke --entry /data/vms/sandbox/<id>/entry.json"
python3 scripts/stations-registry.py new <id> --emulator qemu --kind <archetype> ...   # scaffold (see playbook §6.0 for flags)
```

Then the ledger commit on branch `<id>`: `docs/lab/<ID>-WAVE.md` with the allocation
table (slot/UDP/VMID via `kh-claim`, render orders, device set, measured media
size, upstream pin), the registry entry, launcher and fixture as scaffolded, and
the stream table below. Commit, push (recipe at the bottom). Do not fix validate
failures by hand for more than one minute — leave the field as the scaffold
wrote it and assign it to a stream.

## Minute 3–7: 3–4 parallel streams off the ledger, each with a 4-minute stop

Each: `scripts/dev/wt.sh new <id>-<stream> --from <id>`, commit on its branch, push,
report the branch. **Hard stop at 4 minutes** — report what is proven and what is
not; the coordinator ships what exists.

| Stream | Deliverable | Skips by default |
|---|---|---|
| `build` | `scripts/build-guests/tiles/<id>.sh` (pinned fetch, SHA-256, compose disk, framebuffer-verify boot); RUN it so the pristine output exists; `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows | No bisecting machine types — use the device set from the ledger |
| `golden` | bake `golden` on a sandbox clone with the exact launcher, one `loadvm` restore proof, stage the disk into the station dir; `bootrec-tiles.conf` arm; registry `runtime`/`reset`/`operator` truth; writes its own facts into `docs/guests/<id>.md` §Checkpoint | Pacing bisect (ship 40/40), audio proof (declare it), reset-N-times loops |
| `spa` (+docs) | `registry/posters/<id>.md`, `spa/public/posters/<id>/desktop.webp` from real frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram`; `docs/guests/<id>.md` prose, `GUEST-TIERS.md`, release-notes JSON | Playtesting the demo beyond one `labctl type` + `shot` |

Facts flow one way: a stream that *measures* a fact corrects the ledger in its own
commit and says so in its report; nobody copies a number from a README.

## Minute 7–10: integrate and ship (you)

```bash
# merge the stream branches into <id> (ledger is a union; generated files: regenerate, never hand-merge),
# then land on main from a /data worktree and push — the pre-push gate is the only gate run
git merge --no-edit origin/<id>-build origin/<id>-golden origin/<id>-spa && git checkout main && git merge --no-ff <id>
GIT_SSH_COMMAND="ssh -i /home/wnt/.ssh/id_github -o IdentitiesOnly=yes" git push origin main
scripts/dev/box-deploy.sh --apply                       # a push is not a deploy
scripts/dev/station-up.sh <id>                          # emit + /usr/local/lib/streamhost/stations/<id>/current + start + manifests + labctl gen + checks
ssh lab "labctl shot <id> && labctl type <id> 'dir' && labctl shot <id> && labctl restore <id>"   # framebuffer proof, once
scripts/serve-https-spa.sh build && scripts/serve-https-spa.sh deploy                   # poster/scene/demo; re-arms nothing, so:
ssh lab 'python3 .../darklaunch-station.py withdraw <id>'                               # the smoke overlay is now superseded by the real row
```

Done means: `/os/<id>` shows the real station, the grid lists it, the smoke rig is
withdrawn and its sandbox released (`kh-claim release`), and the report names the
three checks above. Tear-down is part of done.

## Push recipe (3 lines)

1. `SKIP_GATE=1` ONLY on feature branches (`<id>`, `<id>-*`); never on `main`.
2. `GIT_SSH_COMMAND="ssh -i /home/wnt/.ssh/id_github -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20" git push -u origin <branch>`
3. Push `main` from a `/data` worktree (`/data/vms/sandbox/<name>/repo`), never the shared clone — the box-state gate needs it.

## What NOT to skip

The golden must restore once (`loadvm golden` on the exact device set); the
launcher must be the one the golden was baked with; addresses stay placeholders
(`192.0.2.10`, `labhost`); every claim goes through `kh-claim`; the framebuffer
is the proof, not a log line.

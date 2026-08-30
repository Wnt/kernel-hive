# Continuous deploy — push-to-main converges the box

**Status: PROPOSAL. Nothing here is built. No deployment behaviour changed.**

The operator's ask, verbatim intent: *push to main ⇒ the live system converges,
automatically, safely, with many concurrent independent sessions and no
human-brokered coordination — and goldens/OS images covered too. "Make it more
git based."*

This document designs that system against the evidence of 2026-08-30 — one
session with five parallel station agents plus three unrelated sessions, which
produced eleven distinct coordination failures (the numbered incidents cited
throughout: §I.1–§I.11 below). Every design decision names the incident it
kills.

---

## 0. The incidents, indexed

| # | Incident (2026-08-30) | Root shape |
|---|---|---|
| I.1 | `box-deploy.sh --apply` is global; every deploy needs manual clearance from every session | shared mutable checkout, fleet-wide install |
| I.2 | `compare_live_labctl` in the pre-push gate is repo-wide and unsatisfiable during a cutover; `main` became unpushable for everyone; `SKIP_GATE=1` taught itself. Sharpened post-briefing: the gate range-scopes every *other* leg ("Rust lint == not owed"), so this stage is also internally inconsistent with the gate's own design | live state tested as a property of a commit |
| I.3 | Install order (QEMU binary → launcher → daemon → env fixture) binding both directions, enforced by discipline only | sequential installs of a coupled set |
| I.4 | "Inert" judged per-file; the env fixture asserted the backend unconditionally | change reviewed without its closure |
| I.5 | Declaring `pointer_mode: abs` ahead of cutover poisoned main for every session | desired state and live state forced equal at push time |
| I.6 | Stale box `devwatch/Cargo.toml` → every build rewrites `Cargo.lock` → permanent phantom drift, misattributed by three sessions | shared mutable build dir, timestamp rsync, unlocked resolution |
| I.7 | `serve-https-spa.sh deploy` renders five manifests **from the deploying session's checkout**; near-miss silent revert of three stations; clobbers dark-launch overlays | last-writer-wins render from arbitrary source |
| I.8 | Two agents claimed patch number `0007-`; chat-based allocation repeated the bug one level up | check-then-create on a file namespace |
| I.9 | (Fixed 2026-08-24) a dry-run plan used to sync the checkout, moving everyone's drift baseline | read path that writes |
| I.10 | Rule-9 acceptance (framebuffer cursor match, click repaint) is manual and human-brokered per cutover | no machine-runnable acceptance |
| I.11 | `STAT` reported healthy while the drawn cursor was 1–2 px off | self-reported health without framebuffer evidence |

Common shape: **the unit of deployment is the whole box, but the unit of work is
one station.** Everything below re-cuts the system along station lines and moves
"does live match desired?" from a push gate to a convergence loop.

---

## 1. The model in one page

```
                 git push origin main  (any session, any time, no clearance)
                          │
                          ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  labhost: kh-reconciler  (one root systemd service,          │
   │  its own private clone /data/kh-reconciler/repo — the shared │
   │  /data/kernel-hive is no longer a deploy source)             │
   │                                                              │
   │  loop (poll origin/main, ~30 s):                             │
   │    1. fetch; if HEAD moved: build closures                   │
   │    2. for each RELEASE UNIT: desired closure hash vs         │
   │       applied stamp                                          │
   │    3. unit dirty & not leased & disruption window open       │
   │         → transactional cutover + acceptance + auto-rollback │
   │    4. publish per-unit state: applied / pending(reason) /    │
   │       failed(reason) / degraded(reason) / held(owner)        │
   └──────────────────────────────────────────────────────────────┘
```

**Release units** (the concurrency grain):

- one per station (61) — binary + launcher + daemon + env fixture + registry
  declaration + golden ref, as ONE closure;
- one `serve` unit — SPA bundle, HTTPS server files, rendered manifests;
- one `host-tools` unit — guards, labctl, host scripts (today's non-station
  pair rows).

**Desired state** is a pure function of the pushed commit (plus the gitignored
scrub map, as today): `kh-closure <station>` hashes the exact file set +
artifact refs a station runs under into one **closure hash**. **Live state** is
a per-unit stamp `stations/<s>/.applied` (closure hash + commit + timestamp +
acceptance result). Converged ⇔ hashes equal. The single global
`.deployed-rev` is retired; agents never need to read root-owned live files —
they ask `kh-reconciler status`, which runs on the box and reports over the
same door.

Why GitOps-on-one-box is not cargo cult: the observed failures are all
convergence failures (N writers, one target, order-sensitive installs). The
minimal machine that makes "push = deploy" literally true is a loop that owns
the writes, so sessions stop writing to live paths at all and the whole class
of "who else is mid-flight?" questions disappears. What we do **not** import:
no Kubernetes, no container images, no controller hierarchy, no webhook
infrastructure (a 30 s poll on a LAN box is free and has no inbound surface on
a public-gallery host). The implementation is one Python daemon + content-
addressed directories + symlink flips + systemd + the existing `kh-claim` —
every primitive already exists in this lab.

---

## 2. Killing the ordering paradox (I.2, I.5)

**Principle: a push gate may test only properties of the commit.** Live
divergence is a *reconciler* observation, reported as drift/health — never a
reason a commit cannot land.

The gate itself already agrees. Its per-language legs are scoped to the pushed
range — it prints "Rust lint == not owed" when the range contains no `.rs` /
`Cargo.*` — so range-scoping is an established, working pattern *inside this
very gate*. And the "generated-file drift" stage is really two checks welded
together: a genuine commit-local check (regenerate, compare bytes — observed
green today: `generate` leaves the tree clean) and `compare_live_labctl`, a
live-box comparison that ignores the gate's own scoping discipline and
evaluates all 63 entries regardless of what the push touches. It is not that
the gate lacks a scoping concept; this one stage is internally inconsistent
with the gate's design *and* tests the wrong layer. That makes the first fix
small and local, not a rewrite.

Concretely:

1. **Split the welded check.** Keep the byte-parity generated-drift check,
   commit-local and blocking, exactly as is. **Delete `compare_live_labctl`
   from `stations-registry.py check`** (and thus from the pre-push hook and
   `make station-registry-check`). It moves into the reconciler as the
   per-station drift probe, surfaced in `kh-reconciler status` and as a
   `/fleet` health column. Same code, opposite plumbing: a mismatch there is
   the loop's *to-do list*, not anyone's failure. This split is plausibly the
   single highest-value change in this proposal, and it is a few lines.
   1a. **Range-scoping hazard to fix while there**: a pushed range is only
   meaningful against the merge-base with *current* `main` — a branch cut from
   a stale base sweeps an unrelated wave's files into its range and gets billed
   for their lint (observed on another session today). The scoped legs should
   compute the range as `merge-base(origin/main, HEAD)..HEAD` after a fetch,
   not from wherever the branch happened to be cut.
2. **The remaining pre-push box gate ("a live file no commit accounts for")
   also moves to the reconciler** as the `hand-edit` drift class. During
   migration it survives as a scoped WARNING; once per-unit stamps exist it is
   strictly better answered by the loop, which can name the unit, the file and
   the owning claim. `SKIP_GATE=1` is then deleted — there is nothing left for
   it to skip, which is the only reliable way to stop it being learned.
3. **Declared-ahead state is normal, not poison.** A station whose registry
   declares `abs` while the box still runs `rel` is simply a dirty unit; the
   loop converges it. A station whose desired state is *unreachable* (golden
   ref not published yet, `pbs-state` forbids the declared binary, acceptance
   spec missing) is `pending(<reason>)` — visible, non-blocking, and validated
   **at commit time by pure functions**: `stations-registry.py validate` gains
   closure checks (§5) that catch incompatible *combinations* in CI, where
   they belong.
4. **`failed(reason)` is distinct from `pending(reason)`.** A rollout that was
   *attempted, failed acceptance and rolled back* (today's rhapsody) is a
   different state from one not yet tried: `pending` means "the loop will
   converge this when it can"; `failed` means "the loop tried, rolled back,
   and will NOT retry until the closure changes or an operator clears it" —
   with the acceptance evidence (§6) attached in the journal. An operator must
   be able to tell the two apart at a glance, and a `failed` unit blocks
   nobody else's push, which is the whole point.

This alone un-wedges today's `main` and is stage 1 of the migration (§10).

**How today's wedge actually cleared — the sharpest evidence in this
document.** It did not clear by advancing live state to match the
declarations. rhapsody's cutover was attempted and **failed on the live
station**: the pointer mechanism itself worked (the guest's own coordinate
read back exactly the commanded target), but every browser session after the
first timed out negotiating — 40 `SESSION_ACCEPTED`, zero completed
negotiations, input-router counters frozen at the first session's totals;
per-session sink state was never released at teardown. The station was rolled
back and is healthy. The gate then only went green because **three stations'
declarations were reverted to `rel`** — the declared state retreated to match
live, because live could not be advanced to match it.

Read what that means for a repo-wide live-state push gate: **it actively
punishes a failed rollout.** When a cutover fails and correctly rolls back,
the declaration is stranded ahead of reality, and the gate then blocks the
entire fleet's pushes *as a consequence of a rollback working properly*. The
safer and faster the rollback, the longer everyone is blocked — a perverse
incentive pointing straight at `SKIP_GATE=1`. Under this design the same event
is one line of reconciler state on one station
(`rhapsody: failed(acceptance — session negotiation)`), and nobody else's push
notices.

---

## 3. Per-station isolation and concurrency (I.1, I.7, I.9)

- **No shared mutable install source.** The reconciler deploys from its own
  clone at the exact pushed commit; `/data/kernel-hive` remains only as the
  base for `wt.sh` worktrees. `box-deploy.sh --apply`, `box-sync-push.sh` and
  the "ask every session before applying" ritual are deleted (§11).
- **Sessions and the loop share one lock namespace: `kh-claim`.** New class
  `station` (and `unit`): the reconciler takes `station/<s>` for the duration
  of a cutover; a session doing live work on a station takes the same claim
  first, and the loop then reports the unit `held(<session>)` and does not
  touch it. This inverts today's failure: instead of a deploy silently
  reverting an agent's in-flight live edit (the documented `box-deploy`
  hazard), the deploy *waits and says who it is waiting for*. Claims already
  have staleness/gc semantics; a leaked claim degrades to a visible stall, not
  a clobber.
- **N sessions "deploy" by pushing commits touching disjoint stations.** The
  loop serializes per unit (per-unit claim) and parallelizes across units only
  up to a small budget (default 1 station cutover at a time, §9 — this is a
  16-core box running 61 emulators and a public gallery; deploy concurrency is
  a cost knob, not a virtue). Two sessions touching the *same* station meet in
  git (merge conflict) — exactly where that conflict belongs.
- **Every install is idempotent and content-addressed** (§4), so re-running a
  converged unit is a no-op and a crashed cutover resumes from its journal,
  checkpoint-guard-style.
- **Read paths never write** (I.9 codified): `kh-reconciler status|plan` are
  pure reads of the stamps and the store.

---

## 4. Ordered, atomic, reversible station cutovers (I.3, I.4)

The fix for order-sensitivity is to stop doing ordered in-place installs at
all. A station's runnable state becomes a **versioned closure directory**:

```
/data/vms/kh-store/objects/sha256/<hash>          # immutable blobs: binaries,
                                                  # launchers, fixtures, goldens
/data/vms/streamhost/stations/<s>/
    releases/<closure-hash>/                      # a complete materialized set:
        qemu            -> ../../..../objects/…   #   hardlink/symlink per member
        launcher.sh
        streamhost
        station.env                               # scrub applied at materialize
        golden.ref                                # which golden object to run on
        closure.json                              # the manifest: every member,
                                                  #   its hash, its provenance
    current -> releases/<closure-hash>            # THE atomic switch
    .applied                                      # stamp: hash+commit+acceptance
```

The systemd unit, launcher and daemon resolve everything through
`current/`. A cutover is then:

1. **Materialize** the new closure beside the old one (no live file touched).
   Validation already ran at commit time; the reconciler re-validates the
   combination locally (binary ↔ device set ↔ golden ref, §5) and refuses at
   *plan* time otherwise.
2. **Classify disruption** from the closure diff: manifest-only /
   config-reload / restart-required / recapture-required. Non-disruptive
   members apply immediately; disruptive ones wait for a window (§9).
3. **Flip** `current` (one `rename(2)` of a symlink — atomic), restart the
   unit. There is no moment when a new launcher can meet an old binary or a
   new fixture an old daemon: the unit either starts under the complete new
   closure or never sees any of it. I.3 and I.4 become unrepresentable —
   "inert" no longer needs judging, because partial application cannot happen.
4. **Accept** (§6). On failure: flip `current` back, restart, mark
   `failed(<evidence>)`, keep the failed closure for post-mortem. Rollback
   is the same one-symlink flip — strictly simpler than today's already-good
   two-line reverts, and *complete* where a field-by-field revert is not:
   reverting rhapsody's backend without also restoring `SH_CURSOR_SCALE`
   (2.09 there, 2.7778 on macos753) would have left the station streaming
   with a silently wrong pointer gain and nothing failing. The closure flip
   makes that mistake unrepresentable — the whole set reverts or none of it
   does.
5. **Stamp** `.applied` and release the claim.

A crash at any step is resumable from the journal; nothing is deleted until
the new closure is accepted (checkpoint-guard's idiom, generalized).

Cost note: hardlinks into the object store make a "release" a few KB of
directory, so keeping the last N closures per station is free.

---

## 5. Goldens and OS images as git-managed artifacts (rule 6, `pbs-state`)

Goldens never enter the public repo. What enters git is the **reference**:

```
registry/goldens/<station>.json         # committed, small, reviewable
{
  "object":     "sha256:…",             # the store object (qcow2 set + vmstate,
                                        #   one tar or a per-file list)
  "capturedAt": "2026-08-30T…Z",
  "capturedBy": "cd-design",            # KH_SESSION
  "binary":     "sha256:… (qemu-kh-fork@<patch-series-hash>)",
  "deviceSetHash": "sha256:…",          # hash of the launcher's emitted -device
                                        #   set, normalized
  "vmstateFlavor": "plain | pbs-state", # Proxmox-only vmstate section?
  "restoreProven": true,                # checkpoint-guard's framebuffer proof
  "provenance": "recapture of sha256:… after abs-pointer cutover"
}
```

Objects live in `/data/vms/kh-store/objects/` (the 473 G pool; content-
addressed, immutable, never in git — licensing and size both satisfied).

- **Publish**: `checkpoint-guard recapture` gains a final `publish` step —
  hash the captured set into the store and write the new ref JSON into a
  world-readable outbox (`/data/vms/kh-store/outbox/<station>.json`). It does
  **not** commit: git authorship stays in CT950 with the session (standing
  rule), which `git add`s the ref into its branch like any other change. The
  operator ruled recapture cheap; this makes every recapture automatically an
  immutable, referenced, rollback-able artifact instead of a label overwrite.
- **Pin**: the station's closure includes `golden.ref` → the object. Changing
  goldens is a commit; the reconciler materializes the object into the
  station's release. Because the ref carries `binary` + `deviceSetHash` +
  `vmstateFlavor`, **`stations-registry.py validate` can refuse the
  incompatible combination in CI**: a launcher whose normalized device set no
  longer hashes to the ref's, a fork build named where `vmstateFlavor:
  pbs-state` demands the pve binary — both fail at commit time with a named
  reason, not at restore time on a live exhibit. This is the first time the
  binary/device-set/checkpoint "ONE combination" rule is machine-checkable
  rather than folklore.
- **Rollback**: revert the ref commit. The old object is still in the store;
  the reconciler flips back. GC (`kh-store gc`) keeps: every object referenced
  by any ref in the last K commits of main + any branch head, plus the newest
  2 per station regardless — and categorically refuses to delete the sole
  restore-proven golden of a live station.
- **Un-proven refs**: a ref with `restoreProven: false` (hand-written, or a
  publish whose proof step was skipped) makes the unit `pending(golden not
  restore-proven)` — the loop will not cut a live station over to it. Rule 6's
  spirit survives with less ceremony, matching the operator's "no proof gate"
  ruling: the guard's built-in restore proof is the proof; no extra ceremony
  is added on top.

Disk budget: at ~1–2 GB per golden, 61 stations × 2 retained generations ≈
120–250 GB of the 451 GB free. `kh-store gc` runs in the loop with a
high-water alarm at 70 % pool usage. This is the single biggest running cost
of the design and is worth it: it buys atomic golden rollback and the CI-time
combination check.

---

## 6. Automated acceptance (I.10, I.11 — rule 9 as code)

New: `scripts/host/station-accept.sh <station>` (callable by humans today,
by the reconciler in stage 4). Per-station spec in the registry
(`acceptance:` stanza): reference cursor sprite, a safe probe rectangle, the
expected repaint signature, timeouts scaled to the guest's era.

Sequence (all existing primitives — QMP screendump, `cursor-locate.py`
exact-match, `frame-compare.py`, streamhost `STAT`):

1. unit active; ticket check (`check-stream-tickets.py`) passes;
2. **framebuffer settle** then screendump A;
3. inject a pointer move to a commanded position; screendump B; **locate the
   cursor sprite and require it at the commanded position** — this is the I.11
   fix: the check is drawn-pixels-vs-commanded, so a converged read-back with a
   stale last draw fails;
4. click inside the safe rectangle; require a framebuffer delta (repaint) in
   bounded time; restore pointer to the parked position;
5. **session churn — mandatory, not optional.** Run steps 1–4 across
   **multiple sequential client sessions, including at least one abandoned
   mid-stream** (connect, start negotiating, drop without teardown), then
   require the *next* session to negotiate and pass the pointer/repaint
   probes, and require the input-router counters to have *advanced* past the
   first session's totals. This exists because of the rhapsody cutover
   failure: the pointer mechanism was perfect, the guest coordinate read back
   exactly the commanded target — and every session after the first timed out
   negotiating (40 `SESSION_ACCEPTED`, zero completed negotiations, counters
   frozen), because per-session sink state was never released at teardown.
   Every sandbox proof in that wave (7–14 targets, three observers, two runs,
   framebuffer-exact) used ONE session, so the method certified the exact
   defect by construction. A single-session acceptance run is not an
   acceptance run;
6. `STAT` counters sane *as corroboration only* — telemetry may support a
   pass, never substitute for the framebuffer (I.11); frozen-counter
   comparison across the churn of step 5 is the one place counters are
   load-bearing;
7. hold a `WakeLease` for the whole run (existing tool; never hand-rolled).

On failure the reconciler rolls back (§4.4) and marks `degraded` with the
failing screendumps attached to the journal — evidence, not logs.

**What stays human:** scene curation before a recapture (what the visitor
should see); aesthetic judgement ("the exhibit looks right"); first bring-up
of a new station (no reference sprites exist yet); licensing; and the
decision to *retire* anything. The gate proves "reacts correctly", never
"looks good".

---

## 7. Shared build state (I.6)

- **Deployment binaries are built only by the reconciler**, from its own clone
  at the pushed commit, with `cargo build --locked` — a stale workspace
  manifest becomes a loud build failure attributed to the exact commit, not
  phantom drift attributed to three innocent sessions. Output published to the
  object store keyed by (commit, crate); the station closure references the
  object. Same for QEMU fork builds, keyed by patch-series hash (the series
  file, §8).
- **The `build/` rsync mirror and its `.last-harvest` marker are deleted.**
  `build-deploy.sh`'s harvest/rsync logic goes with them; its per-station
  canary restart survives as `kh-reconciler apply <station>` semantics.
- **Sessions keep the warm shared cargo target for development speed** (it was
  never the drift source — the mirror was), but nothing a session builds is
  ever what ships; a canary of an unmerged branch runs in the session's
  sandbox stack, as now.
- Build cost: one release build per push that touches `streamhost/` (minutes,
  niced, serialized). Identical CPU to today, minus the repeated per-session
  rebuilds of the same commit.

## 8. Namespace allocation (I.8)

Generalize `kh-claim`'s "the claim is the proof" to file namespaces, with git
as the arbiter — the atomic operation is the *push*:

- **Ordered patch series**: replace ordinal filenames as the ordering with a
  quilt-style `qemu-patches/series` file. Two agents adding a patch now
  conflict *textually in git*, which merge tooling resolves — the number race
  cannot exist because the number no longer carries meaning.
- **Scalar ledgers** (ports, slots, VMIDs already pre-allocated for waves):
  `registry/allocations.json` + `kh-alloc take <class>` which picks
  next-free, writes the ledger and commits in one step. A racing allocation is
  a push rejection / merge conflict — fail-loud, never check-then-create. The
  existing "allocation ledger in one commit" wave practice becomes tooling.
- Runtime-lifetime things (displays, taps, live ports) stay in `kh-claim`
  (`/run`, dies with the box) — the split is durable-vs-runtime, and each
  namespace lives in exactly one of the two.

## 9. Visitor-facing safety (restarts are exhibits blinking)

The reconciler classifies every closure diff (§4.2) and schedules:

- **manifest/config only** → apply any time;
- **restart-required** → wait until the station is idle-paused (the
  idle-pause reconciler already knows) or has had no viewer for N minutes
  (streamhost viewer telemetry); take the station claim; during the restart
  the signaling plane serves a `restarting` state so the SPA tile shows an
  honest "exhibit resetting" card instead of a dead stream;
- **recapture-required** → never automatic; surfaces as `pending(needs
  recapture)` for a session/operator to run;
- **deferral cap**: a cutover deferred > 24 h (a station someone is *always*
  watching) escalates to the operator report rather than forcing itself;
  `kh-reconciler apply <station> --now` is the human override;
- **budget**: at most one disruptive cutover at a time fleet-wide, and none
  while pool CPU is above a threshold — a deploy must never be the reason a
  neighbouring live stream stutters;
- optional `maintenanceWindow` in the registry for stations the operator wants
  touched only at night.

`rollout: auto | hold` per station (default `auto`) is the only promotion
knob. `hold` replaces today's implicit "the fleet is not auto-promoted": the
default flips to auto because the acceptance gate + auto-rollback now provide
what manual promotion provided, but a station under investigation can be
pinned without blocking anyone's push.

---

## 10. Migration path (each stage lands alone, each is reversible)

Build order is by pain-per-effort; stages 1–2 are worth doing this week even
if nothing else ever ships.

1. **Un-wedge the gate** (hours): split the welded drift stage (§2.1) —
   keep byte-parity blocking, remove `compare_live_labctl` from `check` and
   keep it callable as `stations-registry.py drift` (advisory, like
   `facts-live`). Fix range computation to merge-base-with-current-main
   (§2.1a). Scope the remaining box-state check to WARNING-only for
   non-main branches. Deletes the `SKIP_GATE=1` trap. Reversible: one
   revert. **This — not the reconciler — is the first thing to build**: it
   alone unblocks concurrent independent sessions and is a precondition
   for everything else here.
2. **`station-accept.sh`** (a day): rule 9 as a command. Immediately useful
   to every human cutover; becomes the loop's gate later. No behaviour
   change anywhere.
3. **Reconciler v0 — read-only** (days): `kh-reconciler` service with its own
   clone, computing closures and printing per-unit drift
   (`status|plan`). Replaces "what does the box run?" forensics; agents stop
   needing to read root-owned stamps. No writes; trivially removable.
4. **Transactional per-station apply** (the core, ~a week): closure
   store + `releases/` + `current` symlink + journal + rollback +
   acceptance, exposed as `kh-reconciler apply <station>` — still
   *session-initiated*. This alone ends I.1/I.3/I.4 even before any
   automation: sessions stop hand-ordering installs. Migrate stations onto
   the `current/` layout in waves (the recapture-is-cheap ruling makes the
   per-station cutover itself cheap); a station not yet migrated keeps the
   old path, and the pair table shrinks as units migrate.
5. **Close the loop for opt-in units**: `rollout: auto` on a canary handful +
   the `serve` and `host-tools` units (docs/scripts auto-deploy is pure win).
   Watch for a week.
6. **Manifests to the loop** (I.7): rendered by the reconciler from the
   applied commit; `publish_manifests` deleted from `serve-https-spa.sh`;
   dark-launch overlays become declarative merge inputs with owning claims,
   so a render cannot clobber one.
7. **Builds to the loop** (I.6): `--locked`, store-keyed outputs; delete the
   `build/` mirror and harvest markers.
8. **Golden store + refs** (§5): `kh-store`, checkpoint-guard `publish`,
   registry combination validation. Migrate refs station-by-station at each
   natural recapture — no big-bang re-golden.
9. **Idle-aware scheduling** (§9) — needed before broad auto mode, since
   restarts are visitor-visible.
10. **Flip the default**: `rollout: auto` fleet-wide; retire
    `box-deploy.sh --apply` to a break-glass alias that just runs
    `kh-reconciler apply --all --now` with a warning.

**Build first: stages 1–4.** Stage 1 because main is wedged *now*; stage 4
because the transactional per-station apply is the piece every other stage
stands on, and it pays off before any automation exists.

---

## 11. What to DELETE (the compensating machinery)

Once the corresponding stage lands:

- `compare_live_labctl` in the push path, and `SKIP_GATE=1` (stage 1).
- The pre-push box-state ssh probe entirely (stage 5) — drift is the loop's
  report.
- `box-deploy.sh --apply` global sync + install; `box-sync-push.sh`; the
  "check with other sessions before applying" rule and its four-times-a-day
  human brokering (stage 5/10).
- `/data/kernel-hive` as an install source and its "clean mirror" contract
  policing (`box-repo.sh sync` refusal choreography) — it remains only as the
  worktree base (stage 4+).
- The global `.deployed-rev` (per-unit stamps replace it; also removes an
  agent-unreadable root-owned file from every workflow) (stage 3).
- `build/` rsync mirror, `.last-harvest`, `build-deploy.sh` harvest logic
  (stage 7).
- `serve-https-spa.sh publish_manifests` from session reach; the
  "re-arm darklaunch.d after SPA deploy" folk rule (stage 6).
- Manual patch-number etiquette; the in-chat allocation pattern (stage: §8,
  independent).
- Operating-rules text: rule 11's box-state paragraph, rule 12's
  "push is not a deploy" (inverted: *a push IS a deploy request*; restarts
  remain scheduled, not manual), the `box-deploy` mid-wave warnings in
  MEMORY/docs. Rules 4–9 (sandboxes, guards, claims, teardown, framebuffer)
  are load-bearing forever and are *strengthened*, not touched.

## 12. Failure modes this design introduces (and their mitigations)

- **A root daemon that writes the fleet.** Biggest new trust surface.
  Mitigated by: it only ever writes materialized closures + symlink flips
  (auditable journal per cutover), never shells out to arbitrary repo
  scripts without the closure hash naming them; one unit at a time; and it
  reads git only — it never commits, so no automation loop can author
  history.
- **A bad commit now propagates by itself.** Acceptance + auto-rollback +
  one-at-a-time + `rollout: hold` bound the blast radius to one station in
  `degraded`, which is strictly better than today's silent fleet-wide
  `--apply`. Residual risk: a change that passes acceptance but is wrong
  aesthetically — humans still watch the gallery.
- **Acceptance flapping** (marginal station passes/fails alternately):
  max-attempts (2) then `degraded-hold` — the loop stops touching it and
  says so. Never retry-forever on a visitor-facing exhibit.
- **Leaked claims stall convergence.** Visible as `held(<session>)` with age;
  `kh-claim gc` semantics already cover it. A stall that names its owner is
  the intended failure mode — it replaces a clobber.
- **Store GC eats a needed golden.** GC is refuse-by-default (§5): reachable
  refs + newest-2 + never-the-sole-proven-golden. GC bugs fail toward disk
  pressure, not data loss; the high-water alarm pages the operator instead
  of loosening the rules.
- **Reconciler down = deploys stop silently.** `here.sh` and `/fleet` gain a
  loop-heartbeat line; a stale heartbeat is loud. Manual fallback is
  `kh-reconciler apply` run by hand — the transactional path works without
  the loop.
- **Poll-based loop races a multi-commit story.** Two pushes seconds apart:
  the loop always converges to *latest* HEAD per unit — intermediate states
  may never be materialized. This is correct (desired state is a point, not
  a path) but must be documented, because today's habits assume each push is
  individually installed.
- **The private reconciler clone can wedge** (force-push, corrupt object).
  It is disposable by construction: `rm -rf` + re-clone is the documented
  fix; no state of record lives in it.

## 13. Running cost

- **Disk**: the object store, dominated by goldens — ~120–250 GB steady-state
  (§5), on a pool with 451 GB free. Closures and binaries are noise (hardlinks
  + tens of MB per commit actually deployed).
- **CPU**: idle loop ≈ zero (a fetch + hash compare every 30 s); one niced
  `--locked` release build per streamhost-touching push; acceptance ≈ two
  screendumps + one sprite match per cutover. All bounded by the
  one-cutover-at-a-time budget so the gallery never pays for a deploy.
- **Attention**: per-station acceptance specs must be authored (one-time, per
  station, mostly at natural recapture time) and maintained when a scene
  changes. This is the real ongoing cost, and it is the same work rule 9
  demands today — done once instead of per cutover.

## 14. Files and scripts (summary of the concrete surface)

| add | role |
|---|---|
| `scripts/host/kh-reconciler` (+ `kh-reconciler.service`) | the loop: status/plan/apply/journal |
| `scripts/host/kh-closure` | commit → per-unit closure hash + manifest |
| `scripts/host/kh-store` | object store: add/gc/verify/materialize |
| `scripts/host/station-accept.sh` | rule 9 as a command |
| `scripts/dev/kh-alloc` | git-arbited durable allocations |
| `registry/goldens/<station>.json` | golden refs (committed) |
| `registry/allocations.json`, `qemu-patches/series` | durable namespaces |
| registry stanzas: `acceptance:`, `rollout:`, `maintenanceWindow:` | per-station knobs |

| change | how |
|---|---|
| `scripts/stations_registry/cli.py` | drop `compare_live_labctl` from `check`; add `drift`; add closure/golden-combination validation |
| `scripts/lib/checkpoint-guard.sh` | `publish` step → store + outbox ref |
| `.claude/hooks/pre-push-gate.sh` | commit-properties only |
| `scripts/serve-https-spa.sh` | lose `publish_manifests` (loop-owned) |
| `scripts/dev/here.sh` | show loop heartbeat + per-unit states |

| delete (staged, §11) | `box-deploy.sh --apply` path, `box-sync-push.sh`, global `.deployed-rev`, `build/` mirror + `.last-harvest`, `SKIP_GATE=1` |

---

*Written from the 2026-08-30 incident evidence; grounded in
`box-deploy.sh`/`box-install.sh`/`box-repo.sh`, `stations_registry/cli.py`,
`serve-https-spa.sh`, `checkpoint-guard`, `kh-claim`, `wt.sh` as of
`main@1bb53874`.*

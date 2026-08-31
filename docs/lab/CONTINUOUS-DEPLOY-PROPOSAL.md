# Continuous deploy — push-to-main converges the box

**Status: APPROVED, being built.** Stage 1 (§10.1) is implemented on branch
`cd-build`; stage 2 onwards is still design. One approved change against the
original draft: the loop is **push-triggered, not polled** — §1.1 supersedes
the polling this document first proposed.

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
| I.12 | The QEMU fork was pushed from `qemu-patches/*.patch` by one agent; a second regenerated a patch and found the fork had moved underneath. `qemuBuild.forkCommit` still named the pre-push commit. **No symptom until a build attempt** | repo holds the *recipe*, somewhere else holds the *result* |
| I.13 | 42 serve-side files deployed 2026-08-30 21:42 to a process running since 2026-08-26 03:10 — the whole auth and walk-in plane, never loaded, on a publicly-open surface. Found only because arming the trigger required costing a restart | **no check exists** for the gap between *deployed* and *loaded* |
| I.14 | A sibling-import check excluded the one directory that needed it, and its docstring explained why the case could not arise; a route sat behind the visitor gate under a comment asserting it was in front. Two files, two authors, one night | **prose asserting an invariant the code does not have** — it pre-empts the check |

I.12 is the day's third two-sources-of-truth failure — after registry
declarations vs the live box (I.2/I.5) and rendered manifests vs the registry
(I.7) — and it has a feature the other two lack: **it is invisible until someone
tries to build.** `git apply` of a file-creating patch fails only once the file
exists, so a fork that has moved under the series shows nothing at all, while
the other two at least render a diff a human can look at. §2.5 answers it.

Common shape: **the unit of deployment is the whole box, but the unit of work is
one station.** Everything below re-cuts the system along station lines and moves
"does live match desired?" from a push gate to a convergence loop.

---

## 1. The model in one page

```
                 git push origin main  (any session, any time, no clearance)
                          │
                          ▼   GitHub-side trigger (§1.1): a repo webhook, plus a
                          │   post-CI Actions ping — a signed HINT, never a
                          ▼   command. Slow timer and `poke` are the backstops.
   ┌──────────────────────────────────────────────────────────────┐
   │  labhost: kh-reconciler  (one root systemd service,          │
   │  its own private clone /data/kh-reconciler/repo — the shared │
   │  /data/kernel-hive is no longer a deploy source)             │
   │                                                              │
   │  on wakeup (webhook / Actions ping / slow timer / `poke`) —  │
   │  never on a sha the wakeup supplied:                         │
   │    1. fetch origin/main ITSELF; if HEAD moved: build closures│
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
- one `serve-code` unit — SPA bundle, HTTPS server + serve-side Python,
  PKI scripts. Dirty only when the *commit* changes. Its closure keeps the
  last N asset generations alongside the current one: a PWA client
  mid-session holds `index-<hash>.js`, and a flip that deletes old hashed
  assets 404s every lazily-fetched chunk (`sw.js` is network-first, so the
  risk is vanished assets, not a stale worker — and a wholesale webroot swap
  is exactly how the `boot/` tree was once lost for a week);
- one `serve-manifests` unit — the rendered runtime documents, a pure
  function of *applied station state*, applied as cheap atomic per-file
  writes. Split from `serve-code` deliberately: if manifests were members of
  one serve closure, every station cutover would dirty it — 61 serve flips
  per wave, each republishing an unchanged SPA bundle and each paying the
  serve unit's (strictest, §9) disruption class;
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

**A third category: live state of record — owned by neither git nor the
loop.** The document so far has two kinds of bytes: desired state (a function
of the commit) and derived artifacts (loop-rendered). There is a third, and
the serve units sit directly on top of its most dangerous instance:
`/data/vms/streamhost/serve/auth-state.json` (root 0600) holds every account,
every passkey credential, every walk-in handle, the walk-in access switch and
the drain flag — *inside* the directory the serve units are defined over, a
few lines from where today's `deploy` does `rm -rf` on sibling trees.
`darklaunch.d/` overlays belong to the same category. Members of this
category are **never closure members, never materialized, never rolled back,
never GC'd**: the reconciler carries an explicit deny-list of
state-of-record paths and structurally refuses to write, replace or remove
under them, turning today's folk rule ("never `rm auth-state.json`", plus
the guarded `reset-auth.sh`) into a property of the only daemon that writes.
This deserves at least the seriousness the golden store gets (§5), for a
stronger reason: a golden can be recaptured; **a passkey cannot be
regenerated, and a walk-in handle IS the account.**

**And a named second exception to "desired state is a function of the
commit": the walk-in access switch.** `access: closed|invited|open` and
`drain` live in that same file, with the `WALKIN_OPEN` env floor able only
to lower them. They are operator runtime state, out of scope for
convergence, **permanently** — because the failure mode of a future
reconciler deciding the switch is registry-derived is the worst one
available: a `git push` opening the walk-in plane to the internet. The
scrub map was exception one; this is exception two; the list is closed and
additions to it are a design change, not a config change.

Why GitOps-on-one-box is not cargo cult: the observed failures are all
convergence failures (N writers, one target, order-sensitive installs). The
minimal machine that makes "push = deploy" literally true is a loop that owns
the writes, so sessions stop writing to live paths at all and the whole class
of "who else is mid-flight?" questions disappears. What we do **not** import:
no Kubernetes, no container images, no controller hierarchy. (This draft also
declined a webhook, on the grounds that a 30 s poll is free and adds no inbound
surface. The operator overruled that: polling is not the mechanism — a push must
converge the box now. §1.1 replaces it, and it does carry the inbound surface
this paragraph was right to be wary of, which is precisely why that endpoint is
a hint receiver and nothing else.) The implementation is one Python daemon + content-
addressed directories + symlink flips + systemd + the existing `kh-claim` —
every primitive already exists in this lab.

---

## 1.1 The trigger — push-driven, not polled

**Operator ruling: a push must converge the box immediately; polling is not the
mechanism.** This supersedes the ~30 s poll of the first draft.

### Why the trigger has to be GitHub-side

Pushes reach `main` from three places: the `osgallery-dev` host (most of them),
remote Claude cloud sessions, and the operator's workstation. A client-side
`post-push` hook covers exactly the machine it is installed on and — worse —
fails *silently* on the other two: a trigger with a per-machine install step is
a trigger that is off for whoever set their environment up last, and its being
off looks exactly like nothing having been pushed. GitHub sees all three
identically, because all three end at the same `refs/heads/main` update. So the
trigger lives where a push is a push.

### Two mechanisms, each with a distinct job

Both are used, and they are not redundant — they answer different questions.

| | **Repo webhook** | **Actions workflow on push to `main`** |
|---|---|---|
| role | **the trigger** | **audit trail + delivery backstop** |
| latency | ~1 s from the push | after CI, minutes |
| cost | none | Actions minutes |
| fires | on the ref update, always | on the ref update, once scheduled |
| buys us | immediate convergence | a visible per-commit record that a deploy was requested, and a second hint if the first delivery was dropped |

The webhook is the mechanism. The Actions job exists because **a missed webhook
delivery is missed silently** — the endpoint restarting during a deploy of
itself is the ordinary case, not the exotic one — and because "a deploy was
requested for `<sha>` at `<time>`" is exactly the forensic record the
2026-08-30 wave did not have. It is scheduled *after* the quality jobs, so its
ping also carries "CI was green for this commit"; the reconciler journals that
and does **not** gate on it. A red CI run still converges: the box's own
acceptance gate (§6) is what decides safety, and making GitHub CI load-bearing
for exhibit availability would import a new outage source for no safety gain.

Both call the **same endpoint** with the **same signature scheme**, so there is
exactly one verification path to reason about.

**GAP, OPEN AS OF 2026-08-31: the Actions ping is NOT scheduled after CI.**
`.github/workflows/deploy-hint.yml` triggers on `push` with no ordering against
the quality workflows, so in practice it races the webhook by a few seconds
rather than following a green build — measured at 4–6 seconds behind on every
real push so far. The table above says this ping "doubles as *CI was green for
this commit*"; **as written it carries no such assurance.** The audit-trail half
of its job is therefore weaker than this section documents: it records that a
deploy was requested, not that the commit was healthy when it was.

Fixing it is a real change rather than a one-line addition: `needs:` orders jobs
*within* one workflow, so cross-workflow ordering requires a `workflow_run`
trigger on the quality workflow's completion, which also changes what the ping
means when CI is skipped or cancelled. It was deliberately not folded into the
arming work, because "arm the trigger" does not authorise changing what the
trigger asserts.

**Until it is fixed, nothing may treat that ping as a quality signal.** The
danger is specific and future-facing: a later change wiring convergence to
"converge only on an Actions-sourced hint, because CI passed" would be trusting
something that never checked. The reconciler's own acceptance gate (§6) is what
decides safety, and that is deliberate — see the paragraph above on why GitHub
CI is not made load-bearing for exhibit availability.

### The endpoint

`POST https://kernelhive.madekivi.fi/kh/deploy-hint`, served by the existing
HTTPS plane. Its complete job is *validate, then bump a timestamp*. It runs no
git operation, spawns no process, reads no repository, and holds no privilege
that could deploy anything. The reconciler (root) watches the wakeup file with
inotify; the endpoint (unprivileged, public) can only touch it. That split is
the security design: **the internet-facing half cannot deploy, and the half
that can deploy is not internet-facing.**

Checks in order, cheapest and most-rejecting first — nothing does work before
the signature verifies:

1. method, path, and a `Content-Length` cap; an over-cap body is rejected
   outright (the Actions ping is tiny and covers the rare over-cap push
   payload);
2. rate limit — a token bucket, counted *before* the HMAC, so signature
   verification cannot itself become the flood;
3. `X-Hub-Signature-256`: HMAC-SHA256 over the **raw body**, compared with
   `hmac.compare_digest`. Two keys are configured, one per mechanism, and **the
   source is identified by which key verified, never by a field in the
   payload** — so "which trigger fired", the very signal §1.1's observability
   rests on, cannot be forged by whoever can reach the URL. Failure → `401`,
   no detail, and no key material in any log;
4. replay: `X-GitHub-Delivery` in a bounded, TTL'd seen-set; the Actions ping
   additionally carries a timestamp checked against a short window. A replay is
   *also* harmless by construction (below) — the dedupe is defence in depth,
   not the load-bearing part;
5. ref filter: `refs/heads/main` only. The `ref` field is parsed **solely in
   order to drop** everything else; an unparseable body is dropped, never
   guessed at;
6. bump the wakeup file's mtime, append one bounded journal line, return `202`.

### The trigger is a HINT, never an instruction

This is the invariant that makes a public endpoint acceptable at all:

> **The endpoint cannot express *what* to deploy. It can only say "look
> again".**

On wakeup the reconciler fetches `origin/main` in its own clone and converges to
whatever it finds — the same thing it would have done on the slow timer. It
never takes a sha, a ref, a station name or a path from the payload. Where a
payload sha is present it is used **for the journal only**, and only after
`git merge-base --is-ancestor <hint-sha> <fetched origin/main>` confirms it is
in the history actually fetched; a hint sha that is not an ancestor is recorded
as an anomaly and changes nothing about what is deployed. The worst a forged,
replayed or hostile signed request can therefore achieve is **one extra fetch of
`origin/main`**, and the rate limiter bounds even that.

**Authorisation is write access to the repo, and nothing else.** Anyone who can
push to `main` can cause a deploy, because the push *is* the deploy request.
No per-user auth, no allowlist, no identity plumbed to the box — both mechanisms
give exactly this for free, and a second authorisation layer here would be one
more list to maintain and to get wrong. What the box authenticates is *"this
came from GitHub, for this repo"*, not *"who pushed"*; git already records who
pushed, and the reconciler journals the commit it converged to.

### The slow periodic reconcile stays — as a liveness backstop

Not as the mechanism. Deliveries do get missed: an endpoint restart, a network
blip, a GitHub incident. Without a floor, a missed delivery means the box
quietly stops converging *with nothing reporting it* — the exact shape of every
indicator in §0 that was true and meant nothing. So `kh-reconciler` also wakes
on a long interval (default 30 min), and:

- every convergence records **what triggered it**: `webhook` / `actions` /
  `timer` / `manual`;
- `kh-reconciler status`, `here.sh` and `/fleet` show the last convergence, its
  trigger, and **the age of the last webhook-sourced one**;
- so **"we have been running on the backstop" is a visible state.** Convergences
  arriving only as `timer` or `actions` while commits are landing means the
  webhook is broken, and it says so — instead of looking healthy at a coarser
  latency, which is how a dead trigger would otherwise hide for weeks.

Manual trigger for operators and agents: `ssh lab 'kh-reconciler poke'`, and
`kh-reconciler apply <station> --now` for the impatient single-unit case. Both
go through the same wakeup path, so the manual case is not a second code path.

### Public-repo hygiene (rule 1)

The workflow file is world-readable. It may contain the gallery domain
`kernelhive.madekivi.fi` — the one domain committed on purpose — the public
endpoint path, and `${{ secrets.… }}` references. It must contain no internal
hostname, no IP, no labhost path, no station identity and no secret value. The
webhook secret lives in the repo's webhook configuration, the Actions key in
repo secrets; the box keeps its copies outside the repo, beside the other
gitignored local values.

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
negotiations, input-router counters frozen at the first session's totals. The
station was rolled back and is healthy.

**CORRECTED 2026-08-31, and the correction matters more than the original
claim.** This document previously attributed that failure to *per-session sink
state never released at teardown*. **That cause did not happen.** A four-run
control matrix established the real one: **daemon-wide QMP contention caused by
the observation harness.** The observer held QEMU's monitor for its whole run;
QEMU serves one monitor at a time; the idle pauser's `cont` hit its 2 s timeout
and returned `EAGAIN`; `IdlePauser::session_started()` holds the `st` mutex
*across* that blocking call, and `handle_session` awaits it before any keyframe
work — so sessions queued and blew the SPA's negotiation timeout. `dbus-rel`,
which builds **no `InputRouter` at all**, fails identically with the holder
running. The original isolation compared the new backend *with* the observer
against the old one *without* it.

The old explanation was also impossible from the code side, independently
shown: `RealtimeInputSink` has **no session lifecycle hook**, and `InputRouter`
is built once per station in `transport::serve`, **outside the accept loop** —
there is no per-session sink state that could leak.

So the sharpest incident in this document is not a station that broke. **It is
an instrument that broke the station it was measuring, and a comparison that
ran the instrument on only one side.** That is a stronger warrant for §6 than
the original reading, not a weaker one — see the rule there about never holding
an exclusive resource, and the same-pass control that is what finally told the
two apart. The gate then only went green because **three stations'
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

## 2.5 Recipe here, result somewhere else (I.12)

**The general class.** Some artifacts live in this repo as a *recipe* while the
thing people consume is a *result* produced from it and published elsewhere. The
QEMU fork is the live instance: `streamhost/qemu-patches/*.patch` is the declared
source of truth, `github.com/Wnt/qemu@kernel-hive` is the published, consumable
form. Nothing forces them equal, and on 2026-08-30 they stopped being equal —
one agent pushed the fork from the series, another regenerated a patch and found
the fork had moved underneath.

**Why this one is worse than I.2 and I.7.** Both of those drift *visibly*: the
registry-vs-live case and the manifest-vs-registry case each render a diff a
human or a check can look at. This one renders nothing. `git apply` of a
file-creating patch fails only when the file already exists, so a fork that has
moved under the series has **no symptom until someone tries to build** — and a
build attempt is the most expensive possible detector. Everything between the
divergence and the next build is a period in which the repo confidently says two
contradictory things and nothing anywhere disagrees.

**The requirement, stated generally:** wherever the repo holds a recipe and
something else holds the result, there must be a **cheap, on-demand check that
answers "does the published form still match the source form?" without a build
attempt** — reporting drift as drift. Expect the class to recur; state it once
here rather than per artifact.

**Landed (stage 1): `scripts/lint/published-form-drift.py`**, in the same stage
and for the same reason as §2.1 — this is live divergence, so it is a reconciler
concern reported as drift and **never a push gate**. Wiring it into the pre-push
hook would recreate exactly the wedge §2 removes: whether an external published
artifact currently matches is a property of the world at this instant, shared by
every session, and unsatisfiable by the author of an unrelated change. Two legs,
neither of which builds anything:

1. **Pointer freshness** — one `git ls-remote` (no clone, ~1 s): has the published
   branch moved since anything in the repo recorded a commit on it? The two kinds
   of recorded pointer are judged differently, because a check that cries wolf
   gets ignored: the `third_party/qemu-kernel-hive` **gitlink is a pin** and must
   *equal* the branch head, while a station's `qemuBuild.forkCommit` is the
   **base** its patches were verified against and must merely be an *ancestor* —
   so a difference there is reported `UNVERIFIED`, not drift.
2. **Containment** — `git apply --reverse --check` of each declared patch against
   the published tree. Reverse-apply succeeds only if every post-image hunk is
   present verbatim, which is precisely "the published form carries this patch,
   byte for byte" — proven with no forward apply, no base commit and no build.
   Needs a fork clone; without one it **SKIPs loudly** and names the command.

**Known state as of 2026-08-30, recorded so nobody re-derives it.** The check
reports real drift today — the published branch is ahead of the submodule
gitlink. Reconciling those pointers belongs to the deploy stream, inside a fork
reconciliation currently blocked on a device fix; the report's job is to name
them, not to fix them. On where it can decide: the **CT950 checkout has the
submodule initialised, so the containment leg decides there**; the box checkout
does not (it holds an unpacked tree with no `.git`), and a `wt.sh` worktree
inherits the box clone as its superproject, so a worktree needs `--fork`.

**A probe can answer confidently for a reason unrelated to the question.** Worth
recording next to the four false-health indicators of §6, because it is the same
family one layer down: `git rev-parse --is-inside-work-tree` returns **true**
inside the box's unpacked copy — a directory with no `.git` at all — because it
sits inside the *superproject's* work tree, and `--git-dir` is fooled the same
way, confidently naming the superproject's git dir. Either probe used as "is
this a real repository?" is wrong on the box **in the direction that looks
fine**. The discriminators that actually answer it are the presence of `.git`
and the leading `-` in `git submodule status`. That is now a fifth measured
instance of the pattern: a true signal, produced by a mechanism unrelated to the
thing being tested, that reassures instead of warning.

**A recorded pointer to a mutable ref goes stale in silence.** That is the second
half of I.12 and it generalizes past this artifact: `qemuBuild.forkCommit` still
named the pre-push commit and nothing noticed, because nothing was watching a
value that only an external branch could invalidate. Any reference to an external
mutable ref needs either **verification at use** or **content addressing**, so
that staleness is *detectable* rather than assumed. The object store of §5 is the
content-addressed answer for goldens and binaries; the fork pointers are the
outstanding case, and the freshness leg is the interim verification-at-use.

**Failing loudly at the build is a mitigation, not a fix — and the distinction
matters.** The station build script was made fork-aware the same day: where the
clone already has the file it compares, and fails loudly on real divergence
rather than skipping or re-applying. That converted a silent wrong-build into a
stop, and its author's own summary — *"safe, not resolved"* — is exactly right.
It removes the silence; it does not remove the second source of truth. Only
generating one representation from the other, or content-addressing the pointer,
removes the class. Until then the check above is how we see the drift, and the
loud build failure is how we survive it.

---

## 2.6 Deployed is not loaded (I.13)

**The drift class with no check at all.** §2.1 moved a live-state comparison out
of the push path; §2.5 added one for a published artifact. This one is different
in kind: it is not that a check was in the wrong place, or that a check was
wrong. **No check exists**, in any plane, for the gap between *the bytes are on
the box* and *the running process is executing them*.

**The instance, measured 2026-08-31 while preparing to arm the trigger.** The
`osgallery-https` process had been running since **2026-08-26 03:10**. Forty-two
serve-side `.py` files had been written to `/data/vms/streamhost/serve/` on
**2026-08-30 21:42**, at commit `0cb355b0` — the entire auth plane (`service.py`,
`store.py`, `passkeys.py`, `routes.py`, `tickets.py`) and the entire walk-in
plane (`broker.py`, `cell.py`, `claims.py`, `clone.py`). Five days of code,
deployed and never loaded, on a plane whose walk-in access switch reads `open`,
with thirteen walk-in clones running and an `auth-state.json` written that
morning.

**Every existing signal was green, and each was truthfully answering a different
question.** `box-install.sh` correctly reported the files installed — they were.
`.deployed-rev` correctly named `0cb355b0` — that is what was deployed. The
pre-push gate's box-state stage correctly said live matches the box checkout —
it does. `systemctl is-active` correctly said `active` — it is. Not one of them
is wrong. The question none of them asks is whether the process serving requests
right now was started *after* the bytes it is supposed to be running. That is the
same shape as every other finding in this document — a true indicator that means
nothing — raised from the level of a probe to the level of a whole plane.

The design already names the *cause* in §9 ("shipping serve-side Python without
a restart is a silent no-op — the new code lands, the running process never
loads it, nothing reports it") and answers it for FUTURE deploys by treating a
serve-code change as restart-required by definition. What §9 does not do is
detect the condition that already exists. A reconciler that only prevents new
instances of a fault, while the box is presently deep inside one, is reporting
on a world it has not looked at.

**So `loaded-drift` is a reported class, per serve-side unit:** compare the
running process's start time against the mtimes of the unit's materialized
members, and report `applied-but-not-loaded(<n> files, oldest <age>)`. It is
cheap — one `ps` and one `find` — and it belongs in `kh-reconciler status` and
in `here.sh` beside the loop heartbeat, because the operator-facing question
"is the box running what we think it is?" currently has no honest answer.

**Two things the first real use of this check taught, both about ROLLBACK.**

*The last thing deployed is not the last thing that ran, and only one of them is
a rollback target.* Restoring the previously-DEPLOYED serve tree would have
restored code that had also never been loaded — rolling back to something
unproven. The only tree with five days of production evidence behind it was the
one deployed a minute before the process started, and identifying it required
reading the deploy history against the process start time, which is the same
comparison this check performs. **A `loaded-drift` report is therefore also how
you find your rollback target**, and a plane that cannot say which commit it is
running cannot say what to go back to.

*And the backup you assume exists may not cover the plane you are touching.*
`box-install.sh` saves the previous bytes of every row it writes into
`.deploys/<ts>-<sha>/backup/`. The auth and walk-in planes do not arrive that
way: `serve-https-spa.sh deploy` ships them wholesale with `rm -rf` plus a tar
extract and leaves **no backup at all** — the newest `.deploys` copy of
`serve/auth` was six days older than the deploy in question. The recovery path
for those planes is git and nothing else. Anything that treats `$SERVE_DIR` as a
replaceable tree has to enumerate what in it is not part of the deploy *and*
what of it is not recoverable afterwards.

**Two notes on how this was found, because the method generalizes.**

First, **nobody was looking for it.** It surfaced because arming the trigger
required knowing what a serve restart would cost, and answering that meant
inventorying what a restart would load. The unclaimed-rows finding of stage 3
came the same way: `rows` exists because a reconciler must know it owns every
deployed file *before* it may write, and asking that question found 107 files
nobody owned. **A design whose preconditions force an inventory is doing work
before it ever runs** — which is an argument for stating preconditions as
executable refusals rather than as prose, since prose is never made to answer.

Second, it is an argument against arming anything on a schedule. The restart
that would have armed the endpoint was, unexamined, also a swap of five days of
auth-plane code on a live public surface. Those two actions have nothing to do
with each other except that one requires the other, and a process that treats
"restart the serve unit" as an implementation detail of "turn on the webhook"
would have performed the second while intending only the first.

---

## 2.7 Prose asserting an invariant the code does not have (I.14)

**A distinct hazard, and worse than an absent comment.** Everything else in this
document is a signal that is *true about the wrong question* — a green
`is-active`, a frozen counter, a fractional mtime. This one is different: it is a
statement that is simply false, written by an author who believed it, sitting
where a reader will accept it instead of checking. **It pre-empts the check. A
reader who was about to verify stops, having been told why they need not.**

**Two instances on 2026-08-31, in two files, by two different authors.**

1. `deploy-pair-imports.py` excluded same-directory siblings from its import
   check and said why: *"a sibling in the importer's own directory (which the
   pair loops already carry as a tree)"*. True of `scripts/labctl.d/`,
   `scripts/serve/auth/`, `authui/` and `walkin/`. **False of top-level
   `scripts/serve/`**, which is a static name list — the one directory the
   sentence did not enumerate, and the one where a new module beside a deployed
   one gets no pair row. `deploy_hint.py` landed exactly there.
2. The `/kh/deploy-hint` route carried the comment *"deliberately OUTSIDE the
   public gate"* while being dispatched **after** `_public_gate`. Every GitHub
   delivery was 401 and the trigger could never have fired. The comment stated
   the requirement correctly and the code did the opposite; nothing compared
   them.

Note what these have in common beyond being wrong: **both comments were correct
as statements of intent.** Neither author misunderstood the requirement. The
sibling exclusion was right about the directories in mind; the route comment was
right about where the route belonged. What failed is that an intent written in
prose and an intent expressed in code drift independently, and only one of them
runs.

**The generalisation: a comment that explains why a case is impossible is a
claim, and claims about invariants belong in tests.** Prose that merely
*describes* behaviour is fine and this document is full of it. What rots is an
ENUMERATION — "this holds for A, B and C", "these directories are covered", "this
runs before that" — because code later moves into a D the list never knew about,
and the list has no way to notice. The more carefully the impossibility is
argued, the more effective it is at stopping the next reader from looking.

**So the shape of the fix matters as much as the fix.** Both were repaired by
making the claim executable rather than by rewriting the sentence:

- the sibling case now fires on a **positive contradiction** — *this paired file
  imports that file, and that file has no pair* — so a directory genuinely
  covered by a tree loop stays silent **without the check needing to know which
  loops exist**. The enumeration that rotted is gone, not corrected;
- the route's placement is asserted by exercising it on the listener that
  matters, and the comment now says *"verify this route on the PUBLIC listener
  or you have tested nothing"* — an instruction to check, where the old one was
  a reason not to.

A blanket rule ("every file must have a pair", "no comment may claim an
invariant") would have been silenced within a week, which is the failure mode
`deploy-pair-imports.py`'s own docstring already warns about. The test is the
place for a claim precisely because a test cannot be believed without running.

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
- **Derived artifacts are rendered by the loop, never published by a
  session** — the I.7 near-miss became a real one today, in slow motion: the
  runtime manifests were rendered with `pointerRel=false` for three stations
  from a registry that was *correct at render time*; the cutover then failed
  and rolled back, and what put `pointerRel=true` back was
  `serve-https-spa.sh manifests` run from a rebased **session checkout** —
  i.e. another instance of the very mechanism stage 6 deletes. The fix for a
  bad session-published render was a second session-published render that
  happened to be correct: **luck, not a safeguard.** Had nobody re-run it,
  the SPA would have served the wrong pointer mode for three stations
  running a relative pointer — two-sources-disagreeing in its most
  visitor-facing form, produced by a render that was right when made and
  wrong ten minutes later. A manifest rendered at moment T and published to
  a shared location is stale the instant anything upstream moves; the only
  correct renderer is the convergence loop itself, rendering from the
  *applied* state as part of each reconcile (§10 stage 6).
- **Stronger still: prefer read-time derivation over render-and-publish at
  all.** The walk-in plane already proves the pattern on this box:
  `/walkin/manifest.json` is not a published artifact — `gate.
  walkin_manifest()` computes the projection per request from the gallery
  manifest plus the caller's own claim, so it *cannot go stale and cannot
  leak a field the allowlist does not name*. That is structurally stronger
  against I.7 than any amount of loop discipline. Publish an artifact only
  where read-time derivation is too expensive; the obvious candidate to
  move is `fleet-table.json` — 187 KB derived from the same registry, and
  the one document that actually carried today's stale rows.

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

**Serve-unit acceptance already exists — reuse it.**
`scripts/e2e/walkin-shape-probe.mjs` and `scripts/e2e/live-gallery-check.mjs`
(on `main` as of `9e09844a`) drive real Chromium against the deployed origin
and assert that both visitor classes render correctly, including that neither
is stuck on "Loading the collection…". They are the serve units' acceptance
gate as they stand. Take their calibration too: **assert "it rendered", never
a count** — the first live run of that check failed on "only 31 cards", which
was the era fold working as designed (31 folded, 68 expanded), not a
regression. An acceptance that asserts a total flaps whenever the lineup or a
fold default changes, and a flapping gate is how gates get bypassed.

**The boundary is the point — prove the thing you ship, through the path it
ships on.** The rhapsody post-mortem's sharpest finding is not the session
leak; it is *where the proof boundary sat*. The wave's sandbox harnesses spoke
the control protocol to QEMU's chardev directly, with their own client and
with `streamhost` **not running in the rig**. 8/8 and 6/6 targets, three
observers, two runs, framebuffer-exact — all validating the mechanism and the
device, while the component that actually shipped (the daemon's sink) sat
outside the proof boundary entirely. The only untested component was the only
one that broke, and no amount of repetition or session churn could have
reached it — the harness could not touch it at any repetition count. This is a
*boundary* gap, not a sampling gap.

Nor is it a discipline failure a better checklist fixes: five independent,
rigorous agents each drew the boundary one component short of what ships, and
a coordinator reviewing all five did not notice. That is what happens whenever
the **author of a change also chooses the boundary of its proof.** It is the
case for `station-accept.sh` existing at all: an acceptance gate that runs the
same way for every station, at the real boundary, is structurally immune to
author-drawn boundaries — and once the reconciler is the one running it,
"proven" stops being a claim an author makes about their own work and becomes
a property the system observes.

**The acceptance boundary is therefore defined, fixed and non-negotiable:
browser client → SPA/signaling → streamhost daemon → input sink → device →
guest → framebuffer.** Evidence that does not traverse this whole path is a
component test — valuable during development, *never* acceptance — and the
gate refuses to certify a station on it. Concretely, the probe client speaks
the same WebTransport protocol a visitor's browser speaks, to the same daemon
process the station will run; it never talks to the chardev, the ctl socket or
the device directly.

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
   frozen). The cause was **daemon-wide QMP contention from the observation
   harness serializing session start-up**, not a per-session leak (§2, corrected
   2026-08-31). Every sandbox proof in that wave (7–14 targets, three observers,
   two runs, framebuffer-exact) used ONE session, so the method certified the
   exact defect by construction. A single-session acceptance run is not an
   acceptance run. Churn is a corollary of the boundary rule — "prove the thing
   you ship, through the path it ships on" is the lesson; "run it more than
   once" follows from it. The churn must be *sequential and sparse*, not a
   hammer — see the observation-rate bound below.
   **What the corrected cause does and does not justify, stated plainly so the
   requirement is not quietly propped up by evidence that no longer supports
   it.** *Sequential* churn is confirmed and strengthened: a daemon-wide stall
   in session start-up is invisible to one session by construction, and shows up
   in the second. The **abandoned** session is a different matter — its original
   warrant was the leak-at-teardown story, and that story is gone. It stays in
   the spec because a client vanishing without an orderly close is a real and
   cheap thing to test, and because the orderly path is the one that already
   worked; but it is now a **precaution, not an evidenced requirement**, and
   anyone who finds it costly should know it is defending a class rather than a
   measured defect;
6. `STAT` counters sane *as corroboration only* — telemetry may support a
   pass, never substitute for the framebuffer (I.11); frozen-counter
   comparison across the churn of step 5 is the one place counters are
   load-bearing;
7. hold a `WakeLease` for the whole run (existing tool; never hand-rolled).

**The acceptance signal is inter-frame change, never stream-surface
properties.** There is prior art on this box for driving the shipping path
from CT950 — `scripts/e2e/idle-wake-browser-probe.mjs` and
`scripts/e2e/paused-sink-resume-probe.mjs` drive the real SPA in a real
browser, and they already encode the rule this section needs: `videoWidth`,
`readyState` and non-black-percentage **all pass on a stream that has
stopped** — a paused element showing a stale frame satisfies every one of
them. Motion is the only honest signal. A gate built on stream-surface
properties would happily certify a *frozen* stream — precisely the state
rhapsody's second session would have presented. This is one of *four*
independent instances of the same class today, each at a different layer: STAT healthy while
the drawn cursor sat 1–2 px off (I.11); input-router counters frozen at the
first session's totals while 40 sessions failed to negotiate (§2); and a
video element that is sized, ready and non-black while showing a stopped
stream; and an *empty log* from an observer that was silently holding the
very resource under contention (below). Four indicators, at four layers, each
true and each meaning nothing — and the second and fourth are both cases a
same-pass control station catches immediately. So the probe treats
`videoWidth`/`readyState`/non-black as necessary-but-insufficient
*preconditions*, and the evidence is successive-frame comparison: the
commanded interaction must produce pixel change in the expected place, in
bounded time. `station-accept.sh`'s browser-side leg starts from those two
existing probes, not a new harness — they already traverse the §6 boundary.

**The gate must bound its own observation rate.** Observation perturbs the
thing observed: screendumping a station every second is *itself* enough to
stop a session negotiating — identified during today's wave at the cost of two
failed runs. An acceptance check that samples the framebuffer aggressively can
manufacture the exact failure it tests for, then "correctly" roll back a
healthy deploy. So the sampling interval is an explicit, per-station
`acceptance:` parameter with a documented failure mode on both sides — too
sparse misses the defect, too dense *becomes* the defect — and it defaults
sparse. It is a tuning parameter, not a free measurement — and note the two
bounds are in tension by construction: the motion requirement above sets a
*floor* (enough samples to detect inter-frame change from the commanded
interaction) while the perturbation hazard sets a *ceiling* (dense sampling
can stop the very negotiation under test). The document deliberately does not
pick a number; it requires that both bounds exist, per station, and that the
spec name them.

**The harness must not hold an exclusive resource it does not need — and its
silence is not evidence of non-interference.** From the same wave: an
observer patched to `connect → qmp_capabilities → sleep(DELAY)` produced an
*empty* output file, which was read as "hadn't started capturing yet" — while
it was in fact holding QEMU's single-client QMP monitor for the whole delay
window. The emptiest-looking part of the run was the most interfering; the
empty log did not merely fail to warn, it actively reassured, and the input
sink was condemned on a comparison where the observer ran on one side and not
the other. Two rules follow. (1) The gate acquires exclusive resources (QMP is
the obvious one on this box) **per sample and releases immediately**, never
for the duration of a run — holding a single-client monitor across a station's
session lifecycle is indistinguishable, from the station's side, from the
station being broken. (2) "Our observation did not cause this failure" must be
a **positive** check — the same-pass control station above is what provides
it — never an inference from a quiet log.

**An instrument that observes across two calls attributes the second call's
behaviour to the first, unless the snapshot is taken between them.** Added
2026-08-31, and the sharpest instance yet of this section's own subject: the
audit hook written to PROVE the push gate never reads live box state produced a
false signal itself. It was installed once and left running across both the gate
call and the drift-report call, so it counted the *report's* legitimate read and
attributed it to the gate — reporting "1 roster open by the gate" when the true
figure was zero. The measurement was wrong in the direction that would have
condemned a correct fix. The rule is general and cheap: an instrument that
accumulates must be read at the boundary of the thing being measured, not at the
end of the run, and a tool built to detect a false signal is not exempt from
producing one.

**And the strongest case for both of the rules above is that they were written
from an incident where the observer WAS the defect.** rhapsody's regression —
40 accepted sessions, zero completed negotiations — was caused by the
measurement harness holding QEMU's single-client monitor, not by anything the
cutover shipped (§2). A backend that builds no input router at all failed the
same way with the holder running. It took a four-run control matrix to
establish that, and what distinguished "the station is broken" from "the
instrument is breaking it" was running an untouched station through the same
pass at the same time. A gate without that control would have read the evidence
exactly as the wave first read it, and condemned a healthy release.

**Every acceptance pass runs a simultaneous control station.** Because the
gate can in principle cause what it detects, `failed(reason)` is only
trustworthy enough to auto-rollback on if a station fault can be separated
from a box-wide or harness-induced one. The pattern already exists: the deploy
agent's probe takes a `PROBE_OS` so an untouched station runs the same checks
alongside, and that control is precisely what turned "rhapsody is broken" into
"the ramabs sink is broken". Rule: candidate fails + control passes →
rollback, `failed(evidence)`; candidate fails + control fails → NO rollback,
`held(harness/box suspect)` and escalate — rolling back a healthy release on a
harness fault is rollback flapping, which is worse than no gate.

On failure the reconciler rolls back (§4.4) and marks `failed` with the
failing screendumps and the control's results attached to the journal —
evidence, not logs.

**Assert the MECHANISM, not just the outcome — and never adjudicate between
two checks that disagree.** Added 2026-08-30 from a third incident the same
night, which is the sharpest argument in this section. A device bug stranded a
button edge against a stopped guest; the purpose-built acceptance test for the
fix went **PASS** on a fix that was necessary but not sufficient. A second test,
which pinned the *shape* of the failure — an edge with no following motion, and
whether a later motion released it — **disagreed**. Trusting the disagreement
over the pass found two further defects behind the same symptom, one of which
would have reached visitors: a coordinate written while the guest was stopped
was never published, so on resume the value matched our own write and the tick
declared convergence while the guest had never repainted. Measured at the
shipping boundary as a session settling at 298,280 for a commanded 300,300.
Three rules follow, all cheap, none needing new infrastructure:

1. **A pass must assert the properties that make the reaction repeatable**, not
   only that the symptom is absent: input actually accepted, nothing dropped or
   overflowed, no give-ups, nothing left in flight. These come from counters the
   run already collects. This does **not** contradict "counters are not
   evidence" — the reconciling rule is that **telemetry may only ever SUBTRACT
   confidence, never add it.** A healthy counter can never turn a FAIL into a
   PASS (that is the substitution this section forbids, and frozen counters were
   one of the four true-and-meaningless indicators); a sick counter *can* turn a
   PASS into a FAIL, because it names a mechanism fault the pixels happened not
   to show this time.
2. **A read-back that matches our own write is not evidence the guest acted.**
   That is the same trap in a new place and it has now been measured twice. Every
   acceptance clause must be satisfiable only by guest-side change: pixels that
   moved, in a place we named, after something we commanded.
3. **Where two checks disagree, the gate fails and names both results.** It does
   not adjudicate, and it never silently prefers the passing one — a gate that
   does reproduces the exact bug it exists to catch. `DISAGREE` is red.

**And a missing template is INCONCLUSIVE, never a failure.** In that same run a
`NOTFOUND` from the cursor matcher turned out to be a template bank that did not
cover the station's glyph set — a harness gap, not a device fault. Per-station
template provisioning is therefore an explicit precondition of the pointer leg,
and its absence reports as inconclusive. Rolling a healthy station back for a
missing template is precisely the flapping §12 forbids, and a harness gap must
never be able to roll anything back.

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

- **manifest/config only** → apply any time — with one carve-out: nothing
  under the serve units is "apply any time" by default (see the serve class
  below);
- **restart-required** → wait until the station is idle-paused (the
  idle-pause reconciler already knows) or has had no viewer for N minutes
  (streamhost viewer telemetry); take the station claim; during the restart
  the signaling plane serves a `restarting` state so the SPA tile shows an
  honest "exhibit resetting" card instead of a dead stream;
- **serve-restart** → its own class, with the *strictest* window of all. A
  station restart blinks one exhibit; a serving-plane restart drops **every
  active stream fleet-wide simultaneously**, and for a walk-in visitor it
  destroys the clone they had claimed along with whatever they were doing in
  it — they are anonymous and the claim is TTL'd, so there is no coming back
  to it. The serve unit converges only when the box is drained or in a
  maintenance window, never opportunistically. And the inverse footgun is
  named too: **shipping serve-side Python without a restart is a silent
  no-op** — the new code lands, the running process never loads it, nothing
  reports it. The reconciler therefore treats a serve-code change as
  restart-required *by definition* and reports `pending(awaiting serve
  window)` rather than stamping a file-copy as applied;
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

1. **Un-wedge the gate** (hours) — **DONE, branch `cd-build`.** The welded
   drift stage is split (§2.1): byte-parity stays blocking and unchanged;
   `compare_live_labctl` is out of `check` and lives in
   `scripts/stations_registry/drift.py` as `stations-registry.py drift`,
   shaped like `facts-live` (absent live roster → loud SKIP, exit 0; only a
   readable box that disagrees exits 1). Range computation now fetches
   `origin/main` into a private ref and measures from
   `merge-base(current main, tip)` (§2.1a), so a rebased or merged branch is
   no longer billed for another wave's lint.
   Also landed here — same class, same plumbing (§2.5):
   `scripts/lint/published-form-drift.py` answers "does the published form still
   match the recipe?" with one `git ls-remote` plus a reverse-apply, and no build
   attempt. It already reports real drift: the fork branch sits at a commit that
   neither the submodule gitlink nor `rhapsody.qemuBuild.forkCommit` names.
   Deliberately **not** done here: the box-state stage is already per-row
   scoped (a row is blocking only when the push touches that row's repo-side
   file, and only when live matches neither the box checkout nor this tree),
   so there was nothing left for a branch-name rule to add; and `SKIP_GATE=1`
   stays until stage 5 removes the last check it exists to skip — deleting the
   escape hatch while an unsatisfiable check remains is how the hatch gets
   re-invented in a shell alias. **This — not the reconciler — was the first
   thing to build**: it alone unblocks concurrent independent sessions and is
   a precondition for everything else here.
2. **`station-accept.sh`** (a day) — **DONE, branch `cd-build`.** Rule 9 as a
   command: `scripts/dev/station-accept.sh` (orchestrator, same-pass control,
   decision matrix), `scripts/e2e/station-accept-probe.mjs` (the browser leg —
   sequential sessions, one SIGKILLed mid-stream, motion in a named rectangle,
   commanded click), `scripts/dev/station_accept_verdict.py` (the verdict, a
   pure function, 20 tests) and the registry `acceptance:` stanza with
   `validate_acceptance.py` (14 tests). No behaviour change anywhere: it starts
   nothing, stops nothing, holds no exclusive resource, and refuses a station
   with no spec rather than inventing one.
   **Not in `scripts/host/` as §14 first said.** The acceptance boundary begins
   in a browser, and the browser (with Playwright and a headed Chrome on a real
   display) lives on CT950, not on labhost. It sits beside `tile-accept.sh`,
   which is the same shape — workstation-side, driving the box through the one
   door. The reconciler will invoke it over that door in stage 4 rather than
   in-process.
   **What is NOT implemented, said out loud rather than left to look done:** the
   cursor-sprite-at-commanded-position leg. `cursorBank` is wired as a
   precondition and a missing bank correctly reports INCONCLUSIVE, but the
   sprite match itself needs a per-sample QMP screendump and a learned bank per
   station, and no bank exists for any station yet. Today the pointer leg proves
   *commanded click produced a repaint in the watched rectangle*, which is
   guest-side evidence that input arrives; it does not yet prove the pointer
   landed on the exact pixel. That is stage 4 work and it is listed here so
   nobody reads a green run as more than it is.
3. **Reconciler v0 — read-only** (days) — **DONE, branch `cd-build`.**
   `scripts/host/kh-reconciler` with `units | plan | status | denylist | rows`.
   No service is installed and no clone is created: stage 3 is a CLI, and its
   read-only-ness is proven by a test that runs every subcommand under an audit
   hook asserting zero writes — the 2026-08-24 dry-run-that-mutated incident is
   why a read path earns a test rather than a promise.
   The state-of-record deny-list is **structural**: `build_units()` runs every
   candidate member through `refuse_if_protected()`, which RAISES. A widened
   glob that swallowed `serve/` fails loudly instead of quietly deleting an
   account store, and `kh-reconciler denylist` reports the whole repo clean.
   **`rows` is the finding of this stage.** Cross-checking the live pair table
   against the first decomposition left **107 of 349 deployed rows claimed by no
   unit** — each of them deployed, and each of them a row the loop would have
   converged *never*. They were per-station files living outside the station
   directory (guest agents, systemd drop-ins, retronet and coldboot helpers
   named after their station), the daemon tree, and the registry sources behind
   the rendered manifests. The decomposition now claims all 349, and the last
   straggler needed the station id matched as a filename **suffix**
   (`seriald-sailfishos.service`), not just a prefix. Stage 4 must not write
   anything while that list is non-empty, so it is a command rather than a
   comment.
4. **Transactional per-station apply** (the core) — **MECHANISM DONE, branch
   `cd-build`; NOT installed and NOT armed.** `kh_reconciler/store.py`
   (content-addressed objects, hardlinked into releases, refuse-by-default GC)
   and `kh_reconciler/apply.py` (materialize beside → one `rename(2)` of a
   symlink → stamp → journal → rollback), exposed as
   `kh-reconciler apply|rollback|journal --unit U --root R`.
   **Three refusals, in code rather than in anyone's memory:** a root anywhere
   under the live serving tree is refused with *no override flag* (a flag would
   be found and used by someone who had not read the paragraph explaining it);
   a member that is live state of record raises; and `apply` refuses outright
   unless every deployed row is claimed by a unit — the stage 3 precondition,
   enforced rather than remembered, because an unreadable precondition is not a
   satisfied one either.
   **Adoption is not a cutover**, a distinction the first real run forced. With
   no previous closure nothing is being *changed* for the guest — members are
   placed under `current/` for the first time, which is this stage's migration
   step. Classifying an adoption by its full member list made every station with
   a launcher `recapture-required` forever, so no station could ever be migrated
   onto the layout that makes cutovers safe. Conflating the two made the
   mechanism unable to bootstrap itself.
   Proven end-to-end in a sandbox: adopt → cutover (`restart-required` from 12
   changed members) → rollback → journal, plus 26 tests. The sharpest is
   **rollback completeness**: reverting a backend without also restoring its
   cursor scale would leave a station streaming with a silently wrong pointer
   gain and nothing failing, and the test asserts the *whole* set comes back.
   Still to come before this may run against the fleet: acceptance wired into
   the flip (stage 2's `station-accept.sh` as the gate), the disruption windows
   of §9, and the migration of real stations onto the layout.
5. **The push trigger + close the loop for opt-in units** (§1.1) —
   **MECHANISM DONE, branch `cd-build`; NOT INSTALLED AND NOT ARMED.** Built and
   tested: `scripts/serve/deploy_hint.py` (constant-time signature, rate limit
   *before* the HMAC, delivery dedupe, `refs/heads/main` only, one-file side
   effect), `kh_reconciler/loop.py` (trigger classification, hint corroboration,
   backstop reporting), `kh-reconciler watch --once | poke`, the
   `rollout: auto | hold` knob, and the Actions workflow. Deliberately left
   unbuilt because building it would be half-arming: **the route is not wired**
   (`deploy_hint.handle_post` is dispatched from nowhere, so it cannot go live
   on the next serve deploy) and **there is no continuous mode** — `watch`
   refuses anything but `--once`. The arming order is
   [`docs/lab/CD-STAGE5-ARMING.md`](CD-STAGE5-ARMING.md), and every step in it
   is an operator decision.
   Two properties worth naming. **`rollout` defaults to `hold`, and `auto` is
   validated to require an `acceptance` stanza** — auto-converging a station the
   gate cannot judge is precisely the unattended deploy this design exists to
   make safe, and since no station has a stanza yet, no station can be opted in
   today. **A delivery id is remembered only when the hint is ACCEPTED**: GitHub
   redelivers a failed delivery under the same id, so recording one we dropped
   would turn its own retry into a silent no-op, leaving the box un-converged
   with both sides believing they had done their part. That bug was found by a
   test, not by review. Then `rollout: auto` on a canary handful +
   the `serve-code`, `serve-manifests` and `host-tools` units (docs/scripts
   auto-deploy is pure win, and the serve surfaces are the right first
   canaries: a mistake there costs a page reload, not an exhibit — per the
   walk-in reviewer's endorsement). Watch for a week.
6. **Manifests to the loop** (I.7): the `serve-manifests` unit rendered by
   the reconciler from applied station state; `publish_manifests` deleted
   from `serve-https-spa.sh`; dark-launch overlays live in the
   state-of-record category (§1) with owning claims, so a render cannot
   clobber one. Where read-time derivation is affordable, prefer it to
   publishing at all (§3) — `fleet-table.json` first.
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

- `compare_live_labctl` in the push path (stage 1, done — it is now
  `stations-registry.py drift`). `SKIP_GATE=1` waits for stage 5: the
  escape hatch may only be removed once nothing unsatisfiable is left for it
  to skip, or it comes back as a shell alias nobody can see.
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
- **The trigger dies quietly and the box looks fine.** A push-driven system
  fails in a way a polled one cannot: deliveries stop, the backstop keeps
  converging every 30 min, and everything *looks* healthy at a coarser
  latency for as long as nobody times a deploy with a stopwatch. This is the
  §0 pattern — a true indicator that means nothing — so it is answered the way
  §0 says: the trigger of every convergence is recorded and the age of the
  last **webhook-sourced** one is on the status surface (§1.1). Running on
  the backstop is a visible state, not an invisible one.
- **A public inbound endpoint on the gallery host.** Mitigated structurally
  rather than by hardening: the endpoint holds no privilege that can deploy —
  its only side effect is one file's mtime — and it cannot name what to
  deploy, so a full compromise of it buys an attacker a rate-limited extra
  `git fetch` (§1.1). The half that can deploy has no listening socket.
- **Trigger-driven loop races a multi-commit story.** Two pushes seconds apart:
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
- **CPU**: idle loop ≈ zero (it sleeps on an inotify wakeup, and fetches +
  hash-compares once per push plus once per 30 min backstop tick); one niced
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
| `scripts/host/kh-reconciler` (+ `kh_reconciler/`) | the loop: units/plan/status/denylist/rows (stage 3, landed read-only); apply/journal in stage 4 |
| `scripts/host/kh_reconciler/closure.py` | commit → per-unit closure hash (absence-sensitive; reads git objects, never the worktree) |
| `scripts/host/kh_reconciler/denylist.py` | state of record, enforced by raising rather than remembered |
| `scripts/host/kh_reconciler/store.py` | content-addressed objects + the live-root refusal (no override flag) |
| `scripts/host/kh_reconciler/apply.py` | materialize → one symlink flip → stamp → journal → complete rollback |
| `kh-reconciler status` | add the `loaded-drift` class (§2.6): process start time vs member mtimes, per serve-side unit |
| `scripts/host/kh-store` | object store: add/gc/verify/materialize |
| `scripts/dev/station-accept.sh` | rule 9 as a command (stage 2, landed). **Not `scripts/host/`**: the acceptance boundary starts in a browser, and the browser lives on CT950 |
| `scripts/e2e/station-accept-probe.mjs` | the browser leg: session churn, one abandoned, motion in a named rect |
| `scripts/dev/station_accept_verdict.py` | PASS / FAIL / DISAGREE / INCONCLUSIVE, as a tested pure function |
| `scripts/stations_registry/validate_acceptance.py` | the `acceptance:` stanza's rules, enforced at commit time |
| `scripts/serve/deploy_hint.py` | the public hint endpoint: verify, bump a timestamp, nothing else (§1.1) |
| `.github/workflows/deploy-hint.yml` | post-CI Actions ping to the same endpoint (§1.1) |
| `scripts/dev/kh-alloc` | git-arbited durable allocations |
| `registry/goldens/<station>.json` | golden refs (committed) |
| `registry/allocations.json`, `qemu-patches/series` | durable namespaces |
| registry stanzas: `acceptance:`, `rollout:`, `maintenanceWindow:` | per-station knobs |

| change | how |
|---|---|
| `scripts/stations_registry/cli.py` | drop `compare_live_labctl` from `check`; add `drift`; add closure/golden-combination validation |
| `scripts/lib/checkpoint-guard.sh` | `publish` step → store + outbox ref |
| `.claude/hooks/pre-push-gate.sh` | commit-properties only; range measured from the merge-base with a freshly fetched `main` |
| `scripts/stations_registry/drift.py` | the live labctl comparison, out of the push path (stage 1, landed) |
| `scripts/lint/published-form-drift.py` | recipe-vs-published-form drift for the QEMU fork, answered without a build (§2.5, stage 1, landed) |
| `scripts/serve-https-spa.sh` | lose `publish_manifests` (loop-owned); `deploy` keeps N asset generations |
| reconciler config | deny-list of live state-of-record paths (`auth-state.json` + rotations, `darklaunch.d/`) — never written, never GC'd |
| `scripts/dev/here.sh` | show loop heartbeat + per-unit states |

| delete (staged, §11) | `box-deploy.sh --apply` path, `box-sync-push.sh`, global `.deployed-rev`, `build/` mirror + `.last-harvest`, `SKIP_GATE=1` |

---

*Written from the 2026-08-30 incident evidence; grounded in
`box-deploy.sh`/`box-install.sh`/`box-repo.sh`, `stations_registry/cli.py`,
`serve-https-spa.sh`, `checkpoint-guard`, `kh-claim`, `wt.sh` as of
`main@1bb53874`.*

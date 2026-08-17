> **Historical snapshot.** This document describes the system as it stood around 2026-08-03. It is kept for historical context and is not a description of the current system.

# Artifact CI/CD — a plan to stop shipping unbuilt things

Status: **plan, not yet implemented.** Written 2026-08-03 after a campaign merged
six MAME/golden workstreams to `main` — all "CI green" — without the combined
build artifact ever having been produced, let alone booted.

## The problem, stated plainly

This repo has two classes of artifact, and all of the risk lives in the one with
no automated coverage.

| class | artifacts | CI today |
|---|---|---|
| **A** | Rust daemon, SPA, shell/python scripts, generated registry | real: `shellcheck`, `ruff`, `actionlint`, file-size budget, generated-drift, `cargo fmt/clippy/test`, SPA lint+build, registry parity |
| **B** | **MAME binary, the patch stack, goldens (`*.chd`), tile config** | **none whatsoever** |

Nothing in `.github/workflows/` builds MAME, applies the patch stack, boots a
guest, or touches a golden. There is no CD; deployment is an agent copying files
over `ssh lab`.

So a branch whose entire content is class B — a MAME patch, a re-baked golden, a
tile-env change — can merge with a green tick while being unbuilt, untested, or
actively broken. That is not a hypothetical:

- **fastram** passed its own workstream's checks and merged. It stops IRIX dead at
  `Memory diagnostic *FAILED* / Check or replace: SIMM S7` — but **only** in the
  presence of `-ioc2:rs232a pty`, which is exactly what production runs. No
  existing job could have seen it.
- **The taptun patch** was documented as being in the shipped binary stack. It was
  not. The failure is silent, and it cost a whole campaign its W1/W2/W3
  measurements.
- Goldens **v3 through v7** exist as 2.2 GB files whose md5s live in agent reports
  and prose. That is folklore, not provenance.

The honest name for what we have is a **static hygiene gate**. It verifies that
the repo is tidy. It has been reported — including repeatedly by me in agent
briefs and status updates — as though it meant the change *worked*.

## Phase 0 — stop the mislabelling

**Cost: hours. Do this first; it prevents recurrence immediately.**

- Rename the gate in [`AGENT-CI-EXIT-RULE.md`](AGENT-CI-EXIT-RULE.md), `AGENTS.md`
  and every agent brief: it is the **static hygiene gate**. Passing it is
  necessary and never sufficient.
- Add the rule: a branch touching `scripts/build-guests/**`,
  `streamhost/tiles/**`, or the golden manifest **also owes the artifact gate**
  and may not merge to `main` on hygiene alone.

## Phase 1 — make the patch stack verifiable

**Cost: ~½ day.**

- Add a machine-readable stack manifest (`scripts/build-guests/mame-stack.json`):
  pinned base commit, ordered patch list, and per patch whether it is an
  **upstream bug fix** (should be sent upstream, reduces our carry) or
  **local-only** (ours forever).
- CI job `mame-stack`: shallow-checkout the pinned MAME base, `git apply --check`
  every patch in order. No compile needed, so this can run on a GitHub-hosted
  runner in under a minute.

Catches: stack drift, a patch that no longer applies, a documented order that does
not reproduce the binary.

## Phase 2 — the binary becomes a build product

**Cost: ~1 day.**

- Job `mame-build` builds `SUBTARGET=sgi` from base + manifest **inside a pinned
  container** (a Debian image at or below the box's glibc), so the binary is
  ABI-correct for the target by construction.
- Publish the binary as a CI artifact together with its md5 and the exact manifest
  it was built from.
- **Rule: the tile only ever runs a CI-built binary.** No hand-built binaries
  copied to `/data/vms/streamhost/assets/`.

Catches: the entire class of box/repo divergence, including the taptun case where
a doc claimed a patch was shipped and it was not.

The build is **runner-agnostic**: pinned base commit, pinned patch manifest, pinned
container. Schedule it on the lab runner (fast, warm ccache, no minute budget),
with GitHub-hosted as the fallback when the box is busy.

Two prerequisites:

- Install `ccache` on the box — it is the difference between a ~30-60 min cold
  build and a few minutes.
- **DONE (2026-08-07)** — retired the private glibc bundle that shipped beside
  the binary (`assets/irix/glibc/`), which the launcher invoked explicitly via
  `ld-linux … --library-path`. Measured on the shipped `sgi`: it needs at most
  `GLIBC_2.38` / `GLIBCXX_3.4.32`, and the trixie box provides 2.41 / 3.4.33, so
  MAME is now exec'd directly by every IRIX launcher and rig. The staged bundle
  is left in place unreferenced for one rollback cycle.

## Phase 3 — the boot smoke test

**Cost: ~1 day. This is the highest-value item in the plan.**

Boot a named golden with the candidate binary, headless, under the production flag
set, with `-seconds_to_run`; capture the framebuffer and assert a fingerprint.

The instrument already exists — a campaign built it while bisecting fastram. Known
fingerprints (`w h mean sd` over the captured frame):

| fingerprint | meaning |
|---|---|
| `1288 1024 0.702353 0.166836` | v7 login chooser — healthy |
| `1288 1024 0.589366 0.188070` | memory-diagnostic failure screen |
| `1288 1024 0.000000 0.000000` | black — boot did not get anywhere |

It must be a **matrix over production flags**, not a single happy path, because
fastram passes without `-ioc2:rs232a pty` and fails with it. Minimum:
`{serial on, off} × {net on, off}`.

**This would have caught fastram automatically, before merge, with no human in the
loop.**

## Phase 4 — build the merge result, and protect `main`

**Cost: ~½ day.**

A `pull_request` event checks out the **merge commit** (`refs/pull/N/merge`), not
the branch head — so PR checks build "main + this change" with no staging branch
to maintain.

- Class-B changes go through a **PR**, not a direct push.
- `mame-stack`, `mame-build` and `boot-smoke` run on `pull_request`, so they
  exercise the *merge result* — the combined artifact exists and boots before
  anything lands.
- **Branch protection on `main`**: require those checks for any branch touching
  `scripts/build-guests/**`, `streamhost/tiles/**`, or the golden manifest;
  require branches to be up to date before merging.

**Residual risk:** two PRs each green against `main` can still break in
combination. GitHub's **merge queue** builds the prospective combination before
landing; turn it on if that bites. Serial solo work will not need it; a fan-out of
concurrent agent workstreams might.

## Phase 5 — goldens get provenance

**Cost: ~1 day.**

Goldens are 2.2 GB: not git, not LFS. Instead:

- `registry/goldens.json` (or `docs/lab/GOLDENS.md` if a table reads better):
  name, md5, byte size, **parent golden**, the guest-side delta, and the script
  that produces it.
- **Rule: a golden is only ever produced by a script in `scripts/build-guests/`**,
  never hand-baked in an agent session.
- CI job verifies the manifest matches what the box actually holds (an `ssh lab`
  check from the lab runner). Immutability is already enforced on the box by
  `chmod 444` + `chattr +i`; the manifest makes it auditable.

## Phase 6 — actual CD

**Cost: ~1 day.**

A manually-triggered `deploy-tile` workflow that:

1. snapshots current tile state (binary md5, golden, `tile.env`, tile-dir scripts)
   and writes the rollback command into the run log;
2. installs the CI-built binary and the named golden;
3. verifies via a **clone that reads the real installed files** — never by starting
   the tile service;
4. leaves the service in its configured state (today: stopped).

Rollback is re-running the same workflow pinned to the previous artifact md5.

## The lab runner

**Self-hosted GitHub Actions runners live on the Proxmox host**, because the things
that need *testing* cannot leave it: the goldens are 2.2 GB, the Indy PROM ROMs are
licensed and non-redistributable, and the tile configuration only means anything
next to the real `/data/vms/streamhost` tree.

The lab runner is required from Phase 3 onward.

### Networking

**A GitHub Actions runner dials out**: it long-polls GitHub's API over HTTPS and
receives work on that outbound connection, so no inbound port is opened on the home
WAN and the runner needs no tunnel of its own.

From [`CLOUD-AGENTS.md`](CLOUD-AGENTS.md) we reuse the **security pattern**:

- a **dedicated, least-privilege identity** rather than the LAN root path;
- **one-command revocation** (`systemctl stop`, and de-register the runner);
- its own systemd unit, its own directory, its own credentials.

The forwarder VPS still earns its place in two cases, and both should reuse
`scripts/cloud-agents/` conventions rather than growing a parallel mechanism:

- a **cloud-hosted job** (or a cloud coding agent) that needs to reach the box —
  it uses the existing `ssh lab` path unchanged;
- **operator access to the runner** from outside the LAN — same reverse-tunnel
  design, a second purpose-built endpoint, revocable independently.

### Isolation

A CI runner executes whatever a workflow file says. It must not be root on the
museum host.

- Runner runs as a **dedicated unprivileged user in its own LXC** on the box, not
  as root on the Proxmox host.
- Privileged operations it genuinely needs (installing a tile artifact, driving
  `clone-guard`) go through a **narrow, audited channel** holding exactly that
  capability — the same shape as the cloud-agent sshd: purpose-built, key-only,
  one authorised key, killable with one `systemctl stop`.
- Runner labels `self-hosted, lab, mame`. **Only class-B jobs target the lab
  runner**; class-A hygiene jobs stay on GitHub-hosted runners, where they are
  faster and hold no secrets.

### Concurrency

Measurement campaigns on this box are invalidated by competing load. A busy SMT
sibling costs MAME **39%**, and an unpinned competitor manufactures a ~1.6×
effect — the exact retraction class this project has hit repeatedly.

- The lab runner takes **one job at a time** (`concurrency` group at the workflow
  level, and a single runner process).
- Build and smoke jobs **claim a core pair** via `/data/vms/sandbox/corepairs/`,
  the same protocol agents use, and release it on exit.
- A job that finds the box non-quiet when it needs quiet must **fail loudly**
  rather than produce a number.

### What the runner must never do

- Start a gallery tile service as a side effect.
- Write anywhere under `/data/vms/streamhost/` outside the `deploy-tile` workflow.
- Publish goldens or ROMs as GitHub artifacts (size, and licensing —
  see [`ASSETS-MANIFEST.md`](ASSETS-MANIFEST.md)).
- `pkill` anything. Kills go through `clone-guard` by pidfile, as everywhere else.

## Sequencing and honest cost

~4 days total, front-loaded. **0 → 1 → 3 captures most of the value**, and Phase 3
alone would have prevented the failure that prompted this plan.

**Phases 0-2 need no self-hosted runner at all**, so the runner build-out is not on
the critical path and can proceed in parallel with them.

| phase | cost | catches |
|---|---|---|
| 0 mislabelling | hours | the recurrence |
| 1 stack manifest + apply check | ½ d | stack drift |
| 2 binary as build product | 1 d | box/repo divergence |
| **3 boot smoke + flag matrix** | **1 d** | **fastram-class breakage** |
| 4 PR checks on the merge result + protected `main` | ½ d | untested combinations |
| 5 golden provenance | 1 d | folklore artifacts |
| 6 CD + rollback | 1 d | bespoke, unrepeatable deploys |

## Cross-cutting: the measurement harness belongs in the repo

Several retracted conclusions came from ad-hoc rigs that lacked validity checks.
The harness — with `foreign%` (share of the pinned pair's cycles belonging to
someone else), achieved GHz alongside every cycle-normalised figure, within-run
windowing, and paired medians — should be a committed artifact, not something each
agent rebuilds. See the measurement rules in the IRIX notes
([`docs/guests/irix.md`](../guests/irix.md)).

## Explicitly not doing

- **Boot smoke on GitHub-hosted runners.** Needs 2.2 GB goldens and licensed ROMs.
- **Goldens in git or git-LFS.** Manifest + immutable files on the box instead.
- **Running the runner as root on the Proxmox host.**

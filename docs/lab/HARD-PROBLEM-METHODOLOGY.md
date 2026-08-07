# Hard-problem solving methodology

How we attack **hard / uncertain** problems in this lab — the kind where the
solution path is unknown, dead-ends are likely, and a single straight-line attempt
is as likely to thrash as to succeed (e.g. "get NT 3.51 to 1024×768×16bpp rendering
cleanly under QEMU", "kill the residual encoder latency", "make os2warp hi-res").

Trivial/known work does **not** need this — just do it. Reach for this method when
you can't yet name the working approach.

## The core loop: diverge → gate → converge → verify → hand off

1. **Write the acceptance test FIRST.** Before exploring, encode a *repeatable*,
   **adversarial and production-realistic** test that a solution must pass. Adversarial
   = it exercises the exact thing that tends to break (for a rendering bug: scroll +
   window-drag + icon redraw, repeated, since the bug was intermittent). Production-
   realistic = it reflects how the exhibit is actually used, verified the way we ship
   (real framebuffer screendumps, not logs). If you can't state the pass condition,
   you're not ready to explore.
2. **Diverge.** Enumerate several *distinct* candidate approaches and pursue them in
   **isolated experiments** (see Parallel agents below). Do not converge early on the
   first idea.
3. **Gate.** Run the acceptance test against each candidate. Kill the ones that fail;
   keep framebuffer/artifact evidence for every verdict.
4. **Converge.** Pick the winner. If several pass, prefer the lowest-risk one (fewest
   moving parts; keeps the pinned device set / avoids a re-bake).
5. **Verify.** Re-run the adversarial acceptance test on the converged solution in a
   production-realistic setting (golden re-bake + `loadvm golden` byte-identical +
   live via the SPA), then promote.
6. **Hand off.** Record what won, and — just as important — **what didn't and why**.

## Parallel agents from different angles  ← the default for genuinely hard problems

A single agent grinding one approach (or trying everything sequentially) is slow and
fragile: as its context fills it starts **fighting its own infrastructure and looping**,
wasting effort. Instead:

- **Run MULTIPLE agents in parallel, each attacking the problem from a DIFFERENT
  angle**, each in **its own sandbox**. Coverage of the solution space is parallel,
  not serial.
- **First clean solution wins.** As soon as one agent's approach passes the acceptance
  test, **kill the others and salvage their conclusions.** A proven dead-end is a
  real result — it narrows the space and stops others (and future you) re-treading it.
- Each agent owns **one angle** and reports a crisp verdict: PASS (how, with proof) or
  FAIL (why, with proof). It does **not** promote to production — the orchestrator
  converges and promotes the winner in a dedicated step, to avoid parallel writes to
  live state.

### Keep each agent BOUNDED and FOCUSED

- **Do not raise agent time/token budgets** to "let it finish." A bounded agent that
  dies at its cap is fine — you salvage its partial and relaunch or converge. Raising
  the cap just makes the context-fill loop *longer*; it does not make the agent
  smarter. (In practice: use the agent's default time/token caps; one angle per agent.)
- **One angle per agent** keeps its context small, so it reasons about the problem
  instead of thrashing on plumbing.
- If an angle needs more depth than one bounded run, that's a signal to **split it into
  narrower angles**, not to widen the budget.

### Isolate every experiment

- Repo work: a **git worktree** per agent (branch `agent/<angle>`), so file edits never
  collide.
- Box work: a **namespaced clone** per agent under `/data/vms/soltest/<name>-<uniq>/`
  with a **unique** dir / VMID / `qmp.sock` / pidfile / hostfwd ports, so N concurrent
  QEMU clones don't step on each other. Kill VMs **only** via `clone-guard
  kill-pidfile` (never `pkill` by name). Keep `loadvm golden` device-set parity.
- Verify **only** via real framebuffer screendumps (`labctl shot` / QMP `screendump`),
  never disk/log inference.
- **Claim every shared resource atomically and namespace it per agent** — displays
  (`xvfb-alloc`), taps (`tapnet.sh claim`), core pairs, iptables chain names, host
  IPs, ports, dataset names. A resource you did not create is a loud failure, never
  a silent fallback. The full rule and the four incidents behind it are in
  [AGENTS.md](../../AGENTS.md) ("Shared resources"); the concurrency failures it
  prevents all *reported success* while producing contaminated results.
- **Teardown is part of the agent's verdict.** Kill only via `clone-guard
  kill-pidfile`, verify nothing named after the run survived, release every claim,
  and say so in the report.

### Measure it the same way every time

Any angle whose verdict is a number owes
[MEASUREMENT-METHODOLOGY.md](MEASUREMENT-METHODOLOGY.md) — the metric, achieved
clock beside every figure, within-run windowing, core-pair pinning, `foreign%` as
a gate, and the checklist a claim has to satisfy to be comparable to anything else
in this repo. Four conclusions in this project were retracted to method errors, and
each one had already been reported as a result.

## Orchestrator playbook

1. Author the acceptance test; enumerate 3–5 *distinct* angles (not variations of one).
2. Launch one **bounded, focused** agent per angle, each with a unique sandbox and the
   **salvaged prior findings** (so nobody repeats a known dead-end). Feed forward what
   earlier attempts already ruled out.
3. Monitor. On the **first** PASS: verify its framebuffer proof yourself, **kill the
   remaining agents**, and **salvage** their partial conclusions (append the dead-ends
   to the problem's notes / this repo).
4. Promote the winner via a dedicated step (bake golden, back up, flip registry,
   deploy, live-verify).
5. **If every angle fails**, report **INFEASIBLE with evidence** plus the
   **best-achievable results ranked** — and let the human choose the fallback. Never
   silently ship a downgrade, and never ship a mode that fails the acceptance test.

## Anti-patterns (learned the hard way)

- **One giant long-running agent** trying every approach in sequence → fills context,
  loops on its own tooling, and produces no crisp verdict. (Observed: an nt351-hires
  agent burned 846 events / 18 clones and ended mid-`SIGTERM`/`setsid` plumbing with no
  conclusion.) Split into parallel bounded angles instead.
- **Raising an agent's budget** so it can "keep going" — extends the loop, not the
  insight.
- **Silently downgrading** the target when the ask turns out infeasible — report it and
  offer ranked alternatives.
- **Skipping the acceptance test** — you can't gate candidates without one, so you
  converge on hope.
- **Reporting done with clones still running.** Ten orphans once sat at 85% CPU for
  an hour and poisoned every sibling agent's measurements. The verdict is not final
  until the box is back the way you found it.
- **Adopting a shared resource you did not create** — a display, a tap, a chain, a
  core pair. It looks like success and produces someone else's data.

## Mechanics in this repo

- **Agents:** one bounded agent per angle, isolated in its own git worktree, run at
  default time/token caps; salvage a partial result before relaunching or converging.
- **Isolation / safety:** `clone-guard` (`docs/lab/clone-guard.md`), namespaced
  `/data/vms/soltest` clones, pidfile-only kills.
- **Verification:** `labctl shot` / QMP `screendump` → PNG → look at the framebuffer.
- **Green-before-done:** any branch intended for `main` owes the CI gate
  ([AGENT-CI-EXIT-RULE.md](AGENT-CI-EXIT-RULE.md)).

See also: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` (the step-by-step for a *known* OS add —
the opposite case, where the path is clear and you don't need this method).

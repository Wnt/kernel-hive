# Arming the continuous-deploy loop — the checklist the operator owns

**STATUS 2026-08-31: the TRIGGER IS ARMED. The LOOP IS NOT INSTALLED.**
This file opened with "nothing in this document has been done" for as long as
that was true, and updating it the moment it stopped being true is the point —
a checklist that still says nothing has happened, after it has, is the §2.7
hazard of the design document in its own operating instructions.

Done, on the operator's authorisation: steps 1–7 below. A signed hint now lands
within a second of a push to `main` and is journalled with honest provenance.
**Not done, and a separate decision that must not be inferred from the above:
step 8** — installing the service and timer. Nothing converges today: there is
no loop, `rollout` defaults to `hold`, and no station carries the acceptance
stanza that `rollout: auto` requires.

Every step below remains an operator decision. An agent must not perform one
without being asked for that specifically — "implement the proposal" is not
that authorisation, and neither is "the trigger is armed".

The design is `docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md`; §1.1 is the trigger.

## What is built, and what is deliberately not

| Built and tested | State |
|---|---|
| `scripts/serve/deploy_hint.py` — signature, rate limit, replay, ref filter, wakeup | **routed and live**; answers 503 with no key |
| `scripts/host/kh_reconciler/loop.py` — trigger classification, hint checking, backstop reporting | present, `watch --once` only |
| `kh-reconciler poke` | present, sandbox roots only |
| `registry` `rollout: auto \| hold` + validation | present, **no station sets it** (so nothing can be converged) |
| `.github/workflows/deploy-hint.yml` | **armed**; two triggers — an unconditional `push` ping (delivery backstop) and a `workflow_run` ping carrying the Quality gate's conclusion as journalled data |
| `scripts/host/kh-reconciler.service.example` / `.timer.example` | present, **not installed, not a sync pair** |

Left unbuilt because it is only meaningful once installed, and building it
would be half-arming:

- **the route.** `deploy_hint.handle_post` is never dispatched. Wiring it into
  `osgallery-https-server.py` would put a public deploy trigger live on the next
  serve deploy, so the two-line change is written out below instead of applied.
- **the continuous loop.** `kh-reconciler watch` refuses anything but `--once`.
  There is no daemonize path to disable, because there is no daemonize path.

## The order to arm it in, and why this order

Each step is reversible and each is visible before the next one matters.

1. **Generate two secrets** — one for the webhook, one for Actions. They are
   separate on purpose: the box identifies which trigger fired by *which key
   verified*, never by a field in the payload, and the whole
   "are we running on the backstop?" signal depends on that being unforgeable.
2. **Put the box's copies outside the repo**, beside the other gitignored local
   values. Never in `registry/local.env` if that is ever printed.
3. **Wire the route** (below), deploy the serve unit, restart it. Serve-side
   Python that is shipped without a restart is a silent no-op — the new code
   lands and the running process never loads it.
4. **Confirm the endpoint is unarmed-safe first**: with no key configured it
   answers `503` to everything. Check that before adding the key, so you have
   seen the closed state.
5. **Add the webhook** in the repo settings: `application/json`, the push event
   only, the webhook secret. GitHub's "ping" is answered `200` and wakes
   nothing, so a green ping proves reachability without triggering anything.
6. **Add `KH_DEPLOY_HMAC`** to repo secrets. The workflow stops skipping.
7. **Watch the journal with nothing opted in.** Default is `hold`, so
   convergence selects zero units and `kh-reconciler status` shows the trigger
   provenance. This is the step that proves the trigger works *before* it can
   move anything.
8. **Only then** install the service and timer, and opt in a canary — the serve
   surfaces first, per the proposal: a mistake there costs a page reload, not an
   exhibit.

## Still owed before ANY station may be opted in

Not optional, and not this stage's to hand-wave:

- **acceptance wired into the flip** — `station-accept.sh` exists but the loop
  does not call it, and `rollout: auto` is validated to require an `acceptance`
  stanza precisely so a station the gate cannot judge cannot be auto-converged;
- **the disruption windows of §9** — restarts are exhibits blinking at visitors,
  and the serve class drops every active stream fleet-wide;
- **real stations migrated onto `releases/`+`current`**;
- **no station has an acceptance stanza yet**, so today every station would be
  refused by the gate. That is the honest state, not a blocker to hide.

## The route change, written out rather than applied

In `scripts/serve/osgallery-https-server.py`, inside `do_POST`, beside the other
box-side POST routes:

```python
# POST /kh/deploy-hint — the deploy trigger (docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md 1.1).
# It cannot say WHAT to deploy: it verifies a signature and bumps one file's mtime.
if path == "/kh/deploy-hint":
    return deploy_hint.handle_post(self, DEPLOY_HINT)
```

with, at module scope:

```python
import deploy_hint
DEPLOY_HINT = deploy_hint.HintReceiver(
    keys={"webhook": _secret("KH_WEBHOOK_SECRET"), "actions": _secret("KH_DEPLOY_HMAC")},
    wakeup=Path("/data/vms/streamhost/.kh-reconciler/wakeup"),
)
```

`_secret` must read from the environment or a root-only file — never from
anything the repo carries. With both empty the receiver is unarmed and answers
`503`, which is the correct default for a public deploy trigger.

## How to disarm

In reverse: remove the repo webhook, delete the secret, `systemctl disable --now
kh-reconciler.timer`, drop the route. The mechanism keeps working for manual
`kh-reconciler apply`, which is the fallback the proposal names — the
transactional path does not need the loop.

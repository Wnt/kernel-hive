"""The convergence loop — push-triggered, with a slow backstop (§1.1).

WHAT WAKES IT, in order of how the operator wants it to work:

  webhook   a repo webhook, ~1 s after the push. THE trigger.
  actions   a post-CI Actions ping to the same endpoint. Audit trail, and the
            backstop for a webhook delivery that was dropped.
  timer     a slow tick (default 30 min). NOT the mechanism — the liveness
            floor, so a silently broken trigger degrades to late instead of
            never.
  manual    `kh-reconciler poke`, for operators and agents.

THE HINT IS NEVER AN INSTRUCTION. On wake the loop fetches `origin/main` in its
own clone and converges to what IT finds. A sha carried by the wakeup is used
for the journal only, after `merge-base --is-ancestor` proves it is in the
history actually fetched; a sha that is not an ancestor is recorded as an
anomaly and changes nothing. A forged or replayed hint can therefore cost one
extra fetch and nothing else.

WHY THE TRIGGER SOURCE IS JOURNALLED EVERY TIME. Without it, a dead webhook is
invisible: the timer keeps converging, everything looks healthy at a coarser
latency, and nobody notices for weeks. That is the shape of every incident this
design was written from — a true signal that means nothing. With it, "we have
been running on the backstop" is a state you can see.

NOT INSTALLED, NOT ARMED. This module is the mechanism. Installing a loop that
converges the fleet with no human in it is the operator's decision, so nothing
here installs a unit, enables a timer, or runs on its own. `watch --once` is for
testing it in a sandbox; there is no daemonize path on purpose.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

WAKEUP = Path("/data/vms/streamhost/.kh-reconciler/wakeup")
BACKSTOP_S = 30 * 60
TRIGGERS = ("webhook", "actions", "timer", "manual")


def read_wakeup(path: Path) -> dict | None:
    """The last hint, or None. An unreadable wakeup is treated as ABSENT rather
    than as an error: the timer will converge anyway, and a malformed file must
    never be able to stop the loop."""
    try:
        row = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return row if isinstance(row, dict) else None


def classify_wake(
    wakeup: Path, last_seen_ts: float, now: float, backstop_s: int = BACKSTOP_S
) -> tuple[str, dict | None]:
    """(trigger, hint) — what woke us, decided by evidence rather than by a flag.

    A wakeup file NEWER than the last convergence means a hint arrived, and its
    own recorded source names which one. Otherwise this is the backstop tick.
    """
    row = read_wakeup(wakeup)
    if row and float(row.get("ts", 0)) > last_seen_ts:
        source = row.get("source")
        return (source if source in TRIGGERS else "webhook"), row
    return "timer", None


def hint_is_trustworthy(git, repo: Path, hint_sha: str | None, head: str) -> tuple[bool, str]:
    """Is a hinted sha actually in the history we fetched for ourselves?

    This is the check that keeps a signed-but-hostile payload from meaning
    anything. It does not SELECT what to deploy — head does — it only decides
    whether the hint is worth recording as corroboration or as an anomaly.
    """
    if not hint_sha:
        return True, "no hint sha"
    if len(hint_sha) < 7 or not all(c in "0123456789abcdef" for c in hint_sha.lower()):
        return False, f"hint {hint_sha!r} is not a sha"
    ok = git("merge-base", "--is-ancestor", hint_sha, head, cwd=repo, check_rc=True)
    if ok:
        return True, f"hint {hint_sha[:12]} is an ancestor of {head[:12]}"
    return False, (
        f"ANOMALY: hinted sha {hint_sha[:12]} is NOT an ancestor of the origin/main we fetched "
        f"({head[:12]}). Converging to what we fetched, as always; recording this because a hint "
        "that names history we do not have is either a race or a forgery."
    )


def selectable_units(units: dict, rollout: dict[str, str]) -> tuple[list[str], list[str]]:
    """(auto, held) — `rollout: hold` pins a unit without blocking anyone's push.

    Default is HOLD in this stage, not auto. The proposal flips the default to
    auto once acceptance and the disruption windows exist; until they do, an
    opt-in list is the honest setting, and a unit nobody opted in is simply not
    converged rather than quietly converged.
    """
    auto, held = [], []
    for unit in sorted(units):
        (auto if rollout.get(unit) == "auto" else held).append(unit)
    return auto, held


def journal_row(trigger: str, head: str, hint: dict | None, note: str, units: list[str]) -> dict:
    return {
        "ts": time.time(),
        "trigger": trigger,
        "commit": head,
        "hint": (hint or {}).get("hint"),
        "note": note,
        "units": units,
    }


def backstop_report(rows: list[dict], now: float, backstop_s: int = BACKSTOP_S) -> list[str]:
    """The lines that make a dead trigger visible instead of invisible."""
    out = []
    if not rows:
        return ["NO LOOP HAS EVER RUN"]
    last = rows[-1]
    out.append(f"last convergence {str(last.get('commit', '?'))[:12]} via {last.get('trigger')}")
    webhook = [r for r in rows if r.get("trigger") == "webhook"]
    if not webhook:
        out.append(
            "WEBHOOK HAS NEVER FIRED — every convergence came from the backstop or a manual "
            "poke. That is the trigger being broken, not the box being idle."
        )
        return out
    age = now - float(webhook[-1].get("ts", 0))
    if age > 4 * backstop_s:
        out.append(
            f"RUNNING ON THE BACKSTOP — no webhook-sourced convergence for {int(age)}s while the "
            "timer keeps converging. Everything looks healthy at a coarser latency, which is "
            "exactly how a dead trigger hides."
        )
    else:
        out.append(f"last webhook-sourced convergence {int(age)}s ago")
    return out

#!/usr/bin/env python3
"""Turn one station-accept probe run into PASS / FAIL / NORUN, and say why.

This is the part of acceptance that must be exactly right, so it is a pure
function of a JSON file and is tested without a live station.

THE THREE VERDICTS ARE THREE DIFFERENT ANSWERS, and collapsing any two of them
is how a gate becomes untrustworthy:

  PASS   the station reacted, through the shipping path, AFTER the churn.
  FAIL   it did not. Something to roll back — if, and only if, the control passed.
  NORUN  the probe could not run or its output is unreadable. NOT a failure:
         "I could not look" and "this is broken" must never share a code, because
         only one of them may roll a release back.

WHAT COUNTS AS A PASS — and why each clause is here rather than the obvious
weaker one:

1. A LATER session must have NEGOTIATED. This is the whole point of the churn.
   rhapsody's cutover had a perfect pointer mechanism and 40 SESSION_ACCEPTED
   with zero completed negotiations; every sandbox proof in that wave used ONE
   session and so could not have seen it at any repetition count.
   The cause was **daemon-wide QMP contention from the observation harness**,
   established by a four-run control matrix and corrected here 2026-08-31 — not
   a per-session leak, which was impossible anyway: RealtimeInputSink has no
   session lifecycle hook and InputRouter is built once per station in
   transport::serve, outside the accept loop. A backend building no InputRouter
   at all failed identically with the holder running.
   Two consequences for this file. Sequential churn is CONFIRMED — a daemon-wide
   stall in session start-up is invisible to one session and shows up in the
   second. Churn would have DETECTED that symptom; it could not have DIAGNOSED
   it, which took the same-pass control. A gate owes detection; diagnosis is a
   separate mechanism, and conflating the two nearly got this rule discarded.
   And this failure is exactly the one an over-eager harness can CAUSE, which is
   why a FAIL here is only actionable against the station when the same-pass
   control passed; station-accept.sh, not this module, applies that.

   The ABANDONED session is a weaker claim: its warrant was the disproved leak,
   it has caught nothing, and it stays as a PRECAUTION because an ungraceful
   disconnect is real visitor behaviour rather than a hypothesis. Finding the
   refuted rationale later is not a reason to drop it — it was never justified
   by that rationale.

2. That session must show MOTION IN THE WATCHED RECTANGLE — more than one
   distinct rect signature across the samples. Not `videoWidth`, not
   `readyState`, not non-black percentage: all three PASS ON A STOPPED STREAM,
   which is exactly the state a frozen second session presents. They are
   recorded as preconditions and are never sufficient.

3. If the spec declared a probe point, the click must have produced a repaint
   in the watched rectangle within the sampling budget. A stream that moves on
   its own (a clock) proves the pipe is alive; only a commanded change proves
   INPUT reaches the guest, which is the half rhapsody broke.

MECHANISM, NOT JUST OUTCOME. A test asserting the reported SYMPTOM is gone will
pass a build whose MECHANISM is untouched. Measured 2026-08-30: a purpose-built
test for a stranded button edge went PASS on a fix that was necessary but not
sufficient, while a second test pinning the SHAPE of the failure disagreed — and
the disagreement was right, hiding two further defects including one that would
have reached visitors. So a pass must also assert the properties that make the
reaction repeatable: input actually accepted, nothing dropped or overflowed, no
give-ups. These come from counters the run already collects.

WHICH IS NOT A CONTRADICTION OF "COUNTERS ARE NOT EVIDENCE", and the distinction
is the whole point: **telemetry may only ever SUBTRACT confidence, never add
it.** A healthy counter can never turn a FAIL into a PASS — that is the
substitution §6 forbids, and frozen counters were one of four
true-and-meaningless indicators that day. A sick counter CAN turn a PASS into a
FAIL, because it is naming a mechanism fault the framebuffer happened not to
show this time.

A READ-BACK THAT MATCHES OUR OWN WRITE IS NOT EVIDENCE THE GUEST ACTED. That is
the same trap in a new place, and it has now been measured twice: a coordinate
written while the guest was stopped was never published, so on resume the value
matched our own write and a tick declared convergence while the guest had never
repainted — a session settling at 298,280 for a commanded 300,300. Every clause
below is therefore satisfied by GUEST-SIDE change only: pixels that moved, in a
place we named, after something we commanded.

WHERE TWO CHECKS DISAGREE, THE GATE FAILS RATHER THAN ADJUDICATES. The value in
that incident came entirely from one test contradicting another and a human
trusting the contradiction. A gate that silently prefers the passing check
reproduces the bug it exists to catch. DISAGREE names both results and is red.

AND A MISSING TEMPLATE IS INCONCLUSIVE, NEVER A FAILURE. A `NOTFOUND` from the
cursor matcher was, in that same run, a template bank not covering the station's
glyph set — a harness gap, not a device fault. Rolling a healthy station back
for a missing template is exactly the flapping this design forbids.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

COUNTER_FAULTS = ("dropped", "overflow", "backend-down")


def _delta(counters: dict | None, key: str) -> int | None:
    """How far a counter advanced across the run, or None if unknown."""
    if not counters:
        return None
    before, after = counters.get("before") or {}, counters.get("after") or {}
    if key not in after:
        return None
    return int(after[key]) - int(before.get(key, 0))


def verdict(
    run: dict, returncode: int = 0, counters: dict | None = None, templates: str = "unknown"
) -> tuple[str, str]:
    """(PASS|FAIL|DISAGREE|NORUN, reason).

    `run` is the probe's JSON; `counters` is {"before": {...}, "after": {...}}
    of the station's [input-router] line; `templates` is "ok" | "missing" |
    "unknown" for the cursor bank.
    """
    if returncode != 0:
        return "NORUN", f"the probe exited {returncode} — it could not run, which is not a failure"
    if not isinstance(run, dict) or "sessions" not in run:
        return "NORUN", "unreadable probe output"
    if templates == "missing":
        return (
            "NORUN",
            "this station has no cursor template bank, so the pointer leg cannot be judged — "
            "a NOTFOUND from the matcher is a harness gap, and rolling a healthy station back "
            "for one is exactly the flapping this gate must not do",
        )
    sessions = run.get("sessions") or []
    if not any(s.get("abandoned") for s in sessions):
        return (
            "NORUN",
            "no session was abandoned — a run without churn cannot certify this station, "
            "because the defect it exists to catch is invisible to a single clean session",
        )
    after = [s for s in sessions if not s.get("abandoned") and s.get("index", 0) > run.get("abandonedAt", 0)]
    if not after:
        return "NORUN", "no session ran after the abandoned one — nothing was actually tested"

    negotiated = [s for s in after if s.get("negotiated")]
    if not negotiated:
        return (
            "FAIL",
            f"none of the {len(after)} session(s) after the abandoned one negotiated — "
            "sessions are being serialized or stalled somewhere daemon-wide. CHECK THE "
            "CONTROL BEFORE BLAMING THE STATION: this is the exact shape an observer "
            "holding QEMU's single-client QMP monitor produces, and it is what actually "
            "caused rhapsody's 40-accepted/0-completed regression",
        )
    moving = [s for s in negotiated if (s.get("idle") or {}).get("distinctRect", 0) > 1]
    if not moving:
        return (
            "FAIL",
            "a session after the churn negotiated but its watched rectangle never changed — "
            "a sized, ready, non-black video element showing a stopped stream passes every "
            "surface check and is exactly this state",
        )
    clicked = [s for s in moving if s.get("repaint") is not None]
    repainted = any(s["repaint"].get("changed") for s in clicked) if clicked else None
    if clicked and not repainted:
        return (
            "FAIL",
            "the stream moved but the commanded click produced no repaint — the picture is "
            "live and INPUT is not arriving, which is the half that broke on rhapsody",
        )

    return _mechanism(clicked, repainted, moving, counters)


def _mechanism(clicked: list, repainted: bool | None, moving: list, counters: dict | None) -> tuple[str, str]:
    """Outcome is good. Is the MECHANISM behind it sound and repeatable?"""
    faults = {k: _delta(counters, k) for k in COUNTER_FAULTS}
    broke = {k: v for k, v in faults.items() if v}
    if broke:
        return (
            "FAIL",
            "the station reacted, but its input mechanism did not stay clean across the run "
            f"({', '.join(f'{k}+{v}' for k, v in sorted(broke.items()))}) — a reaction that "
            "leaves work stranded or gives up is not a repeatable one, and the symptom being "
            "gone is not the mechanism being fixed",
        )
    accepted = _delta(counters, "accepted")
    if repainted and accepted is not None and accepted <= 0:
        return (
            "DISAGREE",
            "TWO CHECKS DISAGREE and this gate does not adjudicate: the framebuffer says the "
            "commanded click repainted the guest, while the input router accepted zero events "
            "for the whole run. One of them is wrong and neither may be silently preferred — "
            "the last time a gate preferred the passing check it hid two further defects",
        )
    detail = "with a commanded repaint" if clicked else "motion only (no probe point declared)"
    if accepted is None:
        detail += "; input-router counters unavailable, so the mechanism is UNASSERTED"
    else:
        detail += f"; mechanism clean (accepted+{accepted}, nothing dropped/overflowed/given up)"
    return "PASS", f"{len(moving)} session(s) after the churn negotiated and reacted, {detail}"


def main() -> int:
    if len(sys.argv) < 2:
        print("NORUN usage: station_accept_verdict.py <probe.json> [rc] [counters-json] [templates]")
        return 0
    rc = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    counters = json.loads(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else None
    templates = sys.argv[4] if len(sys.argv) > 4 else "unknown"
    try:
        run = json.loads(Path(sys.argv[1]).read_text())
    except (OSError, ValueError) as exc:
        print(f"NORUN could not read the probe output: {exc}")
        return 0
    state, why = verdict(run, rc, counters, templates)
    print(f"{state} — {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

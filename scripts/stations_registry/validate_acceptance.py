"""Rules for the per-station `acceptance:` stanza (docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md 6).

Lives beside validate_rules.py rather than in it because that module is at its
size cap.

The stanza is OPTIONAL — most stations have no spec yet, and authoring them is
the real ongoing cost of the acceptance gate, done once per station at a natural
recapture. But a stanza that EXISTS must be complete, because a half-specified
acceptance spec is worse than none: `station-accept.sh` refuses to invent a
watched rectangle or a sampling interval, and a spec missing one of them turns
into a refusal at the worst moment rather than an error at commit time.

Two rules here are not obvious and are load-bearing:

* `controlStation` is REQUIRED and must differ from the station itself. Every
  acceptance pass runs a simultaneous control, because the gate can in principle
  cause what it detects — dense observation was measured stopping a session from
  negotiating. Without a control, "the candidate failed" cannot be separated
  from "the box or the harness is unwell", and rolling a healthy release back on
  a harness fault is rollback flapping, which is worse than no gate.

* BOTH sampling bounds must be declared, and they are in tension by
  construction: the floor is set by the need to see the commanded change at all,
  the ceiling by the fact that sampling too densely BECOMES the defect. The
  design deliberately refuses to pick numbers; it requires that each station
  name its own and that the interval sit between them.
"""

from __future__ import annotations

from typing import Any

from .validate_schema import fail

ALLOWED = {
    "watchRect",
    "probePoint",
    "guestSize",
    "controlStation",
    "sessions",
    "abandonAt",
    "sampleIntervalMs",
    "sampleFloorMs",
    "sampleCeilingMs",
    "cursorBank",
    "note",
}


def _ints(value: Any, count: int) -> bool:
    return isinstance(value, list) and len(value) == count and all(isinstance(v, int) for v in value)


def validate_acceptance(rows: list[dict[str, Any]], errors: list[str]) -> None:
    known = {row.get("id") for row in rows}
    specced = {row.get("id") for row in rows if isinstance(row.get("acceptance"), dict)}
    for row in rows:
        spec = row.get("acceptance")
        if spec is None:
            continue
        if not isinstance(spec, dict):
            fail(errors, row, "acceptance must be an object")
            continue
        unknown = sorted(set(spec) - ALLOWED)
        if unknown:
            fail(errors, row, f"acceptance has unknown key(s) {unknown}; allowed: {sorted(ALLOWED)}")

        if not _ints(spec.get("watchRect"), 4):
            fail(errors, row, "acceptance.watchRect must be [x, y, w, h] in guest pixels")
        elif spec["watchRect"][2] <= 0 or spec["watchRect"][3] <= 0:
            fail(errors, row, "acceptance.watchRect must have a positive width and height")

        control = spec.get("controlStation")
        if not control:
            fail(
                errors,
                row,
                "acceptance.controlStation is required — every pass runs a simultaneous "
                "control, or a station fault cannot be told from a harness fault",
            )
        elif control == row.get("id"):
            fail(errors, row, "acceptance.controlStation must be a DIFFERENT station")
        elif control not in known:
            fail(errors, row, f"acceptance.controlStation {control!r} is not a station in this registry")
        elif control not in specced:
            fail(
                errors,
                row,
                f"acceptance.controlStation {control!r} has no acceptance stanza of its own. A "
                "control needs its OWN watched rectangle: sharing the candidate's would make it "
                "fail every run, and a control that cannot pass turns every verdict into "
                "'harness suspect' and blames nobody for anything",
            )

        sessions = spec.get("sessions", 3)
        abandon = spec.get("abandonAt", 2)
        if not isinstance(sessions, int) or sessions < 2:
            fail(
                errors,
                row,
                "acceptance.sessions must be an integer >= 2 — a single-session run certifies "
                "the defect this gate exists to catch, by construction",
            )
        elif not isinstance(abandon, int) or not 1 <= abandon <= sessions:
            fail(errors, row, f"acceptance.abandonAt must name one of the {sessions} sessions")
        elif abandon == sessions:
            fail(
                errors,
                row,
                "acceptance.abandonAt names the LAST session, so nothing runs after the churn "
                "and the run tests nothing; abandon an earlier one",
            )

        _validate_sampling(row, spec, errors)

        if "probePoint" in spec:
            if not _ints(spec.get("probePoint"), 2):
                fail(errors, row, "acceptance.probePoint must be [x, y] in guest pixels")
            if not _ints(spec.get("guestSize"), 2):
                fail(
                    errors,
                    row,
                    "acceptance.probePoint needs acceptance.guestSize [w, h]: the video "
                    "letterboxes, so a guest pixel cannot be mapped to the element without it",
                )


def _validate_sampling(row: dict[str, Any], spec: dict[str, Any], errors: list[str]) -> None:
    interval = spec.get("sampleIntervalMs")
    floor = spec.get("sampleFloorMs")
    ceiling = spec.get("sampleCeilingMs")
    for name, value in (("sampleIntervalMs", interval), ("sampleFloorMs", floor), ("sampleCeilingMs", ceiling)):
        if not isinstance(value, int) or value <= 0:
            fail(
                errors,
                row,
                f"acceptance.{name} must be a positive integer — both bounds are required, and "
                "they are in tension: too sparse misses the defect, too dense BECOMES it",
            )
            return
    if not floor <= interval <= ceiling:
        fail(
            errors,
            row,
            f"acceptance.sampleIntervalMs {interval} must sit between sampleFloorMs {floor} "
            f"and sampleCeilingMs {ceiling}",
        )

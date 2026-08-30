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

import json
from pathlib import Path
from typing import Any

from .constants import REPO
from .validate_schema import fail

ALLOWED = {
    "watchRect",
    "cursorBankBoundTo",
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

        _validate_cursor_bank(row, spec, errors)

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


def _bank_max_sprite(path: Path) -> tuple[int, int] | None:
    """The largest glyph in a bank, or None if it cannot be read."""
    try:
        bank = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    sizes = [(t.get("w", 0), t.get("h", 0)) for t in bank.values() if isinstance(t, dict)]
    return (max(w for w, _ in sizes), max(h for _, h in sizes)) if sizes else None


def _validate_cursor_bank(row: dict[str, Any], spec: dict[str, Any], errors: list[str]) -> None:
    """The cursor bank's traps, encoded where the next author will hit them.

    A bank is an EXACT pixel match, so it is valid only for the golden, colour
    depth and resolution it was learned on. That makes it a FIFTH member of the
    "golden + binary + device set are ONE combination" rule (AGENTS.md rule 6):
    a re-bake, a depth change or a resolution change silently invalidates it,
    and the symptom is a NOTFOUND that reads as "the pointer is not there".
    `cursorBankBoundTo` is required alongside a bank so that binding is written
    down and reviewable rather than remembered.

    The edge rule below has already cost real runs: the matcher rejects any
    placement falling outside the frame, so a probe point too close to an edge
    produces an EXPECTED NotFound that looks exactly like a failure.
    """
    bank_rel = spec.get("cursorBank")
    if not bank_rel:
        if spec.get("cursorBankBoundTo"):
            fail(errors, row, "acceptance.cursorBankBoundTo without acceptance.cursorBank")
        return
    if not spec.get("cursorBankBoundTo"):
        fail(
            errors,
            row,
            "acceptance.cursorBank needs acceptance.cursorBankBoundTo naming the golden, colour "
            "depth and resolution it was learned on. An exact-match bank is a FIFTH member of the "
            "golden+binary+device-set combination: a re-bake or a depth change invalidates it, and "
            "the symptom is a NOTFOUND that reads as 'the pointer is not there'",
        )
    bank = REPO / bank_rel
    if not bank.exists():
        # Not an error: the bank may live on an unmerged branch, and a spec is
        # allowed to be written before the bank lands. station-accept.sh reports
        # a missing bank as INCONCLUSIVE, never as a failure.
        return
    largest = _bank_max_sprite(bank)
    point = spec.get("probePoint")
    size = spec.get("guestSize")
    if not (largest and _ints(point, 2) and _ints(size, 2)):
        return
    max_x = size[0] - largest[0]
    max_y = size[1] - largest[1]
    if point[0] > max_x or point[1] > max_y:
        fail(
            errors,
            row,
            f"acceptance.probePoint {point} leaves no room for the bank's largest glyph "
            f"({largest[0]}x{largest[1]}) inside {size[0]}x{size[1]}: keep x <= {max_x}, "
            f"y <= {max_y}. A sprite clipped by the frame cannot be exact-matched, so the matcher "
            "returns an EXPECTED NotFound that looks exactly like a real failure",
        )

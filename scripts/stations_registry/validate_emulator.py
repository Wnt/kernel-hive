"""Business rule for the per-station `emulator` block (family/version/source/driver).

Lives beside validate_rules.py rather than in it only because that module is at
its size cap; validate() calls this exactly like its sibling rules.
"""

from __future__ import annotations

from typing import Any

from .validate_schema import fail


def validate_emulator(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Every production entry declares its emulator (family/version/source).

    The schema evaluator ignores additionalProperties, so the key allow-list is
    enforced here; `version: null` is legal and means "not recorded" (the
    fleet table renders the gap rather than a guess).
    """
    allowed = {"family", "version", "source", "driver"}
    for row in rows:
        emulator = row.get("emulator")
        if emulator is None:
            if row.get("lifecycle") == "production":
                fail(errors, row, "production entry must declare emulator {family, version, source}")
            continue
        if not isinstance(emulator, dict):
            fail(errors, row, "emulator must be an object")
            continue
        unknown = sorted(set(emulator) - allowed)
        if unknown:
            fail(errors, row, f"emulator has unknown key(s) {unknown}; allowed: {sorted(allowed)}")
        version = emulator.get("version")
        if version is not None and (not isinstance(version, str) or not version.strip()):
            fail(errors, row, "emulator.version must be a non-empty string or null")

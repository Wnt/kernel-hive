"""loaded-drift: is the running process executing the bytes that are on disk?

THE GAP NOTHING ELSE ASKS ABOUT (§2.6, incident I.13). Every existing signal is
green and each is truthfully answering a different question: `box-install`
installed the files, `.deployed-rev` names the commit, the pre-push box-state
stage says live matches the checkout, `systemctl is-active` says active. None of
them asks whether the process serving requests right now was started AFTER the
bytes it is supposed to be running.

Measured 2026-08-31: `osgallery-https` up since 2026-08-26 03:10 with 42
serve-side `.py` files written 2026-08-30 21:42 — the whole auth and walk-in
plane, deployed and never loaded, on a surface whose walk-in access switch reads
`open`. Five days. Nothing reported it, because nothing was looking.

Deliberately CHEAP: one process start time and one mtime walk. A check that
costs nothing is a check that can run on every status, and a check that runs on
every status is one nobody has to remember.

Interpreted-language planes only. A compiled daemon is a different question —
its binary's mtime says nothing about which build is resident — so this reports
Python trees and says so, rather than pretending to a generality it does not
have.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class LoadedDrift:
    unit: str
    process_start: float
    stale: list[tuple[str, float]]  # (path, mtime) newer than the process
    scanned: int

    @property
    def clean(self) -> bool:
        return not self.stale

    @property
    def oldest_stale(self) -> float | None:
        return min((m for _, m in self.stale), default=None)


def drift_for(unit: str, process_start: float, files: dict[str, float]) -> LoadedDrift:
    """Pure core: which files were written after the process began?

    COMPARED AT WHOLE-SECOND GRANULARITY, and that is not a rounding nicety —
    it is the difference between a useful check and one people learn to ignore.
    The two clocks have different precision: `find -printf %T@` reports a
    FRACTIONAL mtime, while a process start read from `/proc/<pid>` is a whole
    second. Install a file and restart within the same second — which is exactly
    the normal deploy sequence — and the fractional mtime is arithmetically
    greater than the truncated start, so the file reads as never loaded when it
    demonstrably is.

    Measured 2026-08-31: `deploy_hint.py` at 1788152288.4 against a process
    start of 1788152288, reported APPLIED-BUT-NOT-LOADED while the running
    process was provably executing that very file. A true-looking number
    produced by a unit mismatch unrelated to the question — the same shape as
    every other false signal this design was written from.
    """
    stale = sorted(((p, m) for p, m in files.items() if int(m) > int(process_start)), key=lambda x: x[1])
    return LoadedDrift(unit=unit, process_start=process_start, stale=stale, scanned=len(files))


def render(drift: LoadedDrift, now: float) -> list[str]:
    if drift.process_start <= 0:
        return [f"  {drift.unit}: SKIPPED — could not read the process start time"]
    if drift.clean:
        return [f"  {drift.unit}: ok — all {drift.scanned} file(s) predate the running process"]
    age_h = (now - drift.oldest_stale) / 3600.0
    lines = [
        f"  {drift.unit}: APPLIED-BUT-NOT-LOADED — {len(drift.stale)} of {drift.scanned} file(s) "
        f"were written AFTER the process started; oldest such write was {age_h:.1f}h ago",
        "    The bytes are deployed and the process is not running them. `systemctl is-active`",
        "    is green and says nothing about this. A restart is what closes it.",
    ]
    for path, _ in drift.stale[:8]:
        lines.append(f"      {path}")
    if len(drift.stale) > 8:
        lines.append(f"      ... and {len(drift.stale) - 8} more")
    return lines


# --- box-side reading (read-only; SKIPs loudly when the box is unreachable) ---

PROBE = (
    "systemctl show {unit} -p ExecMainStartTimestampMonotonic -p ExecMainPID --value 2>/dev/null; "
    "echo ---; date +%s; echo ---; stat -c '%Y' /proc/$(systemctl show {unit} -p ExecMainPID --value)"
    " 2>/dev/null; echo ---; find {tree} -name '*.py' -printf '%T@ %p\\n' 2>/dev/null"
)


def parse_probe(text: str) -> tuple[float, dict[str, float]]:
    """(process start epoch, {path: mtime}). Zero start means 'could not read'."""
    parts = text.split("---")
    start = 0.0
    if len(parts) >= 3:
        try:
            start = float(parts[2].strip().splitlines()[0])
        except (ValueError, IndexError):
            start = 0.0
    files: dict[str, float] = {}
    if len(parts) >= 4:
        for line in parts[3].splitlines():
            mtime, _, path = line.strip().partition(" ")
            if path:
                try:
                    files[path] = float(mtime)
                except ValueError:
                    continue
    return start, files

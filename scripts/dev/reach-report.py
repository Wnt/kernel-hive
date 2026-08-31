#!/usr/bin/env python3
"""reach-report — what production actually uses, beside what the tests cover.

    scripts/dev/reach-report.py                       # live box, last 30 days
    scripts/dev/reach-report.py --days 365
    scripts/dev/reach-report.py --class probe         # what the e2e fleet drives
    scripts/dev/reach-report.py --report /tmp/r.json  # an already-fetched report

WHAT THIS IS FOR. Test coverage tells you which lines a test touched. It cannot
tell you whether anybody NEEDS those lines, so a thoroughly-tested feature that
no visitor has opened since March looks exactly like the healthiest code in the
repo. Crossing the two axes is what makes the question answerable:

                    | reached in production | never reached
    ----------------+-----------------------+------------------------------
    covered by unit | HEALTHY               | PAYING TWICE — tests maintained
    tests           |                       | for something nobody uses
    ----------------+-----------------------+------------------------------
    not covered     | EXPOSED — used, and   | DEAD — the cheapest deletion
                    | nothing catches a     | in the repo, and the first
                    | regression            | place to look for one

The third axis is the one a hit counter cannot see at all, and it is the reason
this plane grades every observation (spa/src/analytics/intent.ts): a probe with
a large `auto` count and a zero `act` count is an endpoint that is called on
every page load and whose answer nobody ever uses. That is not a dead feature,
it is a live COST, and it shows up in the AUTO VS ACT table below rather than in
the quadrants.

WHAT IT DOES NOT CLAIM. `never reached` means "no tab reported reaching it in
the window", which is not the same as "unreachable". Read the window before the
verdict: a 30-day window over a private gallery with a handful of visits says
much less than a 365-day one. And the counts are the client's own account of
what it did (serve/analytics.py) — right for deciding what to build next, wrong
for anything that has to be true.
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / "registry" / "analytics-catalogue.json"
COVERAGE = ROOT / "spa" / "coverage" / "coverage-final.json"
EXCLUSIONS = ROOT / "spa" / "coverage-exclusions.json"


def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except ValueError as exc:
        sys.stderr.write(f"reach-report: {path} is not valid JSON ({exc})\n")
        return None


def fetch_report(url: str, days: int, klass: str):
    """GET the aggregate off the box. The LAN listener uses the lab's own CA, so
    a plain urlopen would fail cert validation on a workstation that has not
    installed it; this is a read of a document with no identities in it, over
    the lab LAN, so the check is skipped rather than made a prerequisite."""
    full = f"{url.rstrip('/')}/analytics/report.json?days={days}&class={klass}"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(full, timeout=15, context=ctx) as resp:  # noqa: S310 - fixed scheme
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, ValueError, OSError) as exc:
        sys.stderr.write(f"reach-report: cannot read {full} ({exc})\n")
        return None


def coverage_by_file() -> dict[str, float]:
    """statement coverage %, keyed by spa-relative path. Empty when the SPA's
    coverage run has not been made (`cd spa && npx vitest run --coverage`)."""
    raw = load_json(COVERAGE)
    if not raw:
        return {}
    out: dict[str, float] = {}
    for abs_path, entry in raw.items():
        counts = (entry or {}).get("s") or {}
        if not counts:
            continue
        hit = sum(1 for v in counts.values() if v)
        rel = abs_path.split("/spa/", 1)[-1] if "/spa/" in abs_path else abs_path
        out[rel] = 100.0 * hit / len(counts)
    return out


def excluded_files() -> dict[str, str]:
    """Modules DELIBERATELY outside the unit-test scope, and the written reason.
    An owner file listed here is not `untested`; it is a third state, and
    conflating the two would put a documented decision in the DEAD quadrant."""
    raw = load_json(EXCLUSIONS) or {}
    return {e["file"]: e["reason"] for e in raw.get("exclusions", []) if "file" in e}


def quadrant(reached: bool, cov: float | None, excluded: bool) -> str:
    if cov is None:
        return "REACHED (no unit scope)" if reached else "NEVER REACHED (no unit scope)"
    if reached:
        return "HEALTHY" if cov > 0 else "EXPOSED"
    return "PAYING TWICE" if cov > 0 else "DEAD"


def percentile(buckets: dict[str, int], p: float) -> tuple[str, int]:
    """The bucket EDGE at percentile `p`, and the total sample count.

    Returned as an edge, and printed as "<= edge", because that is the entire
    truth the data holds: the tab bucketed the value before sending it
    (spa/src/analytics/metrics.ts), deliberately, so that a durable years-long
    aggregate never becomes a behavioural trace of one visitor's session. A
    tool that interpolated inside a bucket to print `p95 = 2847 ms` would be
    inventing three digits nobody measured — and would be believed.
    """
    total = sum(buckets.values())
    if not total:
        return ("-", 0)
    # `inf` sorts last; every other bucket is its numeric edge.
    edges = sorted(buckets, key=lambda b: float("inf") if b == "inf" else int(b))
    want = total * p
    seen = 0
    for edge in edges:
        seen += buckets[edge]
        if seen >= want:
            return (edge, total)
    return (edges[-1], total)


def fmt_edge(edge: str, scale: str) -> str:
    if edge in ("-", "inf"):
        return "over max" if edge == "inf" else "-"
    if scale == "ms":
        n = int(edge)
        return f"{n / 1000:.1f}s" if n >= 1000 else f"{n}ms"
    return f"{edge}%" if scale == "pct" else edge


def row(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="https://127.0.0.1:8443", help="gallery listener (default: the LAN one)")
    ap.add_argument("--days", type=int, default=30, help="window, in days (default 30)")
    ap.add_argument("--class", dest="klass", default="human", choices=("human", "probe", "unknown"))
    ap.add_argument("--report", type=Path, help="read an already-fetched report.json instead of the box")
    ap.add_argument("--json", action="store_true", help="emit the joined table as JSON")
    args = ap.parse_args()

    catalogue = load_json(CATALOGUE)
    if not catalogue:
        sys.stderr.write(f"reach-report: no catalogue at {CATALOGUE} — run `make analytics-catalogue`\n")
        return 2
    report = load_json(args.report) if args.report else fetch_report(args.url, args.days, args.klass)
    if report is None:
        return 1

    probes = catalogue.get("probes", {})
    observed = report.get("probes", {})
    cov = coverage_by_file()
    excl = excluded_files()

    rows = []
    for pid in sorted(probes):
        spec = probes[pid]
        grades = observed.get(pid, {})
        total = sum(grades.values())
        owner = spec["owner"]
        is_excl = owner in excl
        rows.append(
            {
                "probe": pid,
                "area": spec["area"],
                "owner": owner,
                "what": spec["what"],
                "auto": grades.get("auto", 0),
                "show": grades.get("show", 0),
                "act": grades.get("act", 0),
                "total": total,
                "coverage": None if is_excl or owner not in cov else round(cov[owner], 1),
                "excluded": excl.get(owner),
                "verdict": quadrant(total > 0, None if is_excl or owner not in cov else cov[owner], is_excl),
                "consumes": spec.get("consumes"),
            }
        )

    if args.json:
        print(json.dumps({"window": report.get("window"), "rows": rows, "flows": report.get("flows", {})}, indent=2))
        return 0

    w = report.get("window", {})
    print(
        f"\n=== FEATURE REACH — last {w.get('days', '?')} days, class={w.get('class', '?')}, "
        f"last report {report.get('lastAt') or 'never'} ===\n"
    )
    print(f"  {'probe':30}  {'auto':>7} {'show':>7} {'act':>7}  {'cov%':>6}  verdict")
    print(f"  {'-' * 30}  {'-' * 7} {'-' * 7} {'-' * 7}  {'-' * 6}  {'-' * 28}")
    for r in rows:
        covs = "—" if r["coverage"] is None else f"{r['coverage']:.0f}"
        print(f"  {row(r['probe'], 30):30}  {r['auto']:>7} {r['show']:>7} {r['act']:>7}  {covs:>6}  {r['verdict']}")

    tally: dict[str, int] = {}
    for r in rows:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    print("\n  " + "   ".join(f"{v}: {n}" for v, n in sorted(tally.items(), key=lambda kv: -kv[1])))
    blind = sum(n for v, n in tally.items() if "no unit scope" in v)
    if blind:
        # Worth saying out loud rather than leaving as a column of em-dashes:
        # the quadrants only exist where BOTH axes have data, and the SPA's
        # unit-test scope is deliberately narrow (vitest.config.ts covers
        # pure-logic modules only). Every probe in a DOM-heavy file is a row
        # this report can place on the usage axis and not on the tested one.
        print(f"\n  note: {blind} of {len(rows)} probes live in files outside the unit-test scope, so they")
        print("        have a usage verdict and no coverage one. Widening vitest's coverage.include")
        print("        (or an istanbul-instrumented bundle — docs/ANALYTICS.md §6) fills that column.")

    pairs = [r for r in rows if r["consumes"]]
    if pairs:
        print("\n=== AUTO VS ACT — is the request earning its answer? ===\n")
        for r in pairs:
            src = next((x for x in rows if x["probe"] == r["consumes"]), None)
            calls = src["auto"] if src else 0
            used = r["show"] + r["act"]
            pct = f"{100.0 * used / calls:.1f}%" if calls else "n/a"
            print(
                f"  {row(r['consumes'], 26):26} called {calls:>7}   ->  "
                f"{row(r['probe'], 26):26} used {used:>7}  ({pct})"
            )

    metrics = catalogue.get("metrics", {})
    observed_metrics = report.get("metrics", {})
    if metrics:
        print("\n=== METRICS — how long, and how much effort ===\n")
        print(f"  {'metric':34} {'n':>6}  {'p50':>9} {'p75':>9} {'p95':>9}   what a high value means")
        print(f"  {'-' * 34} {'-' * 6}  {'-' * 9} {'-' * 9} {'-' * 9}   {'-' * 30}")
        for mid in sorted(metrics):
            spec = metrics[mid]
            buckets = observed_metrics.get(mid, {})
            p50, total = percentile(buckets, 0.50)
            p75, _ = percentile(buckets, 0.75)
            p95, _ = percentile(buckets, 0.95)
            scale = spec["scale"]
            cells = "  ".join(f"{('<= ' + fmt_edge(e, scale)) if e != '-' else '-':>9}" for e in (p50, p75, p95))
            print(f"  {row(mid, 34):34} {total:>6}  {cells}   {row(spec['what'], 40)}")
        silent = [m for m in metrics if not observed_metrics.get(m)]
        if silent:
            # A metric with no samples is the same ambiguous zero a probe with
            # no hits would be, except the gate has already ruled out "never
            # called". So it is a real statement: nobody reached this path in
            # the window.
            print(
                f"\n  {len(silent)} metric(s) recorded nothing in this window: {', '.join(sorted(silent)[:6])}"
                + (" …" if len(silent) > 6 else "")
            )

    flows = report.get("flows", {})
    if flows:
        print("\n=== FLOWS — where attempts die ===\n")
        for fid, steps in sorted(flows.items()):
            spec = catalogue.get("flows", {}).get(fid, {})
            print(f"  {fid}: {spec.get('what', '')}")
            for step in spec.get("steps", sorted(steps)):
                s = steps.get(step, {})
                print(f"    {step:22} entered {s.get('enter', 0):>6}  ok {s.get('ok', 0):>6}")
            extra = {k: v for k, v in steps.items() if k not in spec.get("steps", [])}
            for name, s in sorted(extra.items()):
                if s.get("fail"):
                    print(f"    {'FAIL ' + name:22} {s['fail']:>14}")
            print()

    errors = report.get("errors", [])
    if errors:
        print("=== ERRORS BY FLOW — most frequent first ===\n")
        print(f"  {'count':>7}  {'fingerprint':11} {'flow / step':30} message")
        for e in errors[:20]:
            where = f"{e['flow'] or '(none)'} / {e['step'] or '-'}"
            print(f"  {e['n']:>7}  {e['fp']:11} {row(where, 30):30} {row(e['message'], 60)}")
        print()

    if not cov:
        print("note: no SPA coverage data — run `cd spa && npx vitest run --coverage` for the cov% column.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

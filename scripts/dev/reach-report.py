#!/usr/bin/env python3
"""reach-report — what production actually uses, beside what the tests cover.

    scripts/dev/reach-report.py                       # live box, last 30 days
    scripts/dev/reach-report.py --days 365
    scripts/dev/reach-report.py --class probe         # what the e2e fleet drives
    scripts/dev/reach-report.py --report /tmp/r.json  # an already-fetched report
    scripts/dev/reach-report.py --prod /tmp/coverage.json   # a fetched line-coverage report

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

THREE AXES, NOT TWO, AND THEY ARE NOT INTERCHANGEABLE. `covered by unit tests`
is a fact about the test suite. `reached in production` is a fact about the
DECLARED probes — a catalogue somebody wrote, so its blind spot is exactly the
code nobody thought to declare. `executed in production` (serve/linecov.py, fed
by the opt-in instrumented bundle) is a fact about LINES, with the compiler for
a denominator. They answer different questions and this report keeps them in
separate columns on purpose: a file can be 90% unit-covered and have never run a
line in front of a visitor, and collapsing that into one number is how a dead
module keeps its budget. The line axis is empty unless somebody has built and
served the instrumented bundle (docs/ANALYTICS.md §6); it is not on by default.

The intent grade is the axis a hit counter cannot see at all, and it is the reason
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


def fetch_json(url: str, route: str, days: int, klass: str):
    """GET one of the box's aggregates. The LAN listener uses the lab's own CA, so
    a plain urlopen would fail cert validation on a workstation that has not
    installed it; this is a read of a document with no identities in it, over
    the lab LAN, so the check is skipped rather than made a prerequisite."""
    full = f"{url.rstrip('/')}{route}?days={days}&class={klass}"
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


def prod_by_file(report) -> dict[str, float]:
    """executed% of instrumented lines, keyed by the same spa-relative path the
    unit axis uses. Empty when nobody has served an instrumented bundle."""
    files = (report or {}).get("files") or {}
    return {name: entry.get("pct", 0.0) for name, entry in files.items() if entry.get("lines")}


def file_quadrant(unit: float | None, prod: float | None) -> str:
    """The §6 grid, per FILE rather than per probe. `prod` is None when this
    build's map has nothing for the file at all, which is a third state: not
    `never executed` but `never instrumented`, and reporting it as the first
    would put a module the instrumented build never saw in the DEAD box."""
    if prod is None:
        return "no line data"
    if unit is None:
        return "EXPOSED (no unit scope)" if prod > 0 else "DEAD (no unit scope)"
    if prod > 0:
        return "HEALTHY" if unit > 0 else "EXPOSED"
    return "PAYING TWICE" if unit > 0 else "DEAD"


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


def file_rows(cov, excl, prod, prod_report) -> list[dict]:
    """One row per file that EITHER axis knows about — the union, not the
    intersection. A file the instrumented build saw and the unit suite has never
    heard of is the whole point of this section, and an inner join would hide
    exactly those."""
    names = sorted(set(cov) | set(prod) | set(excl if prod_report else {}))
    out = []
    for name in names:
        unit = None if name in excl else cov.get(name)
        line = prod.get(name) if prod_report else None
        out.append(
            {
                "file": name,
                "unit": None if unit is None else round(unit, 1),
                "line": None if line is None else round(line, 1),
                "excluded": excl.get(name),
                "verdict": file_quadrant(unit, line),
            }
        )
    return out


def print_files(files, prod_report) -> None:
    """The §6 quadrants, per file. This is the section the probe table cannot
    be: probes only exist where somebody declared one, so the table above can
    never contain a row for code nobody suspected."""
    if not prod_report:
        print("\n=== PRODUCTION LINE COVERAGE ===\n")
        print("  no data: nothing has served the instrumented bundle to this box.")
        print("  build it with `cd spa && npm run build:coverage` — docs/ANALYTICS.md §6.\n")
        return
    w = prod_report.get("window", {})
    print(
        f"\n=== PRODUCTION LINE COVERAGE — build {w.get('build') or 'none'}, "
        f"last {w.get('days', '?')} days, class={w.get('class', '?')} ===\n"
    )
    print(f"  {'file':46}  {'cov%':>6} {'line%':>6}  verdict")
    print(f"  {'-' * 46}  {'-' * 6} {'-' * 6}  {'-' * 24}")
    for f in files:
        if f["line"] is None:
            continue
        u = "—" if f["unit"] is None else f"{f['unit']:.0f}"
        print(f"  {row(f['file'], 46):46}  {u:>6} {f['line']:>6.0f}  {f['verdict']}")
    tally: dict[str, int] = {}
    for f in files:
        if f["line"] is not None:
            tally[f["verdict"]] = tally.get(f["verdict"], 0) + 1
    if tally:
        print("\n  " + "   ".join(f"{v}: {n}" for v, n in sorted(tally.items(), key=lambda kv: -kv[1])))
    missing = [f["file"] for f in files if f["line"] is None]
    if missing:
        # Not the same as `never executed` and it must not read like it: the
        # instrumented build had no statement map for these at all.
        print(f"\n  note: {len(missing)} known file(s) carry no line data for this build")
        print("        (not instrumented, or renamed since it was built).")
    print()


def row(text: str, width: int) -> str:
    return text if len(text) <= width else text[: width - 1] + "…"


def server_reach(catalogue: dict, report: dict, as_json: bool) -> int:
    """The Python serving plane's own branch reach (docs/ANALYTICS.md §7).

    A separate table rather than more rows in the one above, for the same reason
    the store keys everything by class: these are not features a visitor uses,
    they are BRANCHES the server took, and summing the two would make a refusal
    that never fires look like a feature nobody clicked. There is no coverage
    column — the quadrants cross production reach with the SPA's vitest data,
    and no Python equivalent is wired into this report.
    """
    probes = catalogue.get("serverProbes", {})
    observed = report.get("probes", {})
    rows = [
        {
            "probe": pid,
            "area": spec["area"],
            "owner": spec["owner"],
            "what": spec["what"],
            "n": sum(observed.get(pid, {}).values()),
            "consumes": spec.get("consumes"),
        }
        for pid, spec in sorted(probes.items())
    ]
    if as_json:
        print(json.dumps({"window": report.get("window"), "serverRows": rows}, indent=2))
        return 0
    w = report.get("window", {})
    print(f"\n=== SERVER BRANCH REACH — last {w.get('days', '?')} days ===\n")
    print(f"  {'probe':34}  {'taken':>8}  owner")
    print(f"  {'-' * 34}  {'-' * 8}  {'-' * 34}")
    for r in rows:
        print(f"  {row(r['probe'], 34):34}  {r['n']:>8}  {row(r['owner'], 34)}")
    cold = [r for r in rows if not r["n"]]
    if cold:
        print(f"\n  {len(cold)} of {len(rows)} branches were never taken in this window. Each is either dead")
        print("  code or a refusal that has never been needed, and `what` in the catalogue says which")
        print("  question a zero answers. `never taken` is not `unreachable` — read the window first.")
    pairs = [r for r in rows if r["consumes"]]
    if pairs:
        print("\n=== PRECONDITION VS BRANCH — is the fallback reachable at all? ===\n")
        for r in pairs:
            src = next((x for x in rows if x["probe"] == r["consumes"]), None)
            outer = src["n"] if src else 0
            pct = f"{100.0 * r['n'] / outer:.1f}%" if outer else "n/a"
            print(
                f"  {row(r['consumes'], 30):30} taken {outer:>7}   ->  "
                f"{row(r['probe'], 30):30} taken {r['n']:>7}  ({pct})"
            )
    print()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="https://127.0.0.1:8443", help="gallery listener (default: the LAN one)")
    ap.add_argument("--days", type=int, default=30, help="window, in days (default 30)")
    ap.add_argument("--class", dest="klass", default="human", choices=("human", "probe", "unknown", "server"))
    ap.add_argument("--report", type=Path, help="read an already-fetched report.json instead of the box")
    ap.add_argument("--prod", type=Path, help="read an already-fetched coverage/report.json instead of the box")
    ap.add_argument("--no-prod", action="store_true", help="skip the production line-coverage axis entirely")
    ap.add_argument("--json", action="store_true", help="emit the joined table as JSON")
    args = ap.parse_args()

    catalogue = load_json(CATALOGUE)
    if not catalogue:
        sys.stderr.write(f"reach-report: no catalogue at {CATALOGUE} — run `make analytics-catalogue`\n")
        return 2
    report = (
        load_json(args.report) if args.report else fetch_json(args.url, "/analytics/report.json", args.days, args.klass)
    )
    if report is None:
        return 1
    # The line axis is OPTIONAL and its absence is not an error: the box only
    # has data here if somebody deliberately served the instrumented bundle, so
    # a box that never has reads as an empty section rather than a failed run.
    if args.no_prod:
        prod_report = None
    elif args.prod:
        prod_report = load_json(args.prod)
    elif args.report:
        # `--report <file>` is the OFFLINE path — an aggregate fetched earlier,
        # or one carried off the box by hand. Reaching for the live coverage
        # endpoint anyway made the supported offline run print a connection
        # error it could do nothing about, which teaches a reader to ignore the
        # tool's errors. Pair `--report` with `--prod <file>` for the line axis.
        prod_report = None
    else:
        prod_report = fetch_json(args.url, "/coverage/report.json", args.days, args.klass)

    if args.klass == "server":
        return server_reach(catalogue, report, args.json)

    probes = catalogue.get("probes", {})
    observed = report.get("probes", {})
    cov = coverage_by_file()
    excl = excluded_files()
    prod = prod_by_file(prod_report)

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
                "prodLines": prod.get(owner),
                "excluded": excl.get(owner),
                "verdict": quadrant(total > 0, None if is_excl or owner not in cov else cov[owner], is_excl),
                "consumes": spec.get("consumes"),
            }
        )

    files = file_rows(cov, excl, prod, prod_report)
    if args.json:
        print(
            json.dumps(
                {
                    "window": report.get("window"),
                    "rows": rows,
                    "flows": report.get("flows", {}),
                    "lineWindow": (prod_report or {}).get("window"),
                    "files": files,
                },
                indent=2,
            )
        )
        return 0

    w = report.get("window", {})
    print(
        f"\n=== FEATURE REACH — last {w.get('days', '?')} days, class={w.get('class', '?')}, "
        f"last report {report.get('lastAt') or 'never'} ===\n"
    )
    print(f"  {'probe':30}  {'auto':>7} {'show':>7} {'act':>7}  {'cov%':>6} {'line%':>6}  verdict")
    print(f"  {'-' * 30}  {'-' * 7} {'-' * 7} {'-' * 7}  {'-' * 6} {'-' * 6}  {'-' * 28}")
    for r in rows:
        covs = "—" if r["coverage"] is None else f"{r['coverage']:.0f}"
        # `cov%` is the owner file under the unit suite; `line%` is the SAME
        # file's lines in front of visitors. Adjacent, never added together.
        prods = "—" if r["prodLines"] is None else f"{r['prodLines']:.0f}"
        print(
            f"  {row(r['probe'], 30):30}  {r['auto']:>7} {r['show']:>7} {r['act']:>7}  "
            f"{covs:>6} {prods:>6}  {r['verdict']}"
        )

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
        print("        have a usage verdict and no cov% one. The line% beside it is the OTHER")
        print("        axis, not a substitute: it is the owner file's production lines, and a")
        print("        file can be busy in production and still have no test catching a")
        print("        regression in it. Widening vitest's coverage.include fills cov%.")

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

    print_files(files, prod_report)

    if not cov:
        print("note: no SPA coverage data — run `cd spa && npx vitest run --coverage` for the cov% column.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

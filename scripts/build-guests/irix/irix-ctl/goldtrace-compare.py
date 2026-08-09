#!/usr/bin/env python3
"""Diff two golden-trace recordings (issue #45 Stage 1): the A3 parity gate.

Takes the two JSONL traces goldtrace-record.py wrote — one per arm, same
corpus, identically prepared clones — and decides whether the mamectl module's
guest-visible behavior matches the Lua agent's, bug-for-bug:

HARD checks (any failure = divergence, exit 1):
  * same corpus (sha), same injected verb sequence;
  * per !expect: measured verdicts EQUAL and both passing — including the
    binding case: the deterministic (300,500) chooser give-up settling at
    ~(186,386) must REPRODUCE in both arms (fixing it is a parity FAILURE
    on this gate; improvements go on the follow-up A3 track);
  * settle points within --tol-settle px of each other;
  * footer giveups delta equal (when both arms report one);
  * signature probes agree on CHANGED-vs-UNCHANGED between consecutive probes
    (a click that opens a menu in one arm and not the other).

SOFT checks (warnings; hard under --strict-soft):
  * per-MOVEA hop duration and trajectory path length in the same ballpark
    (pacing dominates both; pickup-latency differences are the A/B rig's
    business, not this gate's);
  * trajectory stays inside the start->target bounding box + pad (overshoot);
  * absolute signature mean/sd closeness.

Exit codes: 0 parity; 1 divergence; 2 usage/load error.
"""

import argparse
import json
import math
import sys


def load(path):
    t = {"meta": None, "cmds": [], "expects": [], "sigs": [], "settles": [], "samples": {}, "footer": None}
    with open(path, encoding="utf-8") as f:
        for lineno, ln in enumerate(f, 1):
            ln = ln.strip()
            if not ln:
                continue
            try:
                r = json.loads(ln)
            except json.JSONDecodeError as e:
                print(f"goldtrace-compare: {path}:{lineno}: bad JSONL ({e}) — truncated recording?", file=sys.stderr)
                raise SystemExit(2) from e
            k = r.get("type")
            if k == "meta":
                t["meta"] = r
            elif k == "cmd":
                t["cmds"].append(r)
            elif k == "expect":
                t["expects"].append(r)
            elif k == "sig":
                t["sigs"].append(r)
            elif k == "settle":
                t["settles"].append(r)
            elif k == "sample":
                t["samples"].setdefault(r["i"], []).append(r)
            elif k == "footer":
                t["footer"] = r
    if t["meta"] is None or t["footer"] is None:
        print(f"goldtrace-compare: {path}: incomplete trace (missing meta/footer)", file=sys.stderr)
        raise SystemExit(2)
    return t


def groups(t):
    """Per !expect: the nearest preceding MOVEA cmd + settle + its samples."""
    out = []
    for e in t["expects"]:
        movea = next((c for c in reversed(t["cmds"]) if c["i"] < e["i"] and c["line"].startswith("MOVEA")), None)
        settle = next((s for s in reversed(t["settles"]) if s["i"] < e["i"]), None)
        samples = t["samples"].get(settle["i"], []) if settle else []
        out.append({"e": e, "movea": movea, "settle": settle, "samples": samples})
    return out


def path_len(samples):
    d = 0.0
    for a, b in zip(samples, samples[1:]):
        d += math.hypot(b["x"] - a["x"], b["y"] - a["y"])
    return d


def overshoot_violations(g, pad):
    """Samples outside the (start, target) bounding box + pad."""
    if not g["samples"] or not g["movea"] or "target" not in g["movea"]:
        return 0
    tx, ty = g["movea"]["target"]
    sx, sy = g["samples"][0]["x"], g["samples"][0]["y"]
    x0, x1 = min(sx, tx) - pad, max(sx, tx) + pad
    y0, y1 = min(sy, ty) - pad, max(sy, ty) + pad
    return sum(1 for s in g["samples"] if not (x0 <= s["x"] <= x1 and y0 <= s["y"] <= y1))


def sig_changes(sigs, thr):
    """CHANGED booleans between consecutive signature probes."""
    out = []
    for a, b in zip(sigs, sigs[1:]):
        out.append(abs(b["mean"] - a["mean"]) > thr or abs(b["sd"] - a["sd"]) > thr)
    return out


class Report:
    def __init__(self):
        self.hard = 0
        self.soft = 0

    def ok(self, msg):
        print(f"  OK   {msg}")

    def fail(self, msg):
        self.hard += 1
        print(f"  FAIL {msg}")

    def warn(self, msg):
        self.soft += 1
        print(f"  warn {msg}")


def main():
    ap = argparse.ArgumentParser(description="diff two golden-trace arms (see module docstring)")
    ap.add_argument("trace_a")
    ap.add_argument("trace_b")
    ap.add_argument("--tol-settle", type=float, default=6.0, help="max px between the arms' settle points")
    ap.add_argument("--tol-hop-s", type=float, default=0.4, help="hop-duration slack, s (plus 25%% relative)")
    ap.add_argument("--tol-path", type=float, default=0.35, help="relative path-length slack")
    ap.add_argument("--tol-overshoot", type=float, default=48.0, help="trajectory bbox pad, px")
    ap.add_argument("--sig-thr", type=float, default=0.001, help="mean/sd delta that counts as CHANGED")
    ap.add_argument("--tol-sig-abs", type=float, default=0.02, help="cross-arm absolute sig tolerance")
    ap.add_argument("--allow-corpus-mismatch", action="store_true")
    ap.add_argument("--strict-soft", action="store_true", help="soft warnings also fail the gate")
    args = ap.parse_args()

    a, b = load(args.trace_a), load(args.trace_b)
    rep = Report()
    na, nb = a["meta"]["arm"], b["meta"]["arm"]
    print(f"goldtrace-compare: {na} ({args.trace_a}) vs {nb} ({args.trace_b})")

    if a["meta"]["corpus_sha256"] != b["meta"]["corpus_sha256"]:
        if args.allow_corpus_mismatch:
            rep.warn("corpus sha256 differs (--allow-corpus-mismatch)")
        else:
            rep.fail("corpus sha256 differs — traces are not comparable")
    else:
        rep.ok("same corpus")

    la, lb = [c["line"] for c in a["cmds"]], [c["line"] for c in b["cmds"]]
    if la != lb:
        rep.fail(f"injected verb sequences differ ({len(la)} vs {len(lb)} cmds)")
        for i, (x, y) in enumerate(zip(la, lb)):
            if x != y:
                rep.fail(f"  first divergence at cmd {i}: {x!r} vs {y!r}")
                break
    else:
        rep.ok(f"identical verb sequence ({len(la)} cmds)")

    ga, gb = groups(a), groups(b)
    if len(ga) != len(gb):
        rep.fail(f"expect counts differ: {len(ga)} vs {len(gb)}")
    for i, (x, y) in enumerate(zip(ga, gb)):
        ea, eb = x["e"], y["e"]
        tag = f"expect[{i}] {ea.get('label', '')} want={ea['want']}"
        if ea["verdict"] != eb["verdict"]:
            rep.fail(f"{tag}: verdicts differ — {na}={ea['verdict']} {nb}={eb['verdict']}")
            continue
        if not (ea["pass"] and eb["pass"]):
            rep.fail(f"{tag}: expectation failed ({na} pass={ea['pass']}, {nb} pass={eb['pass']})")
        if ea["settle"] and eb["settle"]:
            d = math.hypot(ea["settle"][0] - eb["settle"][0], ea["settle"][1] - eb["settle"][1])
            if d > args.tol_settle:
                rep.fail(f"{tag}: settle points {d:.1f} px apart (> {args.tol_settle})")
            else:
                rep.ok(f"{tag}: {ea['verdict']}, settle within {d:.1f} px")
        else:
            rep.fail(f"{tag}: missing settle point ({na}={ea['settle']} {nb}={eb['settle']})")
        # soft: hop shape
        if x["movea"] and y["movea"] and x["settle"] and y["settle"]:
            da = x["settle"]["t"] - x["movea"]["t"]
            db = y["settle"]["t"] - y["movea"]["t"]
            if abs(da - db) > args.tol_hop_s + 0.25 * max(da, db):
                rep.warn(f"{tag}: hop durations {da:.2f}s vs {db:.2f}s")
            pa, pb = path_len(x["samples"]), path_len(y["samples"])
            base = max(pa, pb, 30.0)
            if abs(pa - pb) / base > args.tol_path:
                rep.warn(f"{tag}: trajectory path lengths {pa:.0f}px vs {pb:.0f}px")
            va = overshoot_violations(x, args.tol_overshoot)
            vb = overshoot_violations(y, args.tol_overshoot)
            if (va > 0) != (vb > 0):
                rep.warn(f"{tag}: overshoot outside bbox+{args.tol_overshoot:.0f}px in one arm only ({va} vs {vb})")

    fa, fb_ = a["footer"].get("giveups_delta"), b["footer"].get("giveups_delta")
    if fa is not None and fb_ is not None:
        if fa != fb_:
            rep.fail(f"giveups delta differs: {na}={fa} {nb}={fb_}")
        else:
            rep.ok(f"giveups delta equal ({fa})")
    else:
        rep.warn(f"giveups delta unavailable ({na}={fa} {nb}={fb_}) — stats footer missing in one arm")

    sa, sb = a["sigs"], b["sigs"]
    if len(sa) != len(sb):
        rep.fail(f"sig probe counts differ: {len(sa)} vs {len(sb)}")
    else:
        ca, cb = sig_changes(sa, args.sig_thr), sig_changes(sb, args.sig_thr)
        if ca != cb:
            rep.fail(f"sig changed-flags differ: {na}={ca} {nb}={cb}")
        elif sa:
            rep.ok(f"sig changed-flags agree over {len(sa)} probes")
        for i, (x, y) in enumerate(zip(sa, sb)):
            if abs(x["mean"] - y["mean"]) > args.tol_sig_abs or abs(x["sd"] - y["sd"]) > args.tol_sig_abs:
                rep.warn(f"sig[{i}] {x.get('sig_label', '')}: absolute mean/sd differ beyond {args.tol_sig_abs}")

    hard = rep.hard + (rep.soft if args.strict_soft else 0)
    verdict = "PARITY" if hard == 0 else "DIVERGENCE"
    print(f"goldtrace-compare: {verdict} — {rep.hard} hard failure(s), {rep.soft} warning(s)")
    return 0 if hard == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

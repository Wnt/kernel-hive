#!/usr/bin/env python3
"""fleet_rollout_policy.py — the pure half of scripts/dev/fleet_rollout.py.

Everything here is a function of plain data (registry entries, box-state
snapshots, capture rows): no ssh, no subprocess that touches the box, no
sleep that is not injected by the caller. scripts/test_fleet_rollout.py pins
all of it down before any of it is allowed near a machine.

This file exists only because fleet_rollout.py sits at a 600-line hard cap
(scripts/check-file-size.mjs --strict) with no room left for policy — the
same ceiling that already keeps build-deploy.sh from absorbing this file's
job. Splitting along the pure/impure line the file already documented keeps
that line real instead of aspirational.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
REGISTRY = REPO / "registry" / "stations"

# build-deploy.sh's own choice of the station a mistake is cheapest on.
# Honoured here (as order_stations()'s default) so both tools agree on which
# exhibit is the canary without fleet_rollout.py needing a second definition.
SAFE_TILE = os.environ.get("SAFE_TILE", "helenos")

# A `ui: text-console` station only has to prove its frame is not BLANK.
CONSOLE_FLOOR = 0.05

# How much of a station's OWN pre-restart brightness its post-restart frame
# must retain. See effective_floor() for the reasoning.
RELATIVE_FLOOR_RATIO = 0.5


def load_registry(path=REGISTRY):
    """id -> registry entry, for every enabled streamhost station."""
    entries = {}
    for f in sorted(Path(path).glob("*.json")):
        entry = json.loads(f.read_text())
        if not entry.get("enabled", True):
            continue
        if (entry.get("stream") or {}).get("transport") != "streamhost":
            continue
        entries[entry["id"]] = entry
    return entries


def risk_score(entry):
    """How expensive it is to break this station. Lower rolls first.

    Every term is read from the registry the fleet already maintains; none of it
    is a new hand-kept list that would rot. The argument for each:

      reset mode      how the exhibit comes back. `loadvm` restores a golden in
                      seconds; `relaunch` cold-starts the emulator; `restart`
                      walks a full boot (aix432's firmware POST alone is 15-25
                      minutes). Recoverability is the whole point of going first.
      bespoke binary  a station running a forked emulator out of /opt has a
                      binary + golden + device set that are ONE combination
                      (rule 6). Those are the hardest things on the box to put
                      back, so they go last.
      retronet        a second network plane to re-establish on restart.
      desktop UI      the flagship exhibits a visitor comes for, as against a
                      home computer or a text console.
      bespoke pointer a closed-loop or warp pointer backend is per-station work
                      that a bad binary can silently break.
    """
    runtime = (entry.get("runtime") or {}).get("qemu") or {}
    score = {"loadvm": 0, "relaunch": 2, "restart": 4}.get((entry.get("reset") or {}).get("resetMode"), 4)
    source = ((entry.get("emulator") or {}).get("source") or "").lower()
    if str(runtime.get("binary") or "").startswith("/opt/") or "fork" in source or "github.com/wnt" in source:
        score += 3
    if entry.get("retronet"):
        score += 2
    if entry.get("ui") == "desktop":
        score += 2
    backend = ((entry.get("stream") or {}).get("pointer") or {}).get("backend") or ""
    if backend not in ("", "dbus", "qmp", "none", "warpd"):
        score += 1
    return score


def order_stations(entries, safe_tile=SAFE_TILE):
    """Cheapest-mistake-first order. Deterministic: score, then name."""
    return sorted(entries, key=lambda i: (-1, "") if i == safe_tile else (risk_score(entries[i]), i))


def claim_token_match(station, claim, udp_port=None):
    """Does this claim plausibly cover this station?

    Deliberately generous, because the two errors are not symmetric: skipping a
    station nobody was working on costs one deferred restart, while restarting a
    station somebody parked costs their work. A claim matches when it is the
    station's own UDP slot, or when the station id appears as a whole token in
    the claim's name, session or purpose.

    Walk-in clone identities are the one thing masked out first. A pool clone is
    `walkin-<os>-<n>` (docs/lab/walkin/CONTRACT-LEDGER.md 5.1) and is an
    EPHEMERAL DAEMON IDENTITY, not the registry station whose name it borrows —
    the pool holding `walkin-os2warp-1` says nothing about os2warp. Without this
    mask the six live walk-in port claims skipped os2warp and win311 from every
    rollout, which is a station parked by a name collision and nothing else.
    """
    if claim.get("class") == "port" and udp_port and str(claim.get("name")) == str(udp_port):
        return True
    haystack = " ".join(str(claim.get(k) or "") for k in ("name", "session", "purpose")).lower()
    haystack = re.sub(r"walkin-[a-z0-9]+-\d+", " ", haystack)
    return re.search(rf"(?<![a-z0-9]){re.escape(station)}(?![a-z0-9])", haystack) is not None


def claim_owner(station, entry, claims):
    """The session holding this station, or None. Only live/held claims count —
    a stale or dead claim is the registry's own record that nobody is there."""
    udp_port = (entry.get("stream") or {}).get("udpPort")
    for claim in claims:
        if claim.get("state") not in ("held", "live"):
            continue
        if claim_token_match(station, claim, udp_port):
            return claim.get("session") or "?"
    return None


def classify(entries, order, tiles_state, claims, excludes=(), only=(), skip_paused=False, skip_busy=True):
    """Split the ordered station list into (targets, [(station, reason)])."""
    targets, skipped = [], []
    for station in order:
        entry = entries[station]
        state = tiles_state.get(station) or {}
        if only and station not in only:
            skipped.append((station, "not in --only"))
        elif station in excludes:
            skipped.append((station, "--exclude"))
        elif state.get("unit_active") != "active":
            unit = state.get("unit_active") or "absent"
            skipped.append((station, f"unit is {unit}, not active (parked on purpose)"))
        else:
            owner = claim_owner(station, entry, claims)
            if owner:
                skipped.append((station, f"kh-claim held by session '{owner}'"))
            elif skip_busy and state.get("busy"):
                skipped.append((station, "a visitor is connected (--include-busy to restart anyway)"))
            elif skip_paused and state.get("paused"):
                skipped.append((station, "guest paused (--skip-paused was given)"))
            else:
                targets.append(station)
    return targets, skipped


def make_waves(stations, wave_size, canary_first=True):
    """Split into waves. Wave 1 is ONE station when canary_first is set.

    A full first wave of four means a bad binary takes four exhibits down before
    anything notices. One station first is the same discipline build-deploy.sh
    already applies with --canary, and it costs one extra settle interval.
    """
    if wave_size < 1:
        raise ValueError("wave size must be >= 1")
    stations = list(stations)
    head = []
    if canary_first and len(stations) > 1:
        head, stations = [stations[:1]], stations[1:]
    return head + [list(stations[i : i + wave_size]) for i in range(0, len(stations), wave_size)]


def min_nonblack_for(entry, default):
    """The non-black floor THIS station's screen can honestly clear: a healthy
    console is white text on black, ~0.4% at 1920x1200, and halted the first
    rollout. FLEET-ROLLOUT.md, "the frame gate's floor"."""
    return min(default, CONSOLE_FLOOR) if entry.get("ui") == "text-console" else default


def relative_floor(before_row):
    """The floor implied by a station's OWN frame, captured just before its
    wave restarted it — or None if that frame is not trustworthy enough to be
    a baseline (capture failed, or it read as flat 0% itself, which is nothing
    to be relative to and is itself indistinguishable from a bad capture).
    """
    if not before_row or not before_row.get("ok"):
        return None
    before_pct = before_row.get("nonblack_pct") or 0.0
    if before_pct <= 0:
        return None
    return before_pct * RELATIVE_FLOOR_RATIO


def effective_floor(entry, before_row, default):
    """The floor a station's AFTER frame is actually held to.

    A healthy screen's brightness is a property of the STATION, not its `ui`
    class: mpf2 (`home-computer`, same class as c64 at 61.8% and zxspectrum at
    ~99%) halted a rollout at 0.286% non-black, proving no ui class predicts
    brightness the way alpine (`text-console`) proved one flat percentage
    could not. The honest question a health gate can ask is not "how bright is
    a healthy frame" but "did THIS station come back to what IT was" — so the
    primary floor is HALF of the station's own frame from just before its wave
    restarted it (RELATIVE_FLOOR_RATIO). Half is loose enough that ordinary
    frame-to-frame noise (a blinking cursor, one more line of boot text, a
    trainer board's changing digit) never trips it, and tight enough that a
    guest coming back fully black (0%) or producing no frame at all still
    fails outright — 0 < half of anything positive.

    Both the class floor and the relative floor only ever LOWER what the
    operator passed as --min-nonblack, never raise it — the same contract
    min_nonblack_for() already had, extended so a bright desktop's relative
    floor cannot demand more than the operator explicitly asked for. When no
    usable before-frame exists (the pre-restart capture failed, or this is a
    --resume run inheriting a wave whose before-capture predates this check)
    the gate falls back to the class floor alone: a missing before-frame must
    never make a station un-gateable, only less precisely gated.
    """
    floor = min_nonblack_for(entry, default)
    rel = relative_floor(before_row)
    if rel is not None:
        floor = min(floor, rel)
    return floor


def promotable(wave, canary_tile):
    """The stations in this wave whose pointer `build-deploy.sh --promote` can move.

    THE CANARY TILE IS NOT PROMOTABLE, AND THAT IS THE CONTRACT, NOT A BUG.
    `--promote` walks *the rest of* the fleet onto the gated artifact and dies
    on a wave holding nothing else — and wave 1 IS the canary. That wave still
    earns its settle and its frame gate (rule 9); it needs no pointer move.
    """
    return [s for s in wave if s != canary_tile]


def pending_after_resume(waves, done):
    """The waves still to run, with already-done stations dropped from each."""
    finished = set(done)
    out = []
    for wave in waves:
        rest = [s for s in wave if s not in finished]
        if rest:
            out.append(rest)
    return out

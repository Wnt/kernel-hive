"""Station-facts checks: hand-written prose vs the structured facts beside it.

The recurring debt this closes: a registry field or a comment block asserts
something about a guest that the guest (or the structured field two lines
below it) contradicts. Five independent cases surfaced in one night on
2026-08-23/24 -- an OS build number, a "does not work" that does, a DHCP
option blamed for a guest that has no DHCP client, an aspirational browser,
and three stations whose prose said *static* while their own docs and guests
said *DHCP*. Every one was caught by a human tripping over it.

The rules here are deliberately few. Each one compares two things that are
BOTH already in the repo, so the always-on gate needs no live box (a public
clone and CI stay green), and each fires only on a positive contradiction --
never on silence. A check that cries wolf gets disabled by the next agent and
the debt comes straight back, so breadth is not the goal: these are the
claims that were actually observed to rot.

Deliberately NOT checked, and why, so a later session does not "helpfully"
add them:

  * Prelude GEOMETRY vs runtime.x11.geometry. The two legitimately differ --
    cbm8032's prelude says 1600x1200 (the emulated CRT) against an X screen
    of 1408x1088 -- and most stations declare no structured geometry at all,
    so the rule would be noise on the majority and wrong on the rest.
  * Prelude/note NIC MODEL vs the launcher's -device. Correct prose routinely
    names the adapter that does NOT work, as a warning: rhapsody's note says
    "NOT the i82557b ... transmits and never receives". A token match flags
    exactly the notes most worth keeping.
  * Repo-path existence for anything but docs/*.md. Registry prose is full of
    BOX-side runtime paths (streamhost/stations/<id>/signaling.json, fb.sh)
    that correctly do not exist in the repo -- 93 false hits when tried.
"""

from __future__ import annotations

import json
import re
from typing import Any

from .constants import REPO
from .validate_schema import fail

# How far from a mention of the station's own retronet address an addressing
# word still counts as describing it. Wide enough for the real notes (the
# tru64 case put "static" six characters ahead of the address), short enough
# that a later sentence about something else cannot reach.
ADDRESSING_WINDOW = 160

ADDRESSING_TOKENS = {
    "static": re.compile(r"\bstatic(?:ally)?\b", re.I),
    "dhcp": re.compile(r"\bdhcp\b", re.I),
}

# A negated mention is prose EXPLAINING the choice, not contradicting it:
# "STATIC, not DHCP, because MacTCP has no DHCP client at all" is exactly
# right and must stay silent. The negator has to sit in the same clause --
# only spaces, word characters and hyphens may separate it from the token, so
# any punctuation (a clause break) ends the reach. That is what keeps
# solaris's "(NOT slirp); guest is static ..." a real hit: the ");" between
# them means the "NOT" is about slirp, not about the addressing.
ADDRESSING_NEGATED = re.compile(r"(?:\b(?:not|no|never|without)\b|\bpre-)[ \t\w-]{0,20}$", re.I)

# Paths under docs/ are always repo files (see the module docstring for why
# the check stops there). The lookbehind keeps a longer prefix intact, so
# "streamhost/docs/BRIDGE.md" is tested whole rather than as "docs/BRIDGE.md".
DOC_PATH = re.compile(r"(?<![A-Za-z0-9._/-])((?:[A-Za-z0-9._-]+/)*docs/[A-Za-z0-9._/-]*[A-Za-z0-9_-]\.md)")

# Prose that announces a station is off the public floor. The registry says
# the same thing structurally in `listing`, and the two drifted apart in
# silence: rhapsody was listed: true in the served fleet table for days while
# its own prelude still called it a dark launch, and four more stations
# (hpuxvue, newsos, sunos414, tru64) carried the same stale banner.
HIDDEN_CLAIM = re.compile(r"(?i)\bdark.?launch\b|\blisting\s*[=:]\s*hidden\b|\bunlisted\b")


def _prose(row: dict[str, Any]) -> str:
    """Every hand-written string in the entry, as one searchable blob.

    Facts rot wherever prose lives, not only in the field a reviewer expects:
    the static-vs-DHCP contradiction sat in `network.note` on tru64 but in
    `operator.labctl.notes`, `render.stationsManifestPrelude` and a
    `build.rows` value on solaris. Searching the whole entry means a check
    does not have to guess which field the next author will use.
    """
    return json.dumps({k: v for k, v in row.items() if not str(k).startswith("_")}, ensure_ascii=False)


def validate_addressing_prose(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Prose calling the guest static/DHCP must agree with `retronet.addressing`.

    `retronet.addressing` is the structured fact; the notes are prose. When
    they disagree the prose is what a session reads, believes and acts on, so
    the disagreement has to be loud. Only a mention within
    ADDRESSING_WINDOW of the station's OWN retronet address counts -- that is
    what makes this safe against the history the notes legitimately carry
    ("Pre-DHCP backup", "Rehomed from the pre-retronet path"), none of which
    quotes the address.
    """
    for row in rows:
        block = row.get("retronet") or {}
        mode, address = block.get("addressing"), block.get("address")
        if mode not in ADDRESSING_TOKENS or not address:
            continue
        opposite = "dhcp" if mode == "static" else "static"
        prose = _prose(row)
        for hit in re.finditer(re.escape(address) + r"(?![0-9])", prose):
            window = prose[max(0, hit.start() - ADDRESSING_WINDOW) : hit.end() + ADDRESSING_WINDOW]
            for token in ADDRESSING_TOKENS[opposite].finditer(window):
                if ADDRESSING_NEGATED.search(window[: token.start()]):
                    continue
                quote = " ".join(window[max(0, token.start() - 60) : token.end() + 60].split())
                fail(
                    errors,
                    row,
                    f"prose calls {address} {token.group(0)!r} but retronet.addressing says {mode!r} "
                    f"— ...{quote}... . One of the two is stale: ask the guest "
                    f"(`ssh lab 'labctl exec {row['id']} \"<show the interface>\"'`), then correct "
                    "whichever is wrong. Rewrite the sentence to the true thing — never append a "
                    "correction beside it (AGENTS.md: docs are living, not diaries). Prose that "
                    "explains the choice ('STATIC, not DHCP, because ...') is fine and stays silent here.",
                )


def validate_prelude_listing(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """A dark-launch banner in the prelude must match `listing.state`.

    `listing` absent MEANS listed, so a station reaches the public floor
    without anything editing the comment block that still calls it a dark
    launch. Nothing cross-checked the two, and the failure is visitor-facing:
    an exhibit that every note calls hidden while anyone can walk up and open
    it, so the next session reasons about a floor it is not standing on.
    """
    for row in rows:
        prelude = (row.get("render") or {}).get("stationsManifestPrelude")
        if not prelude:
            continue
        claim = HIDDEN_CLAIM.search(prelude)
        state = row.get("listing", {}).get("state", "listed")
        # Only the positive contradiction is a failure. A hidden station whose
        # prelude simply does not mention it is SILENT, not wrong, and demanding
        # a banner there would put boilerplate on every hide/unhide -- the kind
        # of nagging rule that gets deleted, taking the real check with it.
        if claim and state != "hidden":
            fail(
                errors,
                row,
                f"render.stationsManifestPrelude still announces {claim.group(0)!r} but the entry is "
                f"{state.upper()} (listing.state absent MEANS listed) — the exhibit is on the public "
                "floor. Rewrite the prelude to describe the station as it is now; if it really should "
                'be off the floor, set listing {state: "hidden", reason, since} instead.',
            )


def _declared_links(link: str) -> list[str]:
    """Interface names a `retronet.link` string names: 'tap x on B', 'veth a/b (pcap) on B'."""
    names: list[str] = []
    for match in re.finditer(r"\b(?:tap|veth)\s+([A-Za-z0-9_./-]+)", link):
        names.extend(part for part in match.group(1).split("/") if part)
    return names


def validate_retronet_link(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """`retronet.link`/`guard` must name what the station's own rn-tapnet.sh creates.

    The block is the ledger every other session reads to answer "which
    interface is this station on"; the helper is what actually brings the
    interface up. A rename that lands in one and not the other sends the next
    debugger to an interface that does not exist -- with the station running
    fine on another.
    """
    for row in rows:
        block = row.get("retronet") or {}
        if not block:
            continue
        os_id = row["id"]
        rel = f"streamhost/stations/{os_id}/rn-tapnet.sh"
        helper = REPO / rel
        if not helper.exists():
            continue
        text = helper.read_text(encoding="utf-8")
        for name in _declared_links(block.get("link", "")):
            if not re.search(rf"\b{re.escape(name)}\b", text):
                fail(
                    errors,
                    row,
                    f"retronet.link names the interface {name!r} but {rel} never mentions it — the "
                    "ledger and the script that actually creates the link disagree. Fix whichever "
                    "was renamed; `ssh lab 'ip link show'` says which one the box really has.",
                )
        guard = block.get("guard")
        if guard and not re.search(rf"\b{re.escape(guard)}\b", text):
            fail(
                errors,
                row,
                f"retronet.guard names the chain {guard!r} but {rel} never mentions it — the "
                "fail-closed chain the ledger promises is not the one the helper installs. "
                "`ssh lab 'iptables -S'` says which chain is really there.",
            )


def validate_doc_paths(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Every docs/*.md path the entry cites must still exist.

    A moved doc leaves the pointer behind, and the pointer is prose: nothing
    resolves it until a session follows it and finds nothing.
    """
    for row in rows:
        for path in sorted(set(DOC_PATH.findall(_prose(row)))):
            if not (REPO / path).exists():
                fail(
                    errors,
                    row,
                    f"cites the document {path}, which does not exist — it was moved, renamed or "
                    "never written. Point the entry at where the document lives now (`git log "
                    f"--diff-filter=D -- {path}` finds the move), or drop the reference.",
                )


def validate_facts(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """Run every station-facts rule (called from validate_rules.validate())."""
    validate_addressing_prose(rows, errors)
    validate_prelude_listing(rows, errors)
    validate_retronet_link(rows, errors)
    validate_doc_paths(rows, errors)

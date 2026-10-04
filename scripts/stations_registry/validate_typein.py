"""Typing INTO a guest from the SPA: the demo listing's pacing, the type-in
editor's opt-in (registry `typeIn`), and the editor's example programs and
manual links (registry/examples/<id>/).

Both typists (spa/src/ui/grid/StreamView/typeDemoProgram.ts) send ONE character
per typeText() call and then wait the station's per-character budget. The daemon
drains typed keys at SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS per character, so a
budget below that builds a backlog and BASIC loses characters -- seen as the
first digit of a line number going missing partway down a listing. The two
numbers live in different files (the registry and the station's env fixture),
so they are pinned together here rather than rediscovered on the exhibit floor.

The editor is stricter than the demo: a demo may fall back to the SPA default,
an editor station must DECLARE its budget, and a station whose drain rate is not
declared at all cannot be validated and so gets no editor.
"""

from __future__ import annotations

import json
import re
from collections import OrderedDict
from typing import Any

from .constants import REGISTRY
from .keyword_keys import KEYWORD_DIALECTS, keyword_tables
from .validate_schema import fail

EXAMPLES = REGISTRY / "examples"

# spa/src/ui/grid/StreamView/typeDemoProgram.ts DEMO_PER_CHAR_MS -- what the UI
# typist assumes when a demoProgram declares no perCharMs of its own.
SPA_DEFAULT_PER_CHAR_MS = 70
# ... and DEMO_ENTER_DELAY_MS, the settle after ENTER when typeIn declares none.
SPA_DEFAULT_ENTER_DELAY_MS = 600

TYPEIN_KEYS = {
    "dialect",
    "perCharMs",
    "lineDelayMs",
    "enterDelayMs",
    "enterDelayPerLineMs",
    "case",
    "maxLineChars",
    "hint",
    "settleAfter",
    "unreachable",
}
# Upper bounds the JSON-Schema-lite evaluator cannot express (it has no
# `maximum`). Generous on purpose: they catch a unit slip (seconds typed as ms
# times a thousand), not a tuning choice.
TYPEIN_MAXIMA = {
    "perCharMs": 2000,
    "lineDelayMs": 10000,
    "enterDelayMs": 60000,
    "enterDelayPerLineMs": 5000,
    "maxLineChars": 255,
}
HINT_MAX = 160

EXAMPLE_KINDS = ("draw", "input", "game", "sound", "other")
EXAMPLE_KEYS = {"file", "kind", "title", "description"}
MANUAL_KEYS = {"title", "url", "lang", "note"}
EXAMPLE_FILE = re.compile(r"[a-z0-9][a-z0-9_-]*\.(bas|txt)")
PRINTABLE = re.compile(r"[\x20-\x7e]*")
# The direct command that wipes a BASIC program -- NEW in every editor dialect
# (spa/src/ui/typein/basicDialects.ts `clearCommand`).
CLEAR_COMMAND = "NEW"


def drain_ms(row: dict[str, Any]) -> int:
    """The per-character drain rate, or 0 when the station declares none.

    HOLD + GAP per key. A station with a modifier lead (SH_KEY_MOD_LEAD_MS: the
    emulator's key module holds a press until the Shift level in front of it
    has been visible that long) pays it on a shifted character, and again on
    the key after one, so its worst character costs HOLD + max(GAP, LEAD) +
    LEAD.
    """
    env = (row.get("runtime") or {}).get("stationEnv", {})
    try:
        hold = int(env.get("SH_KEY_MIN_HOLD_MS", 0))
        gap = int(env.get("SH_KEY_MIN_GAP_MS", 0))
        lead = int(env.get("SH_KEY_MOD_LEAD_MS", 0))
    except (TypeError, ValueError):
        return 0
    if hold + gap == 0:
        return 0
    return hold + max(gap, lead) + lead


def validate_demo_pacing(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """A demoProgram's per-character budget must not undercut the daemon's pacing."""
    for row in rows:
        demo = row.get("demoProgram")
        if not demo:
            continue
        drain = drain_ms(row)
        if drain == 0:
            continue
        budget = demo.get("perCharMs", SPA_DEFAULT_PER_CHAR_MS)
        if budget < drain:
            fail(
                errors,
                row,
                f"demoProgram.perCharMs={budget} is below the tile's typed drain rate "
                f"({drain} ms/char = SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS, plus the modifier lead); the typist "
                f"would out-run the guest and lose characters",
            )


def validate_type_in(rows: list[dict[str, Any]], errors: list[str]) -> None:
    """The editor opt-in: declared, validated pacing on a streamed station.

    The schema already checks the field types and the dialect/case vocabularies;
    this adds what it cannot say: no unknown keys, the upper bounds, and the one
    rule that matters -- the editor may never type faster than the daemon drains.
    """
    for row in rows:
        block = row.get("typeIn")
        if block is None:
            continue
        if not isinstance(block, dict):
            fail(errors, row, "typeIn must be an object")
            continue
        unknown = sorted(set(block) - TYPEIN_KEYS)
        if unknown:
            fail(errors, row, f"typeIn has unknown key(s) {unknown}; allowed: {sorted(TYPEIN_KEYS)}")
        for key, ceiling in TYPEIN_MAXIMA.items():
            value = block.get(key)
            if isinstance(value, int) and value > ceiling:
                fail(errors, row, f"typeIn.{key}={value} is above {ceiling} -- a unit slip?")
        hint = block.get("hint")
        if isinstance(hint, str) and (len(hint) > HINT_MAX or "\n" in hint):
            fail(errors, row, f"typeIn.hint must be one line of at most {HINT_MAX} characters")
        _check_settle_and_reach(row, block, errors)
        if row.get("stream", {}).get("transport") != "streamhost":
            fail(errors, row, "typeIn on a station that does not stream -- there is no guest to type into")
        drain = drain_ms(row)
        if drain == 0:
            fail(
                errors,
                row,
                "typeIn needs a declared drain rate (SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS in the "
                "station env): without it the editor's pace cannot be validated, so the station gets no editor",
            )
            continue
        budget = block.get("perCharMs")
        if isinstance(budget, int) and budget < drain:
            fail(
                errors,
                row,
                f"typeIn.perCharMs={budget} is below the tile's typed drain rate ({drain} ms/char = "
                f"SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS, plus the modifier lead); the editor would out-run the guest",
            )
        if block.get("dialect") in KEYWORD_DIALECTS:
            validate_chord_pacing(row, block, drain, errors)
    keyword_tables(rows, errors)


def validate_chord_pacing(row: dict[str, Any], block: dict[str, Any], drain: int, errors: list[str]) -> None:
    """A keyword-entry station is typed in CHORDS (modifiers + one key, or a
    modifiers-only E/FUNCTION prefix). The key module applies a chord's
    modifiers with its key and releases them with it, so one chord drains in
    the same budget as one character (drain_ms). Every wait that precedes a
    chord must cover it, the ENTER settle included (settleAfter only ever
    lengthens it), or the next chord's edges queue behind a chord still in
    flight.
    """
    enter = block.get("enterDelayMs", SPA_DEFAULT_ENTER_DELAY_MS)
    if isinstance(enter, int) and enter < drain:
        fail(
            errors,
            row,
            f"typeIn.enterDelayMs={enter} is below one chord ({drain} ms = SH_KEY_MIN_HOLD_MS + "
            f"SH_KEY_MIN_GAP_MS, plus the modifier lead); the next line's first chord would land on the ENTER "
            f"still in flight",
        )
    if "case" in block:
        fail(errors, row, "typeIn.case on a keyword-entry dialect: the keyword transcoder owns letter case")


def _check_settle_and_reach(row: dict[str, Any], block: dict[str, Any], errors: list[str]) -> None:
    """`settleAfter` (extra ENTER settle after a named direct command) and
    `unreachable` (ASCII the station's keymap cannot produce)."""
    settle = block.get("settleAfter")
    if settle is not None:
        if not isinstance(settle, dict) or not settle:
            fail(errors, row, "typeIn.settleAfter must be a non-empty object of command -> ms")
        else:
            for command, ms in settle.items():
                if not (isinstance(command, str) and 0 < len(command) <= 40 and PRINTABLE.fullmatch(command)):
                    fail(errors, row, f"typeIn.settleAfter key {command!r} must be a short printable-ASCII line")
                if command != command.strip().upper():
                    fail(errors, row, f"typeIn.settleAfter key {command!r} must be trimmed upper case (matching is)")
                if not isinstance(ms, int) or isinstance(ms, bool) or not 0 <= ms <= 60000:
                    fail(errors, row, f"typeIn.settleAfter[{command!r}]={ms!r} must be an integer 0..60000 ms")
    reach = block.get("unreachable")
    if reach is not None:
        if not isinstance(reach, str) or not reach or not PRINTABLE.fullmatch(reach):
            fail(errors, row, "typeIn.unreachable must be a non-empty string of printable ASCII")
        elif len(set(reach)) != len(reach) or re.search(r"[A-Za-z0-9 ]", reach):
            fail(errors, row, "typeIn.unreachable lists each symbol once, and never a letter, digit or space")


def _example_errors(os_id: str, folder: Any, block: dict[str, Any], doc: Any) -> tuple[list[str], dict | None]:
    """Validate one registry/examples/<id>/ folder; return (errors, rendered entry)."""
    where = f"registry/examples/{os_id}"
    problems: list[str] = []
    if not isinstance(doc, dict):
        return [f"{where}/index.json must be an object"], None
    unknown = sorted(set(doc) - {"examples", "manuals"})
    if unknown:
        problems.append(f"{where}/index.json has unknown key(s) {unknown}; allowed: ['examples', 'manuals']")
    examples, manuals = doc.get("examples", []), doc.get("manuals", [])
    if not isinstance(examples, list) or not isinstance(manuals, list):
        return problems + [f"{where}/index.json: examples and manuals must be arrays"], None

    max_chars = block.get("maxLineChars")
    seen: set[str] = set()
    rendered_examples = []
    for index, item in enumerate(examples):
        at = f"{where}/index.json examples[{index}]"
        if not isinstance(item, dict):
            problems.append(f"{at} must be an object")
            continue
        extra = sorted(set(item) - EXAMPLE_KEYS)
        if extra:
            problems.append(f"{at} has unknown key(s) {extra}; allowed: {sorted(EXAMPLE_KEYS)}")
        name, kind, title = item.get("file"), item.get("kind"), item.get("title")
        if kind not in EXAMPLE_KINDS:
            problems.append(f"{at}.kind {kind!r} is not one of {list(EXAMPLE_KINDS)}")
        if not isinstance(title, str) or not title.strip():
            problems.append(f"{at}.title must be a non-blank string")
        description = item.get("description", "")
        if not isinstance(description, str):
            problems.append(f"{at}.description must be a string")
        if not isinstance(name, str) or not EXAMPLE_FILE.fullmatch(name):
            problems.append(f"{at}.file {name!r} must be a lower-case .bas or .txt file name")
            continue
        if name in seen:
            problems.append(f"{at}.file {name!r} is listed twice")
        seen.add(name)
        path = folder / name
        if not path.is_file():
            problems.append(f"{at}.file {name!r} does not exist in {where}/")
            continue
        raw = path.read_bytes()
        try:
            text = raw.decode("ascii")
        except UnicodeDecodeError:
            problems.append(f"{where}/{name}: not ASCII -- the typist can only key printable ASCII")
            continue
        lines = text[:-1].split("\n") if text.endswith("\n") else text.split("\n")
        if not any(line.strip() for line in lines):
            problems.append(f"{where}/{name}: empty program")
        elif lines[0].strip().upper() == CLEAR_COMMAND:
            problems.append(
                f"{where}/{name}:1: starts with NEW -- drop it: the editor types NEW before every run "
                "(its 'clear the old program first' option), so a listing carries only its own lines"
            )
        for number, line in enumerate(lines, start=1):
            if not PRINTABLE.fullmatch(line):
                problems.append(f"{where}/{name}:{number}: only printable ASCII and LF line ends (no tabs, no CR)")
            elif line != line.rstrip(" "):
                problems.append(f"{where}/{name}:{number}: trailing spaces")
            elif set(line) & set(block.get("unreachable", "")):
                bad = "".join(sorted(set(line) & set(block["unreachable"])))
                problems.append(f"{where}/{name}:{number}: {bad!r} has no key on this machine (typeIn.unreachable)")
            elif isinstance(max_chars, int) and len(line) > max_chars:
                problems.append(
                    f"{where}/{name}:{number}: {len(line)} characters, over this machine's "
                    f"{max_chars}-character line (typeIn.maxLineChars) -- the screen editor would cut it"
                )
        entry = OrderedDict((("file", name), ("kind", kind), ("title", title)))
        if description:
            entry["description"] = description
        entry["text"] = "\n".join(lines)
        rendered_examples.append(entry)

    for stray in sorted(p.name for p in folder.iterdir() if p.is_file() and p.suffix in (".bas", ".txt")):
        if stray not in seen:
            problems.append(f"{where}/{stray}: not listed in index.json (a typo, or a program nobody can open)")

    rendered_manuals = []
    for index, item in enumerate(manuals):
        at = f"{where}/index.json manuals[{index}]"
        if not isinstance(item, dict):
            problems.append(f"{at} must be an object")
            continue
        extra = sorted(set(item) - MANUAL_KEYS)
        if extra:
            problems.append(f"{at} has unknown key(s) {extra}; allowed: {sorted(MANUAL_KEYS)}")
        if not isinstance(item.get("title"), str) or not item["title"].strip():
            problems.append(f"{at}.title must be a non-blank string")
        url = item.get("url")
        if not isinstance(url, str) or not re.fullmatch(r"https://[^\s\"<>]+", url):
            problems.append(f"{at}.url {url!r} must be an https:// URL")
        if "lang" in item and not (isinstance(item["lang"], str) and re.fullmatch(r"[a-z]{2}", item["lang"])):
            problems.append(f"{at}.lang {item.get('lang')!r} must be a two-letter language code")
        if "note" in item and not isinstance(item["note"], str):
            problems.append(f"{at}.note must be a string")
        rendered_manuals.append(OrderedDict((k, item[k]) for k in ("title", "url", "lang", "note") if k in item))

    return problems, OrderedDict((("examples", rendered_examples), ("manuals", rendered_manuals)))


def load_type_in_docs(rows: list[dict[str, Any]], errors: list[str]) -> OrderedDict[str, Any]:
    """Validate registry/examples/ and return what poster-docs.json carries per station.

    A station with no folder simply has no examples: absence is never an error.
    A folder for a station WITHOUT a typeIn block is one -- its programs could
    never be opened, and a wrong id is the likelier explanation.
    """
    out: OrderedDict[str, Any] = OrderedDict()
    if not EXAMPLES.is_dir():
        return out
    by_id = {row["id"]: row for row in rows}
    for folder in sorted(p for p in EXAMPLES.iterdir() if p.is_dir()):
        os_id = folder.name
        row = by_id.get(os_id)
        if row is None or not isinstance(row.get("typeIn"), dict):
            errors.append(
                f"registry/examples/{os_id}/: {'no such station' if row is None else 'station has no typeIn block'}"
                " -- examples are only offered on editor stations (registry `typeIn`)"
            )
            continue
        index = folder / "index.json"
        if not index.is_file():
            errors.append(f"registry/examples/{os_id}/: missing index.json")
            continue
        try:
            doc = json.loads(index.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"registry/examples/{os_id}/index.json: {exc}")
            continue
        problems, entry = _example_errors(os_id, folder, row["typeIn"], doc)
        errors.extend(problems)
        if entry is not None and not problems:
            out[os_id] = entry
    return out

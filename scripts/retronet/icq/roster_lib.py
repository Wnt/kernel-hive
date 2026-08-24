#!/usr/bin/env python3
"""roster_lib — read scripts/retronet/icq/roster.json, the retronet ICQ fabric's
single source of truth.

Two consumers, so this is a module and not a function inside either of them:

* `seed_contacts.py` — who carries whom in a contact list.
* `scripts/retronet/bot/install-bot.sh` — which personas the greeter watches, via
  `roster_lib.py personas`. The bot runs in a DynamicUser cage with no git
  checkout of its own, so the list is RENDERED into /etc/retronet/bot.env at
  install time rather than read at runtime. See docs/lab/retronet/BOT.md.

`onboarded` is the roster's word for "this station has a live client signed in",
and both consumers mean exactly that by it: a pending station belongs in nobody's
contact list and has nothing to greet.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROSTER = Path(__file__).resolve().parent / "roster.json"


def load_roster(path: str | Path = ROSTER) -> dict:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    seen: set[str] = set()
    for e in [data["bot"], *data["stations"]]:
        if e["uin"] in seen:
            raise ValueError(f"duplicate UIN in roster: {e['uin']}")
        seen.add(e["uin"])
    return data


def onboarded_stations(roster: dict) -> list[dict]:
    return [s for s in roster["stations"] if s.get("onboarded")]


def personas_value(roster: dict) -> str:
    """The greeter bot's RN_BOT_PERSONAS: `uin:station` for every onboarded row.

    Onboarding a station is ONE roster row and nothing else — this is what makes
    that true for the bot, so nobody hand-appends to /etc/retronet/bot.env.
    """
    return ",".join(f"{s['uin']}:{s['station']}" for s in onboarded_stations(roster))


def main(argv: list[str]) -> int:
    if len(argv) != 1 or argv[0] != "personas":
        print("usage: roster_lib.py personas", file=sys.stderr)
        return 2
    value = personas_value(load_roster())
    if not value:
        print("roster_lib: no onboarded stations in the roster", file=sys.stderr)
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

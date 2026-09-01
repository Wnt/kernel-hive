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


# Which greeter instance watches a station, and therefore which identity that
# station can talk BACK to. Default "icq" = HiveBot, UIN 10000. "aim" = the
# `hivebot` AIM screen name run by retronet-bot-aim.service, for clients that
# refuse an all-numeric screen name (win311's Netscape AIM 1.0.414 will not
# list, message, or even REPLY to a UIN — see ICQ-STATION-win311.md).
DEFAULT_GREETER = "icq"


def greeter_of(station: dict) -> str:
    return station.get("greeter", DEFAULT_GREETER)


def persona_id(station: dict) -> str:
    """The name a greeter must WATCH and address to reach this station's client.

    For an ICQ station that is its UIN. For an AIM station it is the screen name
    its client actually signs in as — `uin` there is the numeric identity
    retronet-aim-bridge holds on the station's behalf, which no greeter should
    talk to (it would be talking to the bridge, not the machine).
    """
    return station.get("aimScreenName", station["uin"]) if greeter_of(station) == "aim" else station["uin"]


def onboarded_stations(roster: dict, greeter: str | None = None) -> list[dict]:
    rows = [s for s in roster["stations"] if s.get("onboarded")]
    if greeter is not None:
        rows = [s for s in rows if greeter_of(s) == greeter]
    return rows


def personas_value(roster: dict, greeter: str = DEFAULT_GREETER) -> str:
    """One greeter instance's RN_BOT_PERSONAS: `uin:station` per onboarded row.

    Onboarding a station is ONE roster row and nothing else — this is what makes
    that true for the bot, so nobody hand-appends to /etc/retronet/bot.env.

    Scoped by `greeter` so the two instances partition the fleet rather than both
    greeting the same station: a win311 visitor greeted by UIN 10000 would get a
    message their client cannot answer.
    """
    return ",".join(f"{persona_id(s)}:{s['station']}" for s in onboarded_stations(roster, greeter))


def main(argv: list[str]) -> int:
    if not argv or argv[0] != "personas" or len(argv) > 2:
        print("usage: roster_lib.py personas [icq|aim]", file=sys.stderr)
        return 2
    greeter = argv[1] if len(argv) == 2 else DEFAULT_GREETER
    value = personas_value(load_roster(), greeter)
    if not value:
        print(f"roster_lib: no onboarded {greeter} stations in the roster", file=sys.stderr)
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""aim_bridge.py — let the AIM-only station talk to the ICQ fleet, for real.

THE PROBLEM, in one paragraph. win311 runs Netscape AOL Instant Messenger
1.0.414 — a real OSCAR client, but an AIM one. AIM validates screen names in
the client: a name must start with a letter, so an all-numeric one is refused
outright ("The screen name '10000' is not valid.") for the buddy list, for a
new message, and even for a REPLY. ICQ clients are the mirror image: ICQ 2001b
signs in with a numeric UIN and, tested on the live win98se, SILENTLY DISCARDS
an inbound message whose sender is not numeric. The two client families cannot
name each other. No server setting fixes this — Open OSCAR Server has no alias
or rename endpoint — so ONE account cannot be addressable by both families.

THE BRIDGE. Every station therefore gets a second identity, on the other side
of the naming rule, and this service holds it:

    win311 (AIM client, screen name `win311`)
        |  sees, and can address:  win98se, nt4, os2warp, ...   (letter-leading
        |                                                        ALIAS accounts)
        v
   [ aim_bridge ]
        |  speaks to the real stations as: 31100  (a numeric UIN whose ICQ
        |                                          directory nickname is
        v                                          "win311", so it renders as a
   win98se (ICQ 2001b, UIN 98980)                   name, not a number)

  win311 -> alias `win98se`  ==> bridge sends to UIN 98980 **as 31100**
  UIN 98980 -> 31100         ==> bridge sends to `win311` **as alias `win98se`**

Both directions therefore arrive from a sender the receiving client can render.
Proven on the live win98se before this file was written: a message from the
non-numeric `rnbridge` never appeared, and the identical message from numeric
`31100` opened a Message Session and resolved to the name `win311`.

PRESENCE IS REAL, not simulated. `win98se` appears online in win311's buddy
list exactly when the actual win98se station's ICQ client is signed on, because
the bridge signs that alias in and out to follow it. A permanently-online alias
would be a lie, and this fleet is routinely paused.

TWO watchers, always on and in nobody's contact list, observe presence. They
exist because presence has to be observed by SOMEBODY while the identity that
mirrors it is deliberately offline — a session cannot watch for its own cue to
exist. There are two rather than one because **presence does not cross the
AIM/ICQ divide on this server, even though messages do**: measured here, an
AIM-type account with an ICQ UIN in its buddy list is simply never told that
UIN came online, while the ICQ-type greeter watching the same UIN at the same
moment was. So the ICQ-side watcher (a numeric UIN) watches the stations, and
the AIM-side watcher (a screen name) watches the AIM station. Do not "simplify"
these into one account: it will silently see only half the fleet.

Accounts are owned by this service (install-aim-bridge.sh creates them and
writes their passwords into the 0600 config); they are not station credentials.

See docs/lab/retronet/ICQ-STATION-win311.md and BOT.md.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bot"))

import oscar  # noqa: E402 — the fleet's hand-rolled OSCAR client

LOG = logging.getLogger("retronet.aimbridge")

CONFIG = os.environ.get("RN_BRIDGE_CONFIG", "/etc/retronet/aim-bridge.json")
# How long a dropped session waits before signing back on. The gateway is on the
# same bridge, so a failure here is a real fault, not a slow network.
RECONNECT_SECS = float(os.environ.get("RN_BRIDGE_RECONNECT", "15"))


class Session:
    """One OSCAR identity the bridge holds, supervised in its own thread.

    `wanted` is the whole state machine: set it and the supervisor signs on or
    off to match. That keeps presence mirroring (which is edge-triggered, from
    the watcher's callbacks) away from socket lifetime (which needs retries).
    """

    def __init__(self, host: str, port: int, name: str, password: str, buddies: list[str]) -> None:
        self.host, self.port = host, port
        self.name, self.password, self.buddies = name, password, buddies
        self.on_message = None  # (sender, text) -> None
        self.on_presence = None  # (who, online: bool) -> None
        self.wanted = False
        self.client: oscar.OscarClient | None = None
        self._lock = threading.Lock()
        threading.Thread(target=self._supervise, name=f"sess-{name}", daemon=True).start()

    def set_wanted(self, wanted: bool) -> None:
        if self.wanted == wanted:
            return
        LOG.info("%s: %s", self.name, "signing on" if wanted else "signing off")
        self.wanted = wanted
        if not wanted:
            # Tearing the socket down here is not an optimisation: the supervisor
            # is parked inside run_forever() and only re-reads `wanted` when that
            # returns, so without this the stand-in stays SIGNED ON after its
            # station has gone away — the exact dishonest presence this service
            # exists to avoid. Observed: 31100 still listed online minutes after
            # "31100: signing off".
            self._teardown()

    def _supervise(self) -> None:
        while True:
            if not self.wanted:
                self._teardown()
                time.sleep(1.0)
                continue
            try:
                c = oscar.OscarClient(
                    self.host,
                    self.port,
                    self.name,
                    self.password,
                    buddies=self.buddies,
                    client_name="AOL Instant Messenger (SM), version 1.0.414/WIN16",
                )
                c.on_message = lambda s, t: self.on_message and self.on_message(s, t)
                c.on_buddy_online = lambda s: self.on_presence and self.on_presence(s, True)
                c.on_buddy_offline = lambda s: self.on_presence and self.on_presence(s, False)
                c.connect()
                with self._lock:
                    self.client = c
                LOG.info("%s: signed on", self.name)
                c.run_forever()
            except Exception as exc:  # a bad session must never kill the bridge
                LOG.warning("%s: session ended (%s)", self.name, exc)
            self._teardown()
            if self.wanted:
                time.sleep(RECONNECT_SECS)

    def _teardown(self) -> None:
        with self._lock:
            c, self.client = self.client, None
        if c is not None:
            try:
                c.close()
                c.reset()
            except Exception:
                pass

    def send(self, target: str, text: str) -> bool:
        with self._lock:
            c = self.client
        if c is None:
            LOG.warning("%s: cannot send to %s — not signed on", self.name, target)
            return False
        try:
            c.send_im(target, text)
            return True
        except Exception as exc:
            LOG.warning("%s: send to %s failed: %s", self.name, target, exc)
            return False


def main() -> int:
    logging.basicConfig(
        level=os.environ.get("RN_BRIDGE_LOGLEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    with open(CONFIG, encoding="utf-8") as fh:
        cfg = json.load(fh)
    host, port = cfg["server"].split(":")
    port = int(port)
    aim_name = cfg["aim_station"]  # the guest's own AIM screen name
    links = cfg["links"]  # [{station, alias, alias_password, uin}]
    by_uin = {l["uin"]: l for l in links}
    by_alias = {l["alias"]: l for l in links}

    LOG.info(
        "aim-bridge: %s <-> %d station(s) via proxy UIN %s",
        aim_name,
        len(links),
        cfg["proxy"]["uin"],
    )

    # --- the ICQ-side identity of the AIM station -----------------------------
    # Everything the fleet sends to win311 arrives here, and everything win311
    # sends to the fleet leaves from here, so it renders as a UIN on that side.
    proxy = Session(
        host,
        port,
        cfg["proxy"]["uin"],
        cfg["proxy"]["password"],
        buddies=[l["uin"] for l in links],
    )

    # --- one alias identity per station, as win311's client sees it -----------
    alias_sessions: dict[str, Session] = {}
    for l in links:
        alias_sessions[l["uin"]] = Session(host, port, l["alias"], l["alias_password"], buddies=[aim_name])

    def from_station(sender: str, text: str) -> None:
        """A real station messaged win311 (it addressed the proxy UIN)."""
        link = by_uin.get(sender)
        if link is None:
            LOG.info("proxy: message from unknown %s, ignored: %s", sender, text)
            return
        LOG.info("%s -> %s: %s", link["station"], aim_name, text)
        alias_sessions[link["uin"]].send(aim_name, text)

    proxy.on_message = from_station

    def make_from_aim(link):
        def handler(sender: str, text: str) -> None:
            """win311 messaged this station's alias — carry it to the real UIN."""
            if sender.lower() != aim_name.lower():
                LOG.info("%s: message from unexpected %s, ignored", link["alias"], sender)
                return
            LOG.info("%s -> %s (%s): %s", aim_name, link["station"], link["uin"], text)
            proxy.send(link["uin"], text)

        return handler

    for l in links:
        alias_sessions[l["uin"]].on_message = make_from_aim(l)

    # --- the watchers: the only always-on sessions ----------------------------
    # They translate "the real thing came online" into "sign its stand-in on".
    # One per presence domain — see the module docstring for why one will not do.
    def on_presence(who: str, online: bool) -> None:
        if who.lower() == aim_name.lower():
            # win311's own client signed on/off: the fleet should see its proxy
            # appear and disappear with it, not sit online while nobody is there.
            proxy.set_wanted(online)
            return
        link = by_uin.get(who)
        if link is not None:
            alias_sessions[link["uin"]].set_wanted(online)

    # ICQ-side: a numeric UIN, so the stations' presence is visible to it.
    watcher_icq = Session(
        host,
        port,
        cfg["watcher_icq"]["uin"],
        cfg["watcher_icq"]["password"],
        buddies=[l["uin"] for l in links],
    )
    watcher_icq.on_presence = on_presence
    watcher_icq.set_wanted(True)

    # AIM-side: a screen name, so the AIM station's presence is visible to it.
    watcher_aim = Session(
        host,
        port,
        cfg["watcher_aim"]["name"],
        cfg["watcher_aim"]["password"],
        buddies=[aim_name],
    )
    watcher_aim.on_presence = on_presence
    watcher_aim.set_wanted(True)

    LOG.info("aim-bridge: watching %s + %s", aim_name, ", ".join(sorted(by_alias)))
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    sys.exit(main())

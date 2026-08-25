"""The walk-in broker: a warm pool of private per-visitor clones.

A walk-in gets a machine of their own — wreck it, leave, the next visitor gets a
pristine one. That is the whole product, and everything here exists to make the
sentence true under an anonymous stranger.

    spec.py       registry/walkin/<station>.json — adding an OS is data
    launcher.py   read the station's OWN launcher; never fork it
    deviceset.py  refuse any override that would change the device set (rule 6)
    derive.py     launcher + override -> one clone's command line
    naming.py     identity, slot, tap, port, MAC (contract ledger §5.1)
    claims.py     kh-claim: "it exists" is not "it is mine" (rule 7)
    clone.py      spawn / resume / kill-through-clone-guard / discard overlay
    broker.py     the pool, the sessions, the TTL+idle watchdog
    routes.py     the server side of /walkin/state|claim|release|reset

Lane 2 owns who is allowed to call these; this package owns what happens when
they do.
"""

from __future__ import annotations

from .broker import Broker, BrokerError
from .spec import SpecError, StationSpec

__all__ = ["Broker", "BrokerError", "SpecError", "StationSpec"]

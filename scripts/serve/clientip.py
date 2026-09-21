"""Which client address this process is willing to believe.

Its own module, and deliberately free of the auth package's imports, so the
trust boundary can be unit-tested without a WebAuthn stack present — the reason
the first version of these tests could never run anywhere.

THE BOUNDARY. An address is evidence only when a hop that could SEE the
connection wrote it down. Two positions reach this process:

  * the forwarder agent, over loopback — the public path. Its edge
    (Wnt/forwarder) REPLACES X-Forwarded-For with the single address its own
    TLS terminator observed, discarding anything the caller sent. Believe it.
  * anything else — the LAN listener, reachable directly. Nobody vouched for
    the header and the caller may have written it by hand. Believe the socket.

Reading the header unconditionally, as this did until 2026-09-21, let a direct
caller name any address it liked and have it rate-limited, logged and
(eventually) geolocated as fact.
"""

from __future__ import annotations

import ipaddress

UNKNOWN = "unknown"


def is_loopback(addr: str) -> bool:
    """True when addr is this box talking to itself — the only position from
    which the tunnel can hand us an address to believe."""
    try:
        return ipaddress.ip_address(addr).is_loopback
    except ValueError:
        return False


def client_ip(peer: str | None, xff: str | None) -> str:
    """The address to attribute this request to.

    `peer` is the socket peer; `xff` the raw X-Forwarded-For header, if any.
    The LAST entry is taken rather than the first: the edge emits a single
    value, so the two agree today, and an appending proxy inserted later would
    write the observed address last. The first entry is whatever the caller
    chose to claim.
    """
    if not peer:
        return UNKNOWN
    if not is_loopback(peer):
        return peer
    if xff:
        # Scan from the right for the last NON-EMPTY entry: a proxy that emits a
        # trailing comma or an empty element would otherwise drop the observed
        # address and silently downgrade the attribution to the tunnel itself.
        for entry in reversed(xff.split(",")):
            entry = entry.strip()
            if entry:
                return entry
    return peer

"""Country for an IP address, resolved locally.

WHY LOCAL. An IP geolocation service would mean sending visitor addresses to a
third party on every lookup, and docs/ANALYTICS.md states plainly that this
plane has "no external service, no third-party script, no account anywhere in
it". A database file on the box keeps that true: it is fetched once by
scripts/serve/install-geoip.sh (DB-IP Lite, CC BY 4.0, no account, no API key)
and read from disk.

WHAT IS STORED. A two-letter country code, and only for the admin People list.
The address itself already lives where it lived before; this adds no new
retention. City-level data is deliberately NOT resolved even though DB-IP
publishes it: the question the admin list answers is "roughly where do the
people with accounts sign in from", and a city adds identifying precision
nobody asked for.

DEGRADING. The database is not in git and may simply be absent — on a fresh
box, in a test, or if a monthly refresh failed. Every path here returns None in
that case and the caller shows nothing. A missing database must never be an
error a visitor or an admin sees.
"""

from __future__ import annotations

import ipaddress
import os
import threading
from pathlib import Path

# Where install-geoip.sh puts it. Overridable so a test can point at a fixture.
GEOIP_DB = Path(os.environ.get("GEOIP_DB", "/data/vms/streamhost/serve/geoip/dbip-country-lite.mmdb"))

_lock = threading.Lock()
_reader = None  # lazily opened; None also means "tried and unavailable"
_tried = False


def _open_reader():
    """Open the database once, or decide it is unavailable and stop trying.

    mmdb readers are cheap to keep open and expensive to reopen per request, and
    this is called from the request path.
    """
    global _reader, _tried
    with _lock:
        if _tried:
            return _reader
        _tried = True
        try:
            import maxminddb  # imported lazily: absent DB => absent dependency is fine too

            _reader = maxminddb.open_database(str(GEOIP_DB))
        except Exception:
            # FileNotFoundError on a box that never ran the installer, ImportError
            # if the venv predates the lock, InvalidDatabaseError on a truncated
            # download. None of these is worth a stack trace on every request.
            _reader = None
        return _reader


def reset_for_test() -> None:
    """Forget the cached reader so a test can swap GEOIP_DB."""
    global _reader, _tried
    with _lock:
        _reader = None
        _tried = False


def is_routable(addr: str) -> bool:
    """False for anything that cannot belong to a visitor: loopback, RFC1918,
    link-local, multicast, unspecified. Looking those up wastes a read and,
    worse, invites reading meaning into a private address."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return not (ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_multicast or ip.is_unspecified)


def country_code(addr: str | None) -> str | None:
    """ISO 3166-1 alpha-2 for `addr`, or None when it cannot be answered.

    None covers every "we do not know": no address, a private one, no database,
    or an address the database has no entry for. The caller renders nothing —
    never a guess and never a placeholder that reads like a country.
    """
    if not addr or not is_routable(addr):
        return None
    reader = _open_reader()
    if reader is None:
        return None
    try:
        rec = reader.get(addr)
    except Exception:
        return None
    if not isinstance(rec, dict):
        return None
    country = rec.get("country") or rec.get("registered_country") or {}
    code = country.get("iso_code") if isinstance(country, dict) else None
    return code if isinstance(code, str) and len(code) == 2 else None

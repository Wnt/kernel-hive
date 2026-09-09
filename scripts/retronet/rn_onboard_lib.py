#!/usr/bin/env python3
"""rn_onboard_lib — the pure half of `rn-onboard.sh`: everything that can be
decided without touching the box or the filesystem.

It lives apart from the CLI for two reasons. The first is that the whole point
of this tool is that it REFUSES to commit a real address, and a refusal is only
worth anything if it is unit-tested — `scripts/test_rn_onboard.py` exercises
every function here. The second is the 600-line file cap.

Rule 1 in one paragraph, because it is the rule this module exists to enforce:
placeholders live in git, real values live in the BOX-side
`/data/kernel-hive/registry/local.env`. For a retronet station that means the
committed launcher, `rn-tapnet.sh` and registry all carry the scrubbed MAC
`02:00:00:00:00:<octet>` and read `RN_<ID>_MAC` at boot. The retronet's OWN
address space (10.99.0.0/24) is the deliberate exception: it is committed on
purpose because `retronet.address` is the only half of the uniqueness ledger a
public gate can see (WEB-PLANE-PLAN.md).
"""

from __future__ import annotations

import re
import secrets
from typing import Any

# ── The scheme ───────────────────────────────────────────────────────────────
# One station id yields every shared name, so nothing is passed in twice and
# two agents cannot spell the same station's chain differently.

BRIDGE = "vmbr-rn"
GATEWAY_ADDRESS = "10.99.0.2"
BOT_UIN = "10000"
BOT_NICK = "HiveBot"
PLACEHOLDER_MAC_PREFIX = "02:00:00:00:00:"
LOCAL_ENV = "/data/kernel-hive/registry/local.env"
PLANES = ("web", "icq")

# 15 chars is IFNAMSIZ-1; the kernel and MAME both truncate silently past it.
MAX_IFNAME = 15
# iptables refuses a chain name over 28 characters.
MAX_CHAIN = 28


def tap_name(station: str) -> str:
    return f"{station}rn0"


def chain_name(station: str) -> str:
    return f"{re.sub(r'[^A-Za-z0-9]', '', station).upper()}RN-IN"


def env_key(station: str, kind: str) -> str:
    """`RN_<ID>_MAC` / `RETRONET_ICQ_<ID>_PASS`, the two box-side names."""
    ident = re.sub(r"[^A-Za-z0-9]", "_", station).upper()
    return {"mac": f"RN_{ident}_MAC", "pass": f"RETRONET_ICQ_{ident}_PASS"}[kind]


def station_doc(station: str) -> str:
    return f"docs/lab/retronet/STATION-{station}.md"


def check_names(station: str) -> list[str]:
    """The two length limits that fail LATE and silently if they are not checked."""
    problems = []
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", station):
        problems.append(f"station id {station!r} is not lowercase alphanumeric")
    if len(tap_name(station)) > MAX_IFNAME:
        problems.append(f"tap name {tap_name(station)!r} is over {MAX_IFNAME} chars (IFNAMSIZ truncates silently)")
    if len(chain_name(station)) > MAX_CHAIN:
        problems.append(f"chain name {chain_name(station)!r} is over {MAX_CHAIN} chars (iptables refuses it)")
    return problems


# ── Rule 1: what may appear in a committed file ──────────────────────────────

_MAC_RE = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
_IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")

# The retronet plane itself, slirp's fixed private stack (an emulator constant,
# not an address of ours), loopback/any, and the RFC 5737 documentation blocks
# this repo scrubs to. Everything else in a file we are about to WRITE is a real
# address until someone proves otherwise.
_ALLOWED_IP_PREFIXES = ("10.99.0.", "10.0.2.", "127.", "192.0.2.", "198.51.100.", "203.0.113.")
_ALLOWED_IPS = {"0.0.0.0", "255.255.255.0", "255.255.255.255", "10.99.0.0", "1.1.1.1", "8.8.8.8"}


def real_mac(mac: str) -> bool:
    return bool(_MAC_RE.fullmatch(mac)) and not mac.lower().startswith(PLACEHOLDER_MAC_PREFIX)


def placeholder_mac(mac: str) -> str:
    """`52:54:00:52:4e:1e` -> `02:00:00:00:00:1e` — the fleet's scrub, which keeps
    only the last octet (already public: it is the address's last octet in hex)."""
    if not _MAC_RE.fullmatch(mac):
        raise ValueError(f"not a MAC address: {mac!r}")
    return PLACEHOLDER_MAC_PREFIX + mac.split(":")[-1].lower()


def check_committable(text: str, what: str) -> list[str]:
    """Every reason `text` must not be written into the repo. Empty list = fine."""
    problems = []
    for mac in dict.fromkeys(_MAC_RE.findall(text)):
        if real_mac(mac):
            problems.append(
                f"{what}: refusing to commit the MAC {mac} — put it in {LOCAL_ENV} "
                f"and let the file carry {placeholder_mac(mac)} (rule 1)"
            )
    for ip in dict.fromkeys(_IPV4_RE.findall(text)):
        if ip in _ALLOWED_IPS or ip.startswith(_ALLOWED_IP_PREFIXES):
            continue
        problems.append(
            f"{what}: refusing to commit the address {ip} — the retronet plane is "
            f"10.99.0.0/24 and everything else is scrubbed to 192.0.2.x (rule 1)"
        )
    return problems


def check_address(address: str) -> list[str]:
    """A retronet address must be on the plane, and must not be an infrastructure one."""
    if not re.fullmatch(r"10\.99\.0\.(\d{1,3})", address):
        return [f"{address} is not on the retronet plane (10.99.0.0/24)"]
    octet = int(address.rsplit(".", 1)[1])
    if octet in (0, 1, 2, 255):
        return [f"{address} is reserved (0 network, 1 labhost bridge, 2 gateway CT, 255 broadcast)"]
    if octet >= 100:
        return [f"{address} is inside the DHCP pool (.100+) — reservations live below it"]
    return []


def expected_mac(address: str) -> str:
    """The fleet scheme, `52:54:00:52:4e:<last IP octet in hex>` — returned so the
    CLI can say what it expected, never written into a committed file."""
    return f"52:54:00:52:4e:{int(address.rsplit('.', 1)[1]):02x}"


# The gateway rejects anything outside 6-8 characters, and era clients mangle
# characters outside [a-z0-9] (GATEWAY.md).
def generate_password(length: int = 8) -> str:
    alphabet = "abcdefghijkmnopqrstuvwxyz23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def check_password(password: str) -> list[str]:
    if not 6 <= len(password) <= 8:
        return [f"password is {len(password)} chars; the gateway accepts 6-8"]
    if not re.fullmatch(r"[a-z0-9]+", password):
        return ["password has characters outside [a-z0-9]; era clients mangle them"]
    return []


# ── Rendering ────────────────────────────────────────────────────────────────

_TEMPLATE_ONLY = re.compile(r"^[^\n]*>>> template-only[^\n]*\n.*?^[^\n]*<<< template-only[^\n]*\n", re.S | re.M)
_TOKEN = re.compile(r"@[A-Z]+@")


def tokens_for(
    station: str,
    address: str,
    mac: str,
    *,
    uin: str = "",
    planes: tuple[str, ...] = PLANES,
    addressing: str = "dhcp",
    date: str = "",
) -> dict[str, str]:
    return {
        "@ID@": station,
        "@IDUPPER@": re.sub(r"[^A-Za-z0-9]", "_", station).upper(),
        "@TAP@": tap_name(station),
        "@CHAIN@": chain_name(station),
        "@ADDRESS@": address,
        "@MAC@": placeholder_mac(mac),
        "@ADDRESSING@": addressing,
        "@DOC@": station_doc(station),
        "@UIN@": uin or "(no ICQ plane)",
        "@PLANES@": " + ".join(planes) if planes else "no plane",
        "@DATE@": date,
    }


def render(template: str, tokens: dict[str, str], what: str) -> str:
    """Strip the template-only block, substitute, then re-check the RESULT.

    The re-check is the part that matters: a token map is easy to get right and
    easy to bypass, and the only thing that actually protects the repo is asking
    the finished bytes whether they carry a real address.
    """
    text = _TEMPLATE_ONLY.sub("", template)
    for token, value in tokens.items():
        text = text.replace(token, value)
    left = sorted(set(_TOKEN.findall(text)))
    if left:
        raise ValueError(f"{what}: unsubstituted template tokens: {', '.join(left)}")
    problems = check_committable(text, what)
    if problems:
        raise ValueError("\n".join(problems))
    return text


# ── The structured rows ──────────────────────────────────────────────────────


def registry_block(station: str, address: str, *, planes: list[str], addressing: str, joined: str) -> dict[str, Any]:
    """The `retronet` block for registry/stations/<id>.json.

    `link` and `guard` are prose the box is checked against by
    `stations-registry.py facts-live`, so their exact shape is a contract:
    "tap <if> on <bridge>" is what its interface parser reads.
    """
    return {
        "planes": list(planes),
        "address": address,
        "addressing": addressing,
        "link": f"tap {tap_name(station)} on {BRIDGE}",
        "guard": chain_name(station),
        "joined": joined,
        "doc": station_doc(station),
    }


def roster_row(station: str, uin: str, client: str) -> dict[str, Any]:
    """`onboarded` stays false until a frame shows the client signed in — the
    roster's word for "live", and what gates the fleet-wide SSI cross-list."""
    return {"station": station, "uin": uin, "nick": station, "client": client, "onboarded": False}


def insert_roster_row(roster: dict[str, Any], row: dict[str, Any]) -> dict[str, Any]:
    """Idempotent by station id; refuses a UIN another station already holds."""
    for other in roster["stations"]:
        if other["station"] != row["station"] and other["uin"] == row["uin"]:
            raise ValueError(f"UIN {row['uin']} is already {other['station']}'s in the roster")
    stations = [s for s in roster["stations"] if s["station"] != row["station"]]
    kept = next((s for s in roster["stations"] if s["station"] == row["station"]), None)
    if kept is not None:
        row = {**row, "onboarded": kept.get("onboarded", False)}
    return {**roster, "stations": [*stations, row]}


def local_env_append(station: str, mac: str, password: str | None) -> str:
    """ONE append, so a half-written pair cannot exist.

    Not in here: `RETRONET_DHCP_RESERVATIONS`. That is a single variable holding
    the whole ledger, `wave.sh alloc` owns it, and appending a second assignment
    would silently shadow the first.
    """
    lines = [f"# retronet: {station}, appended by rn-onboard.sh"]
    if real_mac(mac):
        lines.append(f"{env_key(station, 'mac')}={mac}")
    if password:
        lines.append(f"{env_key(station, 'pass')}={password}")
    return "\n".join(lines) + "\n"


def gateway_commands(uin: str, nick: str, password: str) -> list[list[str]]:
    """The server-side account, in the order the gateway needs it.

    `user-open` is not optional: without it the account refuses unattended
    contacts and HiveBot cannot add the station back (the authRequired gotcha).
    """
    base = ["pct", "exec", "951", "--", "python3", "/opt/ras/rn-tool.py"]
    return [
        [*base, "user-set", uin, password],
        [*base, "user-open", uin],
        [*base, "nick", uin, nick],
        [*base, "ssi-seed", uin, f"{BOT_UIN}={BOT_NICK}"],
    ]

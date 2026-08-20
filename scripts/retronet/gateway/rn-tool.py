#!/usr/bin/env python3
"""rn-tool — the retronet gateway's own hands: accounts, WAN proof, real logins.

Installed inside the gateway CT at /opt/ras/rn-tool.py by
provision-gateway-ct.sh, and equally runnable from labhost (`login` and
`wan-probe` take an address; `users`/`user-set` talk to the CT-local management
API and only work inside).

WHY PYTHON AND NOT curl. The Debian CT ships no curl and has no way to install
one — it cannot reach a mirror, which is the whole point of the machine. The
stdlib is the only client that is guaranteed to be there.

WHY A LOGIN CHECK EXISTS AT ALL. "The account row is in the database" and "the
persona can sign in" are different claims, and only the second one is the thing
the exhibit needs. `login` performs the real OSCAR BUCP handshake — challenge,
MD5 hash, login request — and reports the BOS address the server hands back.
That address is the subtle part of this deployment: it is what the client
connects to NEXT, so a wrong one shows up as a client that authenticates and
then hangs, days later, on a station. Checking it here is how that never
happens.

usage:
  rn-tool.py users
  rn-tool.py user-set <screen_name> <password>
  rn-tool.py user-open <screen_name>
  rn-tool.py wan-probe
  rn-tool.py login <host> <port> <screen_name> <password>
"""

from __future__ import annotations

import hashlib
import json
import socket
import sqlite3
import struct
import sys
import urllib.error
import urllib.request

API = "http://127.0.0.1:8080"
DB_PATH = "/var/lib/ras/oscar.sqlite"

# --- OSCAR wire format ------------------------------------------------------

FLAP_SIGNON = 1
FLAP_DATA = 2
FOODGROUP_BUCP = 0x0017
BUCP_LOGIN_REQUEST = 0x0002
BUCP_LOGIN_RESPONSE = 0x0003
BUCP_CHALLENGE_REQUEST = 0x0006
BUCP_CHALLENGE_RESPONSE = 0x0007
TLV_SCREEN_NAME = 0x0001
TLV_CLIENT_IDENTITY = 0x0003
TLV_RECONNECT_HERE = 0x0005
TLV_AUTH_COOKIE = 0x0006
TLV_ERROR_SUBCODE = 0x0008
TLV_PASSWORD_HASH = 0x0025
TLV_MULTI_CONN_FLAGS = 0x004A

# The client identity string is not decoration: the server branches on it (the
# Java AIM client gets a different roasting table). Announce what we are.
CLIENT_ID = "kernel-hive retronet rn-tool"

LOGIN_ERRORS = {
    0x01: "invalid nick or password",
    0x04: "incorrect nick or password",
    0x05: "mismatch nick or password",
    0x11: "account suspended",
    0x18: "rate limited — too many login attempts",
    0x1C: "client too old",
}


def tlv(tag: int, value: bytes) -> bytes:
    return struct.pack(">HH", tag, len(value)) + value


def parse_tlvs(buf: bytes) -> dict[int, bytes]:
    out: dict[int, bytes] = {}
    i = 0
    while i + 4 <= len(buf):
        tag, ln = struct.unpack(">HH", buf[i : i + 4])
        out[tag] = buf[i + 4 : i + 4 + ln]
        i += 4 + ln
    return out


class Flap:
    """A framed OSCAR connection. Sequence numbers are per-connection."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.seq = 0

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError(f"connection closed after {len(buf)}/{n} bytes")
            buf += chunk
        return buf

    def send(self, channel: int, payload: bytes) -> None:
        self.seq = (self.seq + 1) & 0xFFFF
        head = struct.pack(">BBHH", 0x2A, channel, self.seq, len(payload))
        self.sock.sendall(head + payload)

    def recv(self) -> tuple[int, bytes]:
        head = self._recv_exact(6)
        if head[0] != 0x2A:
            raise ValueError(f"not a FLAP frame: {head!r}")
        channel = head[1]
        (length,) = struct.unpack(">H", head[4:6])
        return channel, self._recv_exact(length)

    def send_snac(self, food: int, sub: int, req: int, body: bytes) -> None:
        self.send(FLAP_DATA, struct.pack(">HHHI", food, sub, 0, req) + body)

    def recv_snac(self) -> tuple[int, int, bytes]:
        channel, payload = self.recv()
        if channel != FLAP_DATA:
            raise ValueError(f"expected a data frame, got FLAP channel {channel}")
        food, sub, _flags, _req = struct.unpack(">HHHI", payload[:10])
        return food, sub, payload[10:]


def strong_md5(password: str, auth_key: bytes) -> bytes:
    """MD5(authKey + MD5(password) + magic) — the AIM 4.8+ "strong" hash.

    The server accepts either this or the weak variant (which feeds the
    plaintext password in place of its digest); this one never puts the
    password itself on the wire.
    """
    inner = hashlib.md5(password.encode()).digest()
    outer = hashlib.md5()
    outer.update(auth_key)
    outer.update(inner)
    outer.update(b"AOL Instant Messenger (SM)")
    return outer.digest()


def cmd_login(host: str, port: int, screen_name: str, password: str) -> int:
    with socket.create_connection((host, port), timeout=10) as sock:
        flap = Flap(sock)

        channel, _ = flap.recv()  # server hello
        if channel != FLAP_SIGNON:
            print(f"FAIL  server opened with FLAP channel {channel}, expected 1")
            return 1
        flap.send(FLAP_SIGNON, struct.pack(">I", 1))

        flap.send_snac(
            FOODGROUP_BUCP,
            BUCP_CHALLENGE_REQUEST,
            1,
            tlv(TLV_SCREEN_NAME, screen_name.encode()),
        )
        food, sub, body = flap.recv_snac()
        if (food, sub) == (FOODGROUP_BUCP, BUCP_LOGIN_RESPONSE):
            # The server answers a challenge with a login response only to say
            # "no such user" — DISABLE_AUTH=false and the account is missing.
            return report_login_failure(parse_tlvs(body), screen_name)
        if (food, sub) != (FOODGROUP_BUCP, BUCP_CHALLENGE_RESPONSE):
            print(f"FAIL  unexpected SNAC {food:#06x}/{sub:#06x} for the challenge")
            return 1
        (key_len,) = struct.unpack(">H", body[:2])
        auth_key = body[2 : 2 + key_len]

        flap.send_snac(
            FOODGROUP_BUCP,
            BUCP_LOGIN_REQUEST,
            2,
            tlv(TLV_SCREEN_NAME, screen_name.encode())
            + tlv(TLV_PASSWORD_HASH, strong_md5(password, auth_key))
            + tlv(TLV_CLIENT_IDENTITY, CLIENT_ID.encode())
            + tlv(TLV_MULTI_CONN_FLAGS, b"\x01"),
        )
        food, sub, body = flap.recv_snac()
        if (food, sub) != (FOODGROUP_BUCP, BUCP_LOGIN_RESPONSE):
            print(f"FAIL  unexpected SNAC {food:#06x}/{sub:#06x} for the login")
            return 1
        tlvs = parse_tlvs(body)
        if TLV_ERROR_SUBCODE in tlvs or TLV_AUTH_COOKIE not in tlvs:
            return report_login_failure(tlvs, screen_name)
        bos = tlvs[TLV_RECONNECT_HERE].decode(errors="replace")
        cookie = tlvs[TLV_AUTH_COOKIE]
        print(f"PASS  {screen_name} authenticated at {host}:{port}")
        print(f"      BOS address advertised to this client: {bos}")
        print(f"      auth cookie: {len(cookie)} bytes")
        return 0


def report_login_failure(tlvs: dict[int, bytes], screen_name: str) -> int:
    raw = tlvs.get(TLV_ERROR_SUBCODE, b"")
    code = struct.unpack(">H", raw)[0] if len(raw) == 2 else -1
    why = LOGIN_ERRORS.get(code, "unknown error")
    print(f"FAIL  {screen_name} rejected: error {code:#04x} ({why})")
    return 1


# --- management API ---------------------------------------------------------


def api(method: str, path: str, body: dict | None = None) -> tuple[int, bytes]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(  # noqa: S310 — fixed loopback URL
        API + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:  # noqa: S310
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def cmd_users() -> int:
    status, payload = api("GET", "/user")
    if status != 200:
        print(f"GET /user -> {status}: {payload.decode(errors='replace')}")
        return 1
    for user in json.loads(payload):
        kind = "ICQ" if user.get("is_icq") else "AIM"
        print(f"{user['screen_name']:<16} {kind}  {user.get('id', '')}")
    return 0


def cmd_user_set(screen_name: str, password: str) -> int:
    """Create the account, or reset its password if it is already there.

    Idempotent on purpose: re-provisioning must converge on the password the
    lab has recorded, not fail because a previous run got there first.
    """
    status, payload = api("POST", "/user", {"screen_name": screen_name, "password": password})
    if status == 201:
        print(f"created {screen_name}")
        return 0
    if status == 409:
        status, payload = api("PUT", "/user/password", {"screen_name": screen_name, "password": password})
        if status == 204:
            print(f"exists  {screen_name} (password set to the recorded value)")
            return 0
    print(f"{screen_name}: {status} {payload.decode(errors='replace')}")
    return 1


def cmd_user_open(screen_name: str) -> int:
    """Clear ICQ "my authorization is required" for one UIN.

    WHY THIS EXISTS, and why the greeting does not work without it. The server
    creates every ICQ account with `authRequired` set, so adding it as a contact
    is refused (`BuddyAddBuddies` -> `BuddyRejectNotification`, and the feedbag
    route the same) until its owner clicks "authorize" in a client. Presence
    only flows to watchers on the contact list, so with the flag set the bot
    never learns that the persona signed on and **the greeter never fires** —
    silently, with a healthy-looking server and a healthy-looking bot.

    On the retronet, authorization is ceremony with nobody to perform it: the
    persona is an unattended account whose whole job is to be visible, and the
    bot is the museum's own greeter. Clearing the flag is also the era-accurate
    setting (ICQ's "My authorization is not required" checkbox), and it is
    symmetric — the persona's client can then add the bot without a prompt too.

    The management API has no endpoint for ICQ permissions, so this writes the
    one column directly. SQLite is multi-process safe and the server re-reads
    the row on every check (no cache), so it takes effect without a restart.
    """
    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
    except sqlite3.Error as exc:
        print(f"{screen_name}: cannot open {DB_PATH}: {exc}")
        return 1
    with conn:
        cur = conn.execute(
            "UPDATE users SET icq_permissions_authRequired = 0 WHERE identScreenName = ?",
            (screen_name.lower(),),
        )
        changed = cur.rowcount
    conn.close()
    if changed < 1:
        print(f"{screen_name}: no such account (create it first with user-set)")
        return 1
    print(f"open    {screen_name} (authorization not required — contacts and presence work unattended)")
    return 0


def cmd_user_is_open(screen_name: str) -> bool:
    conn = sqlite3.connect(DB_PATH, timeout=10)
    row = conn.execute(
        "SELECT icq_permissions_authRequired FROM users WHERE identScreenName = ?",
        (screen_name.lower(),),
    ).fetchone()
    conn.close()
    return bool(row) and not row[0]


# --- no-WAN proof -----------------------------------------------------------

# Three different networks, three different well-known anycast addresses, all
# dialled by IP so a missing resolver cannot be mistaken for isolation.
WAN_TARGETS = [("1.1.1.1", 443), ("8.8.8.8", 53), ("9.9.9.9", 443)]


def default_routes() -> list[str]:
    """Default routes straight from the kernel — no `ip` binary needed."""
    routes = []
    with open("/proc/net/route", encoding="ascii") as fh:
        next(fh)
        for line in fh:
            cols = line.split()
            if len(cols) > 2 and cols[1] == "00000000":
                routes.append(cols[0])
    return routes


def cmd_wan_probe() -> int:
    ok = True
    routes = default_routes()
    if routes:
        print(f"FAIL  a default route exists via {', '.join(routes)}")
        ok = False
    else:
        print("PASS  no default route in the kernel routing table")
    for host, port in WAN_TARGETS:
        try:
            with socket.create_connection((host, port), timeout=5):
                print(f"FAIL  connected to {host}:{port} — this machine has a WAN")
                ok = False
        except OSError as exc:
            print(f"PASS  {host}:{port} unreachable ({exc})")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    if cmd == "users":
        return cmd_users()
    if cmd == "user-set" and len(args) == 2:
        return cmd_user_set(*args)
    if cmd == "user-open" and len(args) == 1:
        return cmd_user_open(*args)
    if cmd == "user-is-open" and len(args) == 1:
        return 0 if cmd_user_is_open(*args) else 1
    if cmd == "wan-probe":
        return cmd_wan_probe()
    if cmd == "login" and len(args) == 4:
        return cmd_login(args[0], int(args[1]), args[2], args[3])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

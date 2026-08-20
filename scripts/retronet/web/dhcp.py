#!/usr/bin/env python3
"""retronet-dhcp — the addressing server of the web plane (Lane B).

Runs INSIDE the gateway CT (951, 10.99.0.2). It hands a bridged station three
things and DELIBERATELY WITHHOLDS a fourth:

  * an IP  — a per-MAC reservation if the station is known (so exec-over-bridge
             keeps hitting it at a STABLE <ip>:7788), else the next free address
             from a pool;
  * the subnet mask;
  * DNS = the gateway (10.99.0.2), where retronet-dns answers every name;
  * NO router / default-gateway option (option 3 is never sent).

Withholding the router is the whole point: a guest that gets no default route
can reach only the on-subnet gateway — containment (no WAN) is preserved by the
addressing itself, not just by in-guest config. A station therefore joins with
the Windows defaults ("obtain an IP automatically", "obtain DNS automatically")
and needs no per-guest static addressing at all. See
docs/lab/retronet/WEB-PLANE-PLAN.md and ICQ-STATION.md.

Offline by construction: this server opens NO outbound connection. It answers
DISCOVER/REQUEST from its config and an in-memory lease table, and the CT has no
route off its /24 anyway.

Config (systemd EnvironmentFile /etc/retronet/dhcp.env, or the environment):
  RN_DHCP_LISTEN        bind host:port           (default 0.0.0.0:67)
  RN_DHCP_SERVER_ID     this server's address    (default 10.99.0.2)
  RN_DHCP_SUBNET_MASK   handed to clients        (default 255.255.255.0)
  RN_DHCP_DNS           DNS server(s), csv/space (default 10.99.0.2)
  RN_DHCP_DOMAIN        DNS domain suffix        (default retronet.lab; blank=off)
  RN_DHCP_POOL          general pool lo-hi       (default 10.99.0.100-10.99.0.200)
  RN_DHCP_LEASE         lease seconds            (default 3600)
  RN_DHCP_RESERVATIONS  csv/space of mac=ip      (default empty)  e.g.
                        "02:00:00:00:00:10=10.99.0.10 02:00:00:00:00:11=10.99.0.11"

As-built: docs/lab/retronet/WEB-PROXY.md (addressing plane).
"""

from __future__ import annotations

import os
import re
import socket
import socketserver
import struct
import sys
import threading
import time

# --- defaults (every one overridable from /etc/retronet/dhcp.env) ------------
DEF_LISTEN = "0.0.0.0:67"
DEF_SERVER_ID = "10.99.0.2"
DEF_MASK = "255.255.255.0"
DEF_DNS = "10.99.0.2"
DEF_DOMAIN = "retronet.lab"
DEF_POOL = "10.99.0.100-10.99.0.200"
DEF_LEASE = 3600

MAGIC = bytes([99, 130, 83, 99])
# option codes
O_SUBNET, O_ROUTER, O_DNS, O_HOSTNAME, O_DOMAIN = 1, 3, 6, 12, 15
O_REQIP, O_LEASE, O_MSGTYPE, O_SERVERID, O_PARAMS, O_CLIENTID, O_END = 50, 51, 53, 54, 55, 61, 255
# message types
DISCOVER, OFFER, REQUEST, DECLINE, ACK, NAK, RELEASE, INFORM = 1, 2, 3, 4, 5, 6, 7, 8

MAC_RE = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")


def ip2int(ip: str) -> int:
    return struct.unpack("!I", socket.inet_aton(ip))[0]


def int2ip(n: int) -> str:
    return socket.inet_ntoa(struct.pack("!I", n))


def fmt_mac(raw: bytes) -> str:
    return ":".join(f"{b:02x}" for b in raw)


def parse_packet(data: bytes) -> dict | None:
    """Decode a BOOTP/DHCP packet into the few fields we act on, or None."""
    if len(data) < 240 or data[236:240] != MAGIC:
        return None
    op, _htype, hlen = data[0], data[1], data[2]
    xid = data[4:8]
    flags = struct.unpack("!H", data[10:12])[0]
    ciaddr = int2ip(struct.unpack("!I", data[12:16])[0])
    giaddr = int2ip(struct.unpack("!I", data[24:28])[0])
    chaddr = data[28 : 28 + max(hlen, 6)]
    mac = fmt_mac(chaddr[:6])
    opts: dict[int, bytes] = {}
    i = 240
    while i < len(data):
        code = data[i]
        if code == O_END:
            break
        if code == 0:  # pad
            i += 1
            continue
        if i + 1 >= len(data):
            break
        length = data[i + 1]
        opts[code] = data[i + 2 : i + 2 + length]
        i += 2 + length
    return {
        "op": op,
        "xid": xid,
        "flags": flags,
        "ciaddr": ciaddr,
        "giaddr": giaddr,
        "mac": mac,
        "chaddr": chaddr,
        "opts": opts,
    }


def _opt(code: int, payload: bytes) -> bytes:
    return bytes([code, len(payload)]) + payload


def build_reply(req: dict, msgtype: int, yiaddr: str, cfg: dict) -> bytes:
    """Assemble a BOOTREPLY. Note what is NEVER added: option 3 (router)."""
    chaddr = (req["chaddr"] + b"\x00" * 16)[:16]
    header = struct.pack(
        "!BBBB4sHHII4sI16s64s128s",
        2,  # op = BOOTREPLY
        1,  # htype = ethernet
        6,  # hlen
        0,  # hops
        req["xid"],
        0,  # secs
        req["flags"],  # echo broadcast flag
        0,  # ciaddr
        ip2int(yiaddr) if yiaddr else 0,
        b"\x00\x00\x00\x00",  # siaddr
        ip2int(req["giaddr"]),
        chaddr,
        b"",  # sname
        b"",  # file
    )
    opts = MAGIC
    opts += _opt(O_MSGTYPE, bytes([msgtype]))
    opts += _opt(O_SERVERID, socket.inet_aton(cfg["server_id"]))
    if msgtype in (OFFER, ACK) and yiaddr:
        opts += _opt(O_LEASE, struct.pack("!I", cfg["lease"]))
        opts += _opt(O_SUBNET, socket.inet_aton(cfg["mask"]))
        # DNS -> the gateway resolver. This is the seam that makes "no proxy"
        # browsing work: the guest resolves every name through 10.99.0.2.
        opts += _opt(O_DNS, b"".join(socket.inet_aton(d) for d in cfg["dns"]))
        if cfg["domain"]:
            opts += _opt(O_DOMAIN, cfg["domain"].encode("ascii"))
        # DELIBERATELY no option 3 (router): the guest gets no default route, so
        # it can reach only the on-subnet gateway. Containment by addressing.
    opts += bytes([O_END])
    return header + opts


class Leases:
    """Reservations (fixed) + a small in-memory pool. Minimal by design: a
    restart re-learns on the next DISCOVER/REQUEST, which era clients send on
    every boot anyway."""

    def __init__(self, reservations: dict[str, str], pool_lo: str, pool_hi: str):
        self.reservations = reservations
        self.lo, self.hi = ip2int(pool_lo), ip2int(pool_hi)
        self.by_mac: dict[str, tuple[str, float]] = {}  # pool leases: mac -> (ip, expiry)
        self.lock = threading.Lock()

    def offer(self, mac: str, lease: int) -> str | None:
        """The address this MAC should get: its reservation, its existing pool
        lease, or the next free pool address. None if the pool is exhausted."""
        if mac in self.reservations:
            return self.reservations[mac]
        with self.lock:
            now = time.time()
            cur = self.by_mac.get(mac)
            if cur and cur[1] > now:
                return cur[0]
            reserved = set(ip2int(v) for v in self.reservations.values())
            taken = {ip2int(ip) for ip, exp in self.by_mac.values() if exp > now}
            for n in range(self.lo, self.hi + 1):
                if n not in taken and n not in reserved:
                    ip = int2ip(n)
                    self.by_mac[mac] = (ip, now + lease)
                    return ip
        return None

    def commit(self, mac: str, ip: str, lease: int) -> None:
        if mac not in self.reservations:
            with self.lock:
                self.by_mac[mac] = (ip, time.time() + lease)

    def release(self, mac: str) -> None:
        with self.lock:
            self.by_mac.pop(mac, None)


def decide(req: dict, leases: Leases, cfg: dict):
    """(msgtype, yiaddr) for a request, or None to stay silent."""
    if req["op"] != 1:  # only BOOTREQUEST from a client
        return None
    mtype_opt = req["opts"].get(O_MSGTYPE)
    if not mtype_opt:
        return None
    mtype = mtype_opt[0]
    mac = req["mac"]
    if mtype == DISCOVER:
        ip = leases.offer(mac, cfg["lease"])
        return (OFFER, ip) if ip else None
    if mtype == REQUEST:
        want = req["opts"].get(O_REQIP)
        requested = int2ip(struct.unpack("!I", want)[0]) if want and len(want) == 4 else req["ciaddr"]
        ip = leases.offer(mac, cfg["lease"])
        if ip and requested in (ip, "0.0.0.0", ""):
            leases.commit(mac, ip, cfg["lease"])
            return (ACK, ip)
        # Client insists on an address we won't grant -> tell it to start over.
        return (NAK, "")
    if mtype in (RELEASE, DECLINE):
        leases.release(mac)
        return None
    if mtype == INFORM:
        return (ACK, "")  # options only, no lease
    return None


class DHCPServer(socketserver.UDPServer):
    allow_reuse_address = True

    def __init__(self, addr, cfg, leases):
        self.cfg = cfg
        self.leases = leases
        super().__init__(addr, DHCPHandler)

    def server_bind(self):
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        super().server_bind()


class DHCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        try:
            req = parse_packet(data)
            if not req:
                return
            result = decide(req, self.server.leases, self.server.cfg)
            if not result:
                return
            msgtype, yiaddr = result
            reply = build_reply(req, msgtype, yiaddr, self.server.cfg)
        except (ValueError, OSError, struct.error, IndexError):
            return
        # No relay on this flat /24 and the client has no IP yet, so the reply is
        # a LIMITED broadcast (255.255.255.255:68) — it reaches the client whatever
        # the bridge FDB is doing. On the gateway CT there is no default route, so
        # that broadcast needs an explicit route to 255.255.255.255 (added by this
        # unit's ExecStartPre). If the send fails, say so LOUDLY — a silent
        # suppress here once hid exactly that missing route for an afternoon.
        dest = (req["giaddr"], 67) if req["giaddr"] != "0.0.0.0" else ("255.255.255.255", 68)
        name = {OFFER: "OFFER", ACK: "ACK", NAK: "NAK"}.get(msgtype, str(msgtype))
        try:
            sock.sendto(reply, dest)
        except OSError as e:
            msg = f"retronet-dhcp {req['mac']}: {name} {yiaddr} NOT SENT to {dest[0]} ({e}); broadcast route?"
            sys.stderr.write(msg + "\n")
            return
        sys.stderr.write(f"retronet-dhcp {req['mac']} -> {name} {yiaddr or '(no addr)'}\n")


# --- config + main -----------------------------------------------------------
def parse_reservations(value: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for tok in re.split(r"[,\s]+", value.strip()):
        if not tok:
            continue
        mac, _, ip = tok.partition("=")
        mac = mac.strip().lower()
        if not MAC_RE.match(mac):
            raise ValueError(f"bad reservation MAC: {mac!r}")
        socket.inet_aton(ip.strip())  # validate
        out[mac] = ip.strip()
    return out


def load_config() -> dict:
    listen = os.environ.get("RN_DHCP_LISTEN", DEF_LISTEN).strip()
    host, _, port = listen.rpartition(":")
    pool = os.environ.get("RN_DHCP_POOL", DEF_POOL).strip()
    lo, _, hi = pool.partition("-")
    dns = [d for d in re.split(r"[,\s]+", os.environ.get("RN_DHCP_DNS", DEF_DNS).strip()) if d]
    return {
        "addr": (host or "0.0.0.0", int(port or 67)),
        "server_id": os.environ.get("RN_DHCP_SERVER_ID", DEF_SERVER_ID).strip(),
        "mask": os.environ.get("RN_DHCP_SUBNET_MASK", DEF_MASK).strip(),
        "dns": dns,
        "domain": os.environ.get("RN_DHCP_DOMAIN", DEF_DOMAIN).strip(),
        "pool": (lo.strip(), hi.strip()),
        "lease": int(os.environ.get("RN_DHCP_LEASE", str(DEF_LEASE))),
        "reservations": parse_reservations(os.environ.get("RN_DHCP_RESERVATIONS", "")),
    }


def serve(cfg: dict) -> int:
    leases = Leases(cfg["reservations"], cfg["pool"][0], cfg["pool"][1])
    server = DHCPServer(cfg["addr"], cfg, leases)
    resv = ", ".join(f"{m}->{ip}" for m, ip in cfg["reservations"].items()) or "(none)"
    sys.stderr.write(
        f"retronet-dhcp: listening on {cfg['addr'][0]}:{cfg['addr'][1]}  pool={cfg['pool'][0]}-{cfg['pool'][1]}  "
        f"dns={','.join(cfg['dns'])}  NO-router  reservations: {resv}\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def selftest() -> int:
    """In-process proof: a DISCOVER from a reserved MAC is OFFERED its reserved
    IP, with DNS and mask set and NO router option; a REQUEST is ACKed; a pool
    MAC gets a pool address. No sockets."""
    cfg = {
        "server_id": "10.99.0.2",
        "mask": "255.255.255.0",
        "dns": ["10.99.0.2"],
        "domain": "retronet.lab",
        "lease": 3600,
        "reservations": {"52:54:00:12:34:56": "10.99.0.10"},
        "pool": ("10.99.0.100", "10.99.0.200"),
    }
    leases = Leases(cfg["reservations"], *cfg["pool"])
    ok = True

    def discover(mac_bytes):
        chaddr = mac_bytes + b"\x00" * 10
        pkt = struct.pack(
            "!BBBB4sHHII4sI16s64s128s", 1, 1, 6, 0, b"ABCD", 0, 0x8000, 0, 0, b"\0\0\0\0", 0, chaddr, b"", b""
        )
        return pkt + MAGIC + _opt(O_MSGTYPE, bytes([DISCOVER])) + bytes([O_END])

    req = parse_packet(discover(b"\x52\x54\x00\x12\x34\x56"))
    mt, ip = decide(req, leases, cfg)
    reply = build_reply(req, mt, ip, cfg)
    print(f"  reserved MAC     -> {'OFFER' if mt == OFFER else mt} {ip}")
    ok &= mt == OFFER and ip == "10.99.0.10"
    # the reply must carry yiaddr + mask + DNS and must NOT carry a router (opt 3)
    ropts = parse_packet(reply)
    ok &= ropts is not None and ropts["op"] == 2 and O_ROUTER not in ropts["opts"]
    ok &= ropts is not None and ropts["opts"].get(O_DNS) == socket.inet_aton("10.99.0.2")
    ok &= ropts is not None and ropts["opts"].get(O_SUBNET) == socket.inet_aton("255.255.255.0")
    ok &= struct.unpack("!I", reply[16:20])[0] == ip2int("10.99.0.10")  # yiaddr field
    print(f"  router option 3  -> {'absent' if (ropts and O_ROUTER not in ropts['opts']) else 'PRESENT!'}")
    # a pool MAC gets a pool address
    poolreq = parse_packet(discover(b"\xaa\xbb\xcc\xdd\xee\xff"))
    mt2, ip2 = decide(poolreq, leases, cfg)
    print(f"  pool MAC         -> {'OFFER' if mt2 == OFFER else mt2} {ip2}")
    ok &= mt2 == OFFER and ip2ip_in_pool(ip2, cfg["pool"])
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def ip2ip_in_pool(ip: str, pool) -> bool:
    return ip2int(pool[0]) <= ip2int(ip) <= ip2int(pool[1])


def probe(server: str, mac: str, giaddr: str) -> int:
    """Test client: pose as a relay agent (giaddr set) so the server unicasts
    the OFFER back to us at giaddr:67 — no broadcast plumbing needed. Prints the
    offered address and whether DNS is set / a router is (wrongly) present. Used
    by install-dhcp.sh verify from labhost's bridge address."""
    raw = bytes(int(b, 16) for b in mac.split(":"))
    chaddr = (raw + b"\x00" * 16)[:16]
    disc = struct.pack(
        "!BBBB4sHHII4sI16s64s128s", 1, 1, 6, 0, b"PROB", 0, 0, 0, 0, b"\0\0\0\0", ip2int(giaddr), chaddr, b"", b""
    )
    disc += (
        MAGIC + _opt(O_MSGTYPE, bytes([DISCOVER])) + _opt(O_PARAMS, bytes([O_SUBNET, O_ROUTER, O_DNS])) + bytes([O_END])
    )
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((giaddr, 67))
        s.settimeout(5)
        s.sendto(disc, (server, 67))
        data, _ = s.recvfrom(2048)
    reply = parse_packet(data)
    if not reply or reply["opts"].get(O_MSGTYPE, b"\x00")[0] != OFFER:
        print(f"probe {mac} @ {server} -> no OFFER")
        return 1
    yi = int2ip(struct.unpack("!I", data[16:20])[0])
    dns = reply["opts"].get(O_DNS, b"")
    dns_ips = [socket.inet_ntoa(dns[i : i + 4]) for i in range(0, len(dns), 4)]
    router = O_ROUTER in reply["opts"]
    print(f"probe {mac} @ {server} -> OFFER {yi}  dns={dns_ips}  router_option={'PRESENT' if router else 'absent'}")
    return 0 if (yi and dns_ips and not router) else 1


def main(argv) -> int:
    cmd = argv[0] if argv else "serve"
    if cmd == "serve":
        return serve(load_config())
    if cmd == "selftest":
        return selftest()
    if cmd == "probe":
        opts = dict(zip(argv[1::2], argv[2::2]))
        return probe(
            opts.get("--server", "10.99.0.2"), opts.get("--mac", "02:00:00:aa:bb:cc"), opts.get("--giaddr", "10.99.0.1")
        )
    sys.stderr.write(f"dhcp.py: unknown command {cmd!r} (want serve | selftest | probe)\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

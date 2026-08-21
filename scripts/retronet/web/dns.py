#!/usr/bin/env python3
"""retronet-dns — the wildcard DNS resolver of the web plane (Lane B).

Runs INSIDE the gateway CT (951, 10.99.0.2). It answers EVERY A query with one
address — the gateway itself (default 10.99.0.2) — so a bridged station whose
DHCP-supplied DNS is the gateway can type any URL and reach the museum with NO
proxy configured: the name resolves to the gateway, the gateway's :80 origin
(proxy.py) serves the corpus by Host, and an un-mirrored site still resolves ->
:80 -> the period miss page (authentic). See docs/lab/retronet/WEB-PLANE-PLAN.md.

THE SECURITY PROPERTY: this program NEVER opens an outbound connection and NEVER
resolves a real address. The `serve` path answers from a single constant; it
opens no socket except its own listeners. So no name a guest types can ever
resolve to a real external IP — which reinforces containment: the retronet has
no route off its /24, and now no name can point off it either. (The `query`
subcommand is a test client and is never used by the service.)

Wire behaviour, kept deliberately small and robust:
  * A/IN query      -> one A record = the answer IP, TTL from config, AA=1.
  * AAAA (or any
    other type)     -> NOERROR with no answer (NODATA), so an IPv4-only client
                       falls back to the A query instead of failing.
  * malformed packet -> dropped, no reply (never a traceback to journald).
Both UDP and TCP (RFC 1035 2-byte length prefix) are served on :53.

Config (systemd EnvironmentFile /etc/retronet/dns.env, or the environment):
  RN_DNS_LISTEN   bind address host:port   (default 10.99.0.2:53)
  RN_DNS_ANSWER   the A record every name  (default 10.99.0.2)
  RN_DNS_TTL      answer TTL, seconds       (default 300)

As-built: docs/lab/retronet/WEB-PROXY.md (addressing plane). Part of the web
plane (docs/lab/retronet/WEB-PLANE-PLAN.md).
"""

from __future__ import annotations

import socket
import socketserver
import struct
import sys

# --- defaults (every one overridable from /etc/retronet/dns.env) -------------
DEF_LISTEN = "10.99.0.2:53"
DEF_ANSWER = "10.99.0.2"
DEF_TTL = 300

# DNS constants.
TYPE_A = 1
TYPE_AAAA = 28
CLASS_IN = 1
HEADER = struct.Struct("!HHHHHH")  # id, flags, qd, an, ns, ar


def _walk_name(data: bytes, off: int) -> int:
    """Return the offset just past the QNAME at `off`. Stops at the root label
    or a compression pointer (which a question almost never uses, but we tolerate
    one rather than raising)."""
    while True:
        if off >= len(data):
            raise ValueError("truncated name")
        length = data[off]
        if length == 0:
            return off + 1
        if length & 0xC0 == 0xC0:  # compression pointer: two bytes, then done
            return off + 2
        if length & 0xC0:
            raise ValueError("bad label length")
        off += 1 + length


def build_response(query: bytes, answer_ip: str, ttl: int) -> bytes:
    """Build a wildcard reply to `query`. A/IN -> the answer IP; anything else
    -> NODATA. Raises ValueError on a packet we cannot parse (caller drops it)."""
    if len(query) < 12:
        raise ValueError("short header")
    txid, qflags, qdcount = HEADER.unpack_from(query, 0)[:3]
    if qdcount < 1:
        raise ValueError("no question")
    q_end = _walk_name(query, 12)
    if q_end + 4 > len(query):
        raise ValueError("truncated question")
    qtype, qclass = struct.unpack_from("!HH", query, q_end)
    question = query[12 : q_end + 4]

    opcode = (qflags >> 11) & 0xF
    rd = (qflags >> 8) & 0x1
    # QR=1, echo opcode, AA=1 (we are authoritative for the whole namespace),
    # echo RD, RA=1, RCODE=0 (NOERROR).
    flags = 0x8000 | (opcode << 11) | 0x0400 | (rd << 8) | 0x0080

    answer = b""
    ancount = 0
    if qclass == CLASS_IN and qtype == TYPE_A:
        rdata = socket.inet_aton(answer_ip)
        answer = b"\xc0\x0c" + struct.pack("!HHIH", TYPE_A, CLASS_IN, ttl, len(rdata)) + rdata
        ancount = 1
    return HEADER.pack(txid, flags, 1, ancount, 0, 0) + question + answer


class _Wildcard:
    """Config a server instance carries into its handlers."""

    def __init__(self, answer_ip: str, ttl: int):
        self.answer_ip = answer_ip
        self.ttl = ttl


class DNSUDPServer(socketserver.UDPServer, _Wildcard):
    # Single-threaded: a reply is pure computation (no I/O wait), so it returns
    # in microseconds and a thread-per-datagram would only invite a fork bomb
    # under a flood. allow_reuse_address so a restart rebinds immediately.
    allow_reuse_address = True

    def __init__(self, addr, answer_ip, ttl):
        _Wildcard.__init__(self, answer_ip, ttl)
        socketserver.UDPServer.__init__(self, addr, DNSUDPHandler)


class DNSTCPServer(socketserver.ThreadingTCPServer, _Wildcard):
    # TCP can block on a slow client, so thread it; daemon threads so shutdown
    # never hangs on one.
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, answer_ip, ttl):
        _Wildcard.__init__(self, answer_ip, ttl)
        socketserver.ThreadingTCPServer.__init__(self, addr, DNSTCPHandler)


class DNSUDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        try:
            reply = build_response(data, self.server.answer_ip, self.server.ttl)
        except (ValueError, OSError, IndexError):
            return  # malformed — drop, no reply
        sock.sendto(reply, self.client_address)


class DNSTCPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            head = _recv_exact(self.request, 2)
            if head is None:
                return
            (length,) = struct.unpack("!H", head)
            query = _recv_exact(self.request, length)
            if query is None:
                return
            reply = build_response(query, self.server.answer_ip, self.server.ttl)
            self.request.sendall(struct.pack("!H", len(reply)) + reply)
        except (ValueError, OSError, IndexError):
            return


def _recv_exact(sock, n: int) -> bytes | None:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


# --- test client (verify/selftest — never used by the service) ---------------
def build_query(name: str, qtype: int = TYPE_A, txid: int = 0x1234) -> bytes:
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)  # RD=1
    q = b"".join(bytes([len(lb)]) + lb.encode("idna" if not lb.isascii() else "ascii") for lb in name.split(".") if lb)
    return header + q + b"\x00" + struct.pack("!HH", qtype, CLASS_IN)


def parse_answers(data: bytes) -> list[str]:
    """Return the A-record dotted-quads in a response (for the test client)."""
    _txid, _flags, _qd, ancount = HEADER.unpack_from(data, 0)[:4]
    off = _walk_name(data, 12) + 4  # past the question
    ips = []
    for _ in range(ancount):
        off = _walk_name(data, off)
        rtype, _rclass, _ttl, rdlen = struct.unpack_from("!HHIH", data, off)
        off += 10
        if rtype == TYPE_A and rdlen == 4:
            ips.append(socket.inet_ntoa(data[off : off + 4]))
        off += rdlen
    return ips


def do_query(name: str, server: str, use_tcp: bool = False, qtype: int = TYPE_A) -> list[str]:
    host, _, port = server.partition(":")
    port = int(port or 53)
    packet = build_query(name, qtype)
    if use_tcp:
        with socket.create_connection((host, port), timeout=5) as s:
            s.sendall(struct.pack("!H", len(packet)) + packet)
            length = struct.unpack("!H", _recv_exact(s, 2))[0]
            resp = _recv_exact(s, length)
    else:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(5)
            s.sendto(packet, (host, port))
            resp, _ = s.recvfrom(4096)
    return parse_answers(resp)


def selftest() -> int:
    """In-process wire-format proof: no sockets, gate-friendly."""
    ok = True
    # A/IN -> the answer IP.
    resp = build_response(build_query("spacejam.com"), "10.99.0.2", 300)
    ips = parse_answers(resp)
    print(f"  A spacejam.com          -> {ips}")
    ok &= ips == ["10.99.0.2"]
    # A different (long) name still resolves to the one address.
    resp = build_response(build_query("www.some.deeply.nested.example"), "10.99.0.2", 60)
    ok &= parse_answers(resp) == ["10.99.0.2"]
    # AAAA -> NODATA (no answer records), so a client falls back to A.
    resp = build_response(build_query("spacejam.com", TYPE_AAAA), "10.99.0.2", 300)
    ancount = HEADER.unpack_from(resp, 0)[3]
    print(f"  AAAA spacejam.com        -> ancount={ancount} (NODATA expected)")
    ok &= ancount == 0
    # A malformed packet raises (so the handler drops it) rather than replying.
    try:
        build_response(b"\x00\x01", "10.99.0.2", 300)
        ok = False
    except ValueError:
        pass
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


# --- config + main -----------------------------------------------------------
def load_config():
    import os

    listen = os.environ.get("RN_DNS_LISTEN", DEF_LISTEN)
    answer = os.environ.get("RN_DNS_ANSWER", DEF_ANSWER).strip()
    ttl = int(os.environ.get("RN_DNS_TTL", str(DEF_TTL)))
    host, _, port = listen.strip().rpartition(":")
    return {"addr": (host or "0.0.0.0", int(port or 53)), "answer": answer, "ttl": ttl}


def serve(cfg) -> int:
    import threading

    host, port = cfg["addr"]
    socket.inet_aton(cfg["answer"])  # fail loudly on a bad answer IP
    udp = DNSUDPServer((host, port), cfg["answer"], cfg["ttl"])
    tcp = DNSTCPServer((host, port), cfg["answer"], cfg["ttl"])
    sys.stderr.write(
        f"retronet-dns: listening on {host}:{port} (udp+tcp)  every A -> {cfg['answer']}  ttl={cfg['ttl']}\n"
    )
    t = threading.Thread(target=udp.serve_forever, name="dns-udp", daemon=True)
    t.start()
    try:
        tcp.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        udp.shutdown()
        udp.server_close()
        tcp.server_close()
    return 0


def main(argv) -> int:
    cmd = argv[0] if argv else "serve"
    if cmd == "serve":
        return serve(load_config())
    if cmd == "selftest":
        return selftest()
    if cmd == "query":
        if len(argv) < 2:
            sys.stderr.write("usage: dns.py query <name> [--server host:port] [--tcp] [--type AAAA]\n")
            return 2
        name = argv[1]
        server = DEF_LISTEN
        use_tcp = "--tcp" in argv
        qtype = TYPE_AAAA if "--type" in argv and "AAAA" in argv else TYPE_A
        if "--server" in argv:
            server = argv[argv.index("--server") + 1]
        ips = do_query(name, server, use_tcp, qtype)
        proto = "tcp" if use_tcp else "udp"
        print(f"{name} @ {server} ({proto}) -> {ips or '(no A record)'}")
        return 0 if ips or qtype != TYPE_A else 1
    sys.stderr.write(f"dns.py: unknown command {cmd!r} (want serve | query | selftest)\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

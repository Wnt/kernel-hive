#!/usr/bin/env python3
"""win2000-icq-nudge — keep the win2000 ICQ persona reconnecting after a wake.

The win2000 sibling of win98se-icq-nudge.py; see that file and
docs/lab/retronet/ICQ-STATION.md / ICQ-STATION-win2000.md for the full story.

THE PROBLEM. ICQ 2000b does not poll the server; it relies on the server pinging
it. After `loadvm golden` (a `labctl reset`, or the launcher's boot) the guest is
restored onto its golden BOS socket, which the gateway timed out and dropped long
ago. Neither side speaks: the guest thinks it is connected, the gateway shows the
persona offline, and ICQ never notices the half-open zombie. The station would
wake OFFLINE and never greet.

THE NUDGE. Elicit the gateway's own RST for that stale socket: send the guest a
spoofed TCP ACK as if from the gateway (`10.99.0.2:5190 -> 10.99.0.11:<golden
port>`) with a bad seq. The guest challenge-ACKs the *real* gateway, which has no
socket for that 4-tuple and RSTs it; ICQ sees the drop and reconnects on a fresh
port with a clean sign-on — and the bot greets ~30 s later.

WHY IT IS SAFE TO FIRE REPEATEDLY. It targets ONLY the golden's fixed ICQ port
(`GOLDEN_ICQ_PORT`, the port the guest is always restored onto). After a reconnect
the live session is on a *different, higher* ephemeral port, so the nudge no longer
matches anything and is inert — it can never reset a healthy connection. It only
ever un-sticks the golden zombie. If the golden is ever re-captured, update
GOLDEN_ICQ_PORT to the port the persona shows at capture time (see
ICQ-STATION-win2000.md).

Run as root (raw socket). Driven by win2000-icq-nudge.timer every few seconds;
skips when the guest is paused/absent so it never spams a frozen guest.
"""

import json
import os
import socket
import struct
import sys

GATEWAY = os.environ.get("RN_ICQ_GATEWAY", "10.99.0.2")
GATEWAY_PORT = int(os.environ.get("RN_ICQ_GATEWAY_PORT", "5190"))
GUEST = os.environ.get("RN_ICQ_GUEST", "10.99.0.11")
GOLDEN_ICQ_PORT = int(os.environ.get("RN_ICQ_GOLDEN_PORT", "1031"))
QMP = os.environ.get("RN_ICQ_QMP", "/data/vms/streamhost/stations/win2000/qmp.sock")


def guest_running() -> bool:
    """True only if win2000's QEMU is up and NOT paused (else nudging is pointless)."""
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect(QMP)
        buf = b""

        def line() -> dict:
            nonlocal buf
            while b"\n" not in buf:
                buf += s.recv(4096)
            ln, buf = buf.split(b"\n", 1)
            return json.loads(ln)

        line()  # greeting
        s.sendall(b'{"execute":"qmp_capabilities"}\n')
        line()
        s.sendall(b'{"execute":"query-status"}\n')
        st = line().get("return", {})
        s.close()
        return bool(st.get("running"))
    except (OSError, ValueError):
        return False


def _cksum(d: bytes) -> int:
    if len(d) % 2:
        d += b"\0"
    s = sum(struct.unpack(f"!{len(d) // 2}H", d))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF


def _tcp_ack(sport: int, dport: int, seq: int) -> bytes:
    off = 5 << 4
    hdr = struct.pack("!HHLLBBHHH", sport, dport, seq, seq, off, 0x10, 65535, 0, 0)
    pseudo = socket.inet_aton(GATEWAY) + socket.inet_aton(GUEST) + struct.pack("!BBH", 0, 6, len(hdr))
    c = _cksum(pseudo + hdr)
    return struct.pack("!HHLLBBHHH", sport, dport, seq, seq, off, 0x10, 65535, c, 0)


def _ip(payload: bytes) -> bytes:
    tot = 20 + len(payload)
    fields = (0x45, 0, tot, 0x1234, 0, 64, 6, 0, socket.inet_aton(GATEWAY), socket.inet_aton(GUEST))
    hdr = struct.pack("!BBHHHBBH4s4s", *fields)
    c = _cksum(hdr)
    hdr = struct.pack("!BBHHHBBH4s4s", *fields[:7], c, fields[8], fields[9])
    return hdr + payload


def nudge() -> None:
    raw = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    # a spread of seqs so at least one is out-of-window and elicits the challenge-ACK
    for seq in (1, 1000, 100000, 0x40000000, 0x80000000):
        raw.sendto(_ip(_tcp_ack(GATEWAY_PORT, GOLDEN_ICQ_PORT, seq)), (GUEST, 0))
    raw.close()


def main() -> int:
    if not guest_running():
        return 0
    nudge()
    return 0


if __name__ == "__main__":
    sys.exit(main())

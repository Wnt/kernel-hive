#!/usr/bin/env python3
"""nt4-icq-nudge — keep the nt4 ICQ persona reconnecting after a wake.

THE PROBLEM. ICQ 2000b does not poll the server; it relies on the server pinging
it. After a wake the guest is on a BOS socket the gateway timed out and dropped:
the guest thinks it is connected, the gateway shows the persona offline, and ICQ
never notices the half-open zombie. Two ways in:
  * `loadvm golden` (a `labctl reset`, or the launcher's boot) restores the
    golden's stale socket outright; and
  * the daemon resumes an idle-paused guest with `cont`, not `loadvm`, so after a
    reconnect the guest drifts to a new ephemeral port — the next idle-drop
    strands *that* one.
Either way the station wakes OFFLINE and never greets.

THE NUDGE. Elicit the gateway's own RST for the stale socket: send the guest a
spoofed TCP ACK as if from the gateway (`10.99.0.2:5190 -> 10.99.0.12:<port>`)
with a bad seq. The guest challenge-ACKs the *real* gateway, which has no socket
for that 4-tuple and RSTs it; ICQ sees the drop and reconnects on a fresh port
with a clean sign-on — and the bot greets ~30 s later.

PORT-ROBUST + SAFE. It records the persona's live remote port whenever the
gateway shows it ONLINE, and only ever fires when the gateway shows it OFFLINE —
targeting that last-known (now-stale) port. So it always hits the real zombie
whatever it drifted to, and can never reset a healthy connection (there is none
to reset while offline). Seeds with the golden's port for the first wake.

Run as root (raw socket + `pct exec` to read the gateway). Driven by
nt4-icq-nudge.timer; a no-op unless the guest is running AND offline.
"""

import contextlib
import json
import os
import socket
import struct
import subprocess
import sys

GATEWAY = os.environ.get("RN_ICQ_GATEWAY", "10.99.0.2")
GATEWAY_PORT = int(os.environ.get("RN_ICQ_GATEWAY_PORT", "5190"))
GUEST = os.environ.get("RN_ICQ_GUEST", "10.99.0.12")
PERSONA = os.environ.get("RN_ICQ_PERSONA_UIN", "40000")
GOLDEN_ICQ_PORT = int(os.environ.get("RN_ICQ_GOLDEN_PORT", "1035"))
CT = os.environ.get("RN_ICQ_CT", "951")
QMP = os.environ.get("RN_ICQ_QMP", "/data/vms/streamhost/stations/nt4/qmp.sock")
PORTFILE = os.environ.get("RN_ICQ_PORTFILE", "/run/nt4-icq-port")


def persona_port() -> int | None:
    """Return the persona's live remote port from the gateway, or None if offline."""
    code = (
        "import urllib.request,json;"
        'd=json.loads(urllib.request.urlopen("http://127.0.0.1:8080/session").read());'
        f'print(next((s["instances"][0]["remote_port"] for s in d["sessions"] if s["screen_name"]=="{PERSONA}"),""))'
    )
    try:
        out = subprocess.run(
            ["pct", "exec", CT, "--", "python3", "-c", code],
            capture_output=True,
            text=True,
            timeout=8,
        ).stdout.strip()
        return int(out) if out else None
    except (subprocess.SubprocessError, ValueError):
        return None


def guest_running() -> bool:
    """True only if nt4's QEMU is up and NOT paused (else nudging is pointless)."""
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


def stale_port() -> int:
    try:
        with open(PORTFILE) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return GOLDEN_ICQ_PORT


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


def nudge(dport: int) -> None:
    raw = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    # a spread of seqs so at least one is out-of-window and elicits the challenge-ACK
    for seq in (1, 1000, 100000, 0x40000000, 0x80000000):
        raw.sendto(_ip(_tcp_ack(GATEWAY_PORT, dport, seq)), (GUEST, 0))
    raw.close()


def main() -> int:
    # Cheap local QMP check FIRST: while the station is idle-paused (most of the
    # time) do nothing and skip the costly `pct exec` gateway read entirely, so
    # the healer is idle when the guest is.
    if not guest_running():
        return 0
    port = persona_port()
    if port is not None:
        # ONLINE — remember the live port for the next wake, and leave it alone.
        with contextlib.suppress(OSError), open(PORTFILE, "w") as f:
            f.write(str(port))
        return 0
    # OFFLINE + running — un-stick the stale socket.
    nudge(stale_port())
    return 0


if __name__ == "__main__":
    sys.exit(main())

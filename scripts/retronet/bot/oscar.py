"""Minimal OSCAR (ICQ/AIM) client — enough protocol to be a retronet chatbot.

WHY hand-rolled: the retronet bot needs four verbs — sign on as a UIN, watch a
buddy's presence, receive an IM, send an IM — and no maintained Python OSCAR
library exists. A dependency-free module is also what the rest of this repo's
host tooling looks like (stdlib only, `ssh lab` deploys a file, not a venv).

Wire model (OSCAR, as served by open-oscar-server, ex-"Retro AIM Server"):

    FLAP frame   0x2A | channel u8 | seq u16 | len u16 | payload
    SNAC header  family u16 | subtype u16 | flags u16 | request-id u32
    TLV          type u16 | len u16 | value

Sign-on is BUCP (family 0x17): challenge -> md5 -> login response carrying the
BOS address and an auth cookie; then a second connection to BOS presents the
cookie. open-oscar-server >= 0.19 multiplexes every service onto ONE port, so
the BOS address is usually the same host:port the client just dialled.

The one ordering rule that is not obvious and that costs a whole debugging
session if you get it wrong: BuddyAddBuddies (0x03,0x04) must be sent BEFORE
ClientOnline (0x01,0x02). The server suppresses arrival notifications until
sign-on completes, and only replays them at ClientOnline if the contact list was
already initialised. Add buddies after ClientOnline and an already-online
persona stays invisible until it signs on again.
"""

from __future__ import annotations

import contextlib
import hashlib
import logging
import os
import random
import re
import select
import socket
import struct
import threading
import time

LOG = logging.getLogger("retronet.oscar")

FLAP_SIGNON, FLAP_DATA, FLAP_ERROR, FLAP_SIGNOFF, FLAP_KEEPALIVE = 1, 2, 3, 4, 5

OSERVICE, LOCATE, BUDDY, ICBM, BUCP = 0x0001, 0x0002, 0x0003, 0x0004, 0x0017

AIM_MD5_STRING = b"AOL Instant Messenger (SM)"
_HTML_TAG = re.compile(r"<[^>]+>")


class OscarError(Exception):
    """Sign-on refused, or the peer hung up mid-handshake."""


def tlv(t: int, v: bytes) -> bytes:
    return struct.pack(">HH", t, len(v)) + v


def tlv_str(t: int, s: str) -> bytes:
    return tlv(t, s.encode("utf-8"))


def tlv_u16(t: int, v: int) -> bytes:
    return tlv(t, struct.pack(">H", v))


def tlv_u32(t: int, v: int) -> bytes:
    return tlv(t, struct.pack(">I", v))


def lnts(s: str) -> bytes:
    """uint8-length-prefixed string — how OSCAR carries screen names."""
    b = s.encode("utf-8")
    return bytes([len(b)]) + b


def parse_tlvs(buf: bytes, off: int = 0) -> list[tuple[int, bytes]]:
    out: list[tuple[int, bytes]] = []
    while off + 4 <= len(buf):
        t, ln = struct.unpack_from(">HH", buf, off)
        off += 4
        out.append((t, buf[off : off + ln]))
        off += ln
    return out


def find_tlv(tlvs: list[tuple[int, bytes]], t: int) -> bytes | None:
    for tt, v in tlvs:
        if tt == t:
            return v
    return None


def decode_msg_text(charset: int, raw: bytes) -> str:
    if charset == 0x0002:
        return raw.decode("utf-16-be", "replace")
    return raw.decode("cp1252", "replace")


def strip_html(s: str) -> str:
    """AIM-era clients wrap text in <HTML><BODY>. Personas should not see markup."""
    s = re.sub(r"<[Bb][Rr]\s*/?>", "\n", s)
    s = _HTML_TAG.sub("", s)
    for ent, ch in (("&lt;", "<"), ("&gt;", ">"), ("&quot;", '"'), ("&nbsp;", " "), ("&amp;", "&")):
        s = s.replace(ent, ch)
    return s.strip()


class FlapConn:
    """One FLAP connection. Sends are serialised; reads are polled by one thread."""

    def __init__(self, host: str, port: int, timeout: float = 20.0) -> None:
        self.sock = socket.create_connection((host, port), timeout)
        self.sock.settimeout(timeout)
        self.seq = random.randint(0, 0x7FFF)
        self._send_lock = threading.Lock()
        self.peer = f"{host}:{port}"

    def close(self) -> None:
        with contextlib.suppress(OSError):
            self.sock.close()

    def send_flap(self, channel: int, payload: bytes = b"") -> None:
        with self._send_lock:
            frame = struct.pack(">BBHH", 0x2A, channel, self.seq, len(payload)) + payload
            self.seq = (self.seq + 1) & 0xFFFF
            self.sock.sendall(frame)

    def send_snac(self, fam: int, sub: int, body: bytes = b"", reqid: int | None = None) -> None:
        if reqid is None:
            reqid = random.randint(1, 0x7FFFFFFF)
        self.send_flap(FLAP_DATA, struct.pack(">HHHI", fam, sub, 0, reqid) + body)

    def _recv_exact(self, n: int) -> bytes:
        chunks = []
        got = 0
        while got < n:
            b = self.sock.recv(n - got)
            if not b:
                raise OscarError(f"{self.peer}: connection closed mid-frame")
            chunks.append(b)
            got += len(b)
        return b"".join(chunks)

    def recv_flap(self) -> tuple[int, bytes]:
        hdr = self._recv_exact(6)
        if hdr[0] != 0x2A:
            raise OscarError(f"{self.peer}: bad FLAP marker {hdr[0]:#04x}")
        _, channel, _seq, ln = struct.unpack(">BBHH", hdr)
        return channel, self._recv_exact(ln) if ln else b""

    def poll_flap(self, timeout: float) -> tuple[int, bytes] | None:
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return None
        return self.recv_flap()

    def wait_snac(self, fam: int, subs: tuple[int, ...], timeout: float = 20.0) -> bytes:
        return self.wait_snac_sub(fam, subs, timeout)[1]

    def wait_snac_sub(self, fam: int, subs: tuple[int, ...], timeout: float = 20.0) -> tuple[int, bytes]:
        """Read frames until one of `subs` in `fam` arrives; returns (subtype, body)."""
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise OscarError(f"{self.peer}: timeout waiting for SNAC {fam:#06x}/{subs}")
            got = self.poll_flap(left)
            if got is None:
                continue
            channel, payload = got
            if channel == FLAP_SIGNOFF:
                raise OscarError(f"{self.peer}: server closed: {parse_tlvs(payload)}")
            if channel != FLAP_DATA or len(payload) < 10:
                continue
            f, s, flags, _ = struct.unpack_from(">HHHI", payload, 0)
            body = payload[10:]
            if flags & 0x8000 and len(body) >= 2:  # optional SNAC version block
                skip = struct.unpack_from(">H", body, 0)[0]
                body = body[2 + skip :]
            if f == fam and s in subs:
                return s, body


def _md5(data: bytes) -> bytes:
    return hashlib.md5(data, usedforsecurity=False).digest()


def _password_hash(password: str, authkey: bytes) -> bytes:
    """md5(authkey || md5(password) || AIM_MD5_STRING) — the AIM 4.8+ "strong" hash.

    Protocol-mandated MD5; open-oscar-server stores both this and the older
    "weak" md5(authkey || password || AIM_MD5_STRING) and accepts either.
    """
    return _md5(authkey + _md5(password.encode("utf-8")) + AIM_MD5_STRING)


class OscarClient:
    """Sign on, watch presence, exchange channel-1 IMs. Callbacks run on the read thread."""

    def __init__(
        self,
        host: str,
        port: int,
        screen_name: str,
        password: str,
        buddies: list[str] | None = None,
        bos_host_override: str | None = None,
        client_name: str = "ICQ Inc. - Pentium(R)-based ICQ 2000b",
    ) -> None:
        self.host, self.port = host, port
        self.screen_name, self.password = screen_name, password
        self.buddies = list(buddies or [])
        self.bos_host_override = bos_host_override
        self.client_name = client_name
        self.bos: FlapConn | None = None
        self.on_message = None  # (sender:str, text:str) -> None
        self.on_buddy_online = None  # (sender:str) -> None
        self.on_buddy_offline = None  # (sender:str) -> None
        self.on_ready = None  # () -> None
        self._stop = threading.Event()

    # ---------------------------------------------------------------- sign-on

    def _bucp_login(self) -> tuple[str, int, bytes]:
        auth = FlapConn(self.host, self.port)
        try:
            channel, _ = auth.recv_flap()
            if channel != FLAP_SIGNON:
                raise OscarError(f"expected FLAP signon, got channel {channel}")
            auth.send_flap(FLAP_SIGNON, struct.pack(">I", 1))
            auth.send_snac(BUCP, 0x06, tlv_str(0x0001, self.screen_name) + tlv(0x004B, b"") + tlv(0x005A, b""))
            sub, body = auth.wait_snac_sub(BUCP, (0x0007, 0x0003))
            if sub == 0x0003:  # login response instead of a challenge = refusal
                raise OscarError(f"challenge refused: {[hex(t) for t, _ in parse_tlvs(body)]}")
            keylen = struct.unpack_from(">H", body, 0)[0]
            if keylen == 0 or keylen + 2 > len(body):
                raise OscarError(f"challenge response malformed ({keylen=}, {len(body)=})")
            authkey = body[2 : 2 + keylen]

            login = (
                tlv_str(0x0001, self.screen_name)
                + tlv(0x0025, _password_hash(self.password, authkey))
                + tlv_str(0x0003, self.client_name)
                + tlv_u16(0x0016, 0x010A)
                + tlv_u16(0x0017, 0x0005)
                + tlv_u16(0x0018, 0x0000)
                + tlv_u16(0x0019, 0x0000)
                + tlv_u16(0x001A, 0x0BDC)
                + tlv_u32(0x0014, 0x0000010A)
                + tlv_str(0x000F, "en")
                + tlv_str(0x000E, "us")
                + tlv(0x004A, b"\x01")
            )
            auth.send_snac(BUCP, 0x0002, login)
            resp = parse_tlvs(auth.wait_snac(BUCP, (0x0003,)))
            err = find_tlv(resp, 0x0008)
            if err is not None:
                raise OscarError(f"sign-on refused: error subcode {struct.unpack('>H', err)[0]:#06x}")
            bos = find_tlv(resp, 0x0005)
            cookie = find_tlv(resp, 0x0006)
            if bos is None or cookie is None:
                raise OscarError(f"sign-on response missing BOS/cookie: {[t for t, _ in resp]}")
            bos_s = bos.decode("utf-8")
            bhost, _, bport = bos_s.partition(":")
            if self.bos_host_override:
                LOG.info("BOS advertised %s, overridden to %s", bos_s, self.bos_host_override)
                bhost = self.bos_host_override
            return bhost, int(bport or 5190), cookie
        finally:
            auth.close()

    def _bos_handshake(self, bhost: str, bport: int, cookie: bytes) -> None:
        bos = FlapConn(bhost, bport)
        self.bos = bos
        channel, _ = bos.recv_flap()
        if channel != FLAP_SIGNON:
            raise OscarError(f"BOS: expected FLAP signon, got channel {channel}")
        bos.send_flap(FLAP_SIGNON, struct.pack(">I", 1) + tlv(0x0006, cookie))

        host_online = bos.wait_snac(OSERVICE, (0x0003,))
        fams = list(struct.unpack(f">{len(host_online) // 2}H", host_online[: len(host_online) // 2 * 2]))
        LOG.debug("BOS host online, families: %s", [hex(f) for f in fams])

        # Claim every family the host announced. OService and Feedbag get v3
        # (the AIM 5.x baseline); everything else v1, which every server accepts.
        claimed = {OSERVICE: 3, 0x0013: 3}
        versions = b"".join(struct.pack(">HH", f, claimed.get(f, 1)) for f in fams)
        bos.send_snac(OSERVICE, 0x0017, versions)
        bos.wait_snac(OSERVICE, (0x0018,))

        bos.send_snac(OSERVICE, 0x0006)
        bos.wait_snac(OSERVICE, (0x0007,))
        bos.send_snac(OSERVICE, 0x0008, struct.pack(">HHHHH", 1, 2, 3, 4, 5))

        # ICBM parameters: flags 0x0B = channel msgs + missed calls + typing events.
        bos.send_snac(ICBM, 0x0002, struct.pack(">HIHHHI", 0, 0x0000000B, 8000, 999, 999, 0))
        bos.send_snac(OSERVICE, 0x001E, tlv_u32(0x0006, 0x00000000))

        if self.buddies:
            bos.send_snac(BUDDY, 0x0004, b"".join(lnts(b) for b in self.buddies))
        bos.send_snac(OSERVICE, 0x0002)  # ClientOnline — must come AFTER AddBuddies
        LOG.info("signed on as %s at %s (buddies: %s)", self.screen_name, bos.peer, self.buddies or "none")

    def connect(self) -> None:
        bhost, bport, cookie = self._bucp_login()
        self._bos_handshake(bhost, bport, cookie)
        if self.on_ready:
            self.on_ready()

    # --------------------------------------------------------------- sending

    def send_im(self, target: str, text: str) -> None:
        if not self.bos:
            raise OscarError("send_im before connect()")
        payload = text.encode("cp1252", "replace")
        msg = tlv(0x0501, b"\x01") + tlv(0x0101, struct.pack(">HH", 0x0000, 0x0000) + payload)
        body = (
            os.urandom(8)
            + struct.pack(">H", 0x0001)
            + lnts(target)
            + tlv(0x0002, msg)
            + tlv(0x0003, b"")  # request host ack — turns "sent" into a fact in the log
        )
        self.bos.send_snac(ICBM, 0x0006, body)
        LOG.info("-> %s: %s", target, text)

    def add_buddy(self, screen_name: str) -> None:
        if not self.bos:
            raise OscarError("add_buddy before connect()")
        self.bos.send_snac(BUDDY, 0x0004, lnts(screen_name))

    # -------------------------------------------------------------- receiving

    @staticmethod
    def _parse_incoming(body: bytes) -> tuple[str, str] | None:
        off = 8
        channel = struct.unpack_from(">H", body, off)[0]
        off += 2
        nlen = body[off]
        sender = body[off + 1 : off + 1 + nlen].decode("utf-8", "replace")
        off += 1 + nlen
        off += 2  # warning level
        ntlv = struct.unpack_from(">H", body, off)[0]
        off += 2
        for _ in range(ntlv):  # fixed user-info block
            _t, ln = struct.unpack_from(">HH", body, off)
            off += 4 + ln
        rest = parse_tlvs(body, off)

        if channel == 0x0001:
            blob = find_tlv(rest, 0x0002)
            if blob is None:
                return None
            for t, v in parse_tlvs(blob):
                if t == 0x0101 and len(v) >= 4:
                    charset = struct.unpack_from(">H", v, 0)[0]
                    return sender, strip_html(decode_msg_text(charset, v[4:]))
            return None
        if channel == 0x0004:  # old-style ICQ message, little-endian body
            blob = find_tlv(rest, 0x0005)
            if blob is None or len(blob) < 8:
                return None
            msg_type = blob[4]
            if msg_type != 0x01:
                return None
            mlen = struct.unpack_from("<H", blob, 6)[0]
            raw = blob[8 : 8 + mlen].rstrip(b"\x00")
            return sender, raw.decode("cp1252", "replace")
        return None

    def _dispatch(self, fam: int, sub: int, body: bytes) -> None:
        if fam == BUDDY and sub == 0x000B:
            nlen = body[0]
            sn = body[1 : 1 + nlen].decode("utf-8", "replace")
            LOG.info("presence: %s ONLINE", sn)
            if self.on_buddy_online:
                self.on_buddy_online(sn)
        elif fam == BUDDY and sub == 0x000C:
            nlen = body[0]
            sn = body[1 : 1 + nlen].decode("utf-8", "replace")
            LOG.info("presence: %s offline", sn)
            if self.on_buddy_offline:
                self.on_buddy_offline(sn)
        elif fam == ICBM and sub == 0x0007:
            got = self._parse_incoming(body)
            if got and got[1]:
                LOG.info("<- %s: %s", got[0], got[1])
                if self.on_message:
                    self.on_message(*got)
        elif fam == BUDDY and sub == 0x000A:
            # The server refused to watch these contacts. For ICQ that means the
            # contact has "authorization required" set (open-oscar-server
            # defaults icq_permissions_authRequired=1 on freshly created
            # accounts) — without provisioning it off, presence never arrives
            # and the greeter never fires. See docs/lab/retronet/BOT.md.
            names = []
            off = 0
            while off < len(body):
                ln = body[off]
                names.append(body[off + 1 : off + 1 + ln].decode("utf-8", "replace"))
                off += 1 + ln
            LOG.error("BUDDY LIST REJECTED for %s — contact requires authorization; presence will NOT arrive", names)
        elif fam == ICBM and sub == 0x000C:
            LOG.debug("ICBM host ack")
        elif sub == 0x0001:
            LOG.warning("SNAC error from family %#06x: %s", fam, body.hex())

    def run_forever(self, keepalive: float = 60.0) -> None:
        """Read loop. Returns when stop()/close() is called; raises if the link drops."""
        last_ka = time.monotonic()
        while not self._stop.is_set():
            bos = self.bos
            if bos is None:
                return
            try:
                got = bos.poll_flap(1.0)
            except (OSError, ValueError):
                if self._stop.is_set():
                    return  # our own close() pulled the socket out from under select
                raise
            now = time.monotonic()
            if now - last_ka >= keepalive:
                bos.send_flap(FLAP_KEEPALIVE)
                last_ka = now
            if got is None:
                continue
            channel, payload = got
            if channel == FLAP_SIGNOFF:
                raise OscarError(f"server signed us off: {parse_tlvs(payload)}")
            if channel != FLAP_DATA or len(payload) < 10:
                continue
            fam, sub, flags, _ = struct.unpack_from(">HHHI", payload, 0)
            body = payload[10:]
            if flags & 0x8000 and len(body) >= 2:
                skip = struct.unpack_from(">H", body, 0)[0]
                body = body[2 + skip :]
            try:
                self._dispatch(fam, sub, body)
            except Exception:  # a malformed SNAC must not kill the bot
                LOG.exception("handler failed for SNAC %#06x/%#06x", fam, sub)

    def stop(self) -> None:
        self._stop.set()

    def reset(self) -> None:
        """Re-arm after close() so the same client object can reconnect."""
        self._stop.clear()

    def close(self) -> None:
        self._stop.set()
        if self.bos:
            with contextlib.suppress(OSError):
                self.bos.send_flap(FLAP_SIGNOFF)
            self.bos.close()
            self.bos = None

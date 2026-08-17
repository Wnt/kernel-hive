#!/usr/bin/env python3
"""QMP + framebuffer helpers for the guest input-wedge repro.

Deliberately dependency-free and streamhost-free: keys go straight into QEMU, so
anything reproduced with this is the GUEST or the emulator, never the streaming
plane. That makes it the discriminator to run FIRST when an exhibit "freezes".
"""

import contextlib
import hashlib
import json
import os
import socket
import time


class Qmp:
    """Minimal synchronous QMP client (events are skipped, not queued)."""

    def __init__(self, path):
        self.path = path
        self.work = os.path.dirname(path)
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(30)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.f.readline()  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, execute, **args):
        msg = {"execute": execute}
        if args:
            msg["arguments"] = args
        self.f.write((json.dumps(msg) + "\n").encode())
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise RuntimeError("qmp connection closed")
            d = json.loads(line)
            if "event" in d:
                continue
            if "error" in d:
                raise RuntimeError(d["error"]["desc"])
            return d.get("return")

    def hmp(self, line):
        return self.cmd("human-monitor-command", **{"command-line": line})

    # ---- input -------------------------------------------------------------
    def key(self, qcode, down):
        """One key EDGE. Separate down/up is the point: QMP `send-key` can only
        send a complete chord, so it can never express a HELD key, which is how
        games are actually played and where the wedge lives."""
        self.cmd(
            "input-send-event",
            events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}],
        )

    def tap(self, qcode, hold_ms=80):
        self.key(qcode, True)
        time.sleep(hold_ms / 1000.0)
        self.key(qcode, False)

    def chord(self, mods, qcode, hold_ms=120):
        for m in mods:
            self.key(m, True)
        self.key(qcode, True)
        time.sleep(hold_ms / 1000.0)
        self.key(qcode, False)
        for m in reversed(mods):
            self.key(m, False)

    # ---- framebuffer -------------------------------------------------------
    def fb_hash(self):
        p = os.path.join(self.work, ".probe-shot.ppm")
        with contextlib.suppress(OSError):
            os.unlink(p)
        self.cmd("screendump", filename=p)
        for _ in range(60):
            if os.path.exists(p) and os.path.getsize(p) > 0:
                break
            time.sleep(0.05)
        with open(p, "rb") as fh:
            return hashlib.md5(fh.read()).hexdigest()

    def fb_region_hash(self, x, y, w, h):
        """Hash ONE RECTANGLE of the framebuffer.

        Whole-frame hashing is a poor liveness signal for a game: it changes
        when any pixel does, and it goes static both when the app is wedged AND
        when the app is simply idle (a skier who has stopped, a crash screen).
        Hashing the HUD instead reads the game's OWN COUNTERS — SkiFree's
        Dist/Speed advance whenever its logic is running — which separates
        "wedged" from "nothing is moving on screen".
        """
        p = os.path.join(self.work, ".probe-shot.ppm")
        with contextlib.suppress(OSError):
            os.unlink(p)
        self.cmd("screendump", filename=p)
        for _ in range(60):
            if os.path.exists(p) and os.path.getsize(p) > 0:
                break
            time.sleep(0.05)
        with open(p, "rb") as fh:
            data = fh.read()
        # P6 header: magic, width, height, maxval — each possibly separated by
        # arbitrary whitespace, with '#' comment lines allowed between them.
        pos, fields = 0, []
        while len(fields) < 4:
            while pos < len(data) and data[pos : pos + 1].isspace():
                pos += 1
            if data[pos : pos + 1] == b"#":
                while pos < len(data) and data[pos : pos + 1] != b"\n":
                    pos += 1
                continue
            start = pos
            while pos < len(data) and not data[pos : pos + 1].isspace():
                pos += 1
            fields.append(data[start:pos])
        pos += 1  # single whitespace byte after maxval
        (
            fw,
            fh_,
        ) = int(fields[1]), int(fields[2])
        px = data[pos:]
        x2, y2 = min(x + w, fw), min(y + h, fh_)
        out = bytearray()
        for row in range(max(0, y), max(0, y2)):
            off = (row * fw + max(0, x)) * 3
            out += px[off : off + (x2 - max(0, x)) * 3]
        return hashlib.md5(bytes(out)).hexdigest()

    def running(self):
        return bool(self.cmd("query-status").get("running"))

    def loadvm(self, snap, settle=2.0):
        self.cmd("stop")
        self.hmp(f"loadvm {snap}")
        self.cmd("cont")
        time.sleep(settle)


def kbd_alive(q, settle=2.0):
    """Is the guest still accepting keyboard input?

    THIS, NOT FRAMEBUFFER MOTION, IS THE MEASUREMENT. A static screen is
    ambiguous — a game can legitimately stop animating, and reading that as "the
    freeze" sent the first pass of this investigation down the wrong path.

    Ctrl+Esc is the probe because Windows 3.x handles it BELOW the focused
    application (it opens the Task List), so it repaints even when a 16-bit app
    is wedged. Framebuffer changes => input alive. It does not => input is dead.
    Leaves the scene as it found it by closing the Task List again.
    """
    before = q.fb_hash()
    q.chord(["ctrl"], "esc")
    time.sleep(settle)
    if q.fb_hash() != before:
        q.tap("esc")
        time.sleep(0.8)
        return True
    return False


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)

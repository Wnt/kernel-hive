"""The two host-native planes, as one small client library.

Split out of nextstep-scene.py when that script reached its size cap. This half
is the PLUMBING -- the mamectl/1 socket, the IFB1 mapping, the NeXT scancode
tables, the cursor locator and the pointer/keyboard primitives -- and it is
useful on its own to anyone debugging the station by hand. The scene script is
the POLICY: which buttons to press, in what order, and what counts as done.

Nothing here knows what the acceptance scene looks like.
"""

from __future__ import annotations

import os
import subprocess
import time

import numpy as np

W, H = 1120, 832
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
NSTEL = os.path.join(REPO, "scripts", "build-guests", "nextstep-nstel.py")

# The NeXT arrow, as (dx, dy, white?) samples: a black glyph inside a white
# outline. Only pure 0 and pure 255 are sampled, so the template is exact on the
# 2 bpp mono machine AND on the 16 bpp colour one, over any background.
# fmt: off
SIG = [
    (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 0), (2, 1, 1), (0, 2, 1),
    (1, 2, 0), (2, 2, 0), (3, 2, 1), (0, 3, 1), (1, 3, 0), (2, 3, 0),
    (3, 3, 0), (4, 3, 1), (0, 4, 1), (1, 4, 0), (2, 4, 0), (3, 4, 0),
    (4, 4, 0), (5, 4, 1), (0, 5, 1), (1, 5, 0), (2, 5, 0), (3, 5, 0),
    (4, 5, 0), (5, 5, 0), (6, 5, 1), (0, 6, 1), (1, 6, 0), (2, 6, 0),
    (3, 6, 0), (4, 6, 0), (5, 6, 0), (6, 6, 0), (7, 6, 1), (0, 7, 1),
    (1, 7, 0), (2, 7, 0), (3, 7, 0), (4, 7, 0), (5, 7, 0), (6, 7, 0),
    (7, 7, 0), (8, 7, 1), (0, 8, 1), (1, 8, 0), (2, 8, 0), (3, 8, 0),
    (4, 8, 0), (5, 8, 0), (6, 8, 0), (7, 8, 0), (8, 8, 0), (9, 8, 1),
    (0, 9, 1), (1, 9, 0), (2, 9, 0), (3, 9, 0), (4, 9, 0), (5, 9, 0),
    (6, 9, 1), (7, 9, 1), (8, 9, 1), (9, 9, 1), (10, 9, 1), (0, 10, 1),
    (1, 10, 0), (2, 10, 0), (3, 10, 1), (4, 10, 0), (5, 10, 0), (6, 10, 1),
    (0, 11, 1), (1, 11, 0), (2, 11, 1), (4, 11, 1), (5, 11, 0), (6, 11, 0),
    (7, 11, 1), (0, 12, 1), (1, 12, 1), (4, 12, 1), (5, 12, 0), (6, 12, 0),
    (7, 12, 1), (0, 13, 1), (5, 13, 1), (6, 13, 0), (7, 13, 0), (8, 13, 1),
    (5, 14, 1), (6, 14, 0), (7, 14, 0), (8, 14, 1), (6, 15, 1), (7, 15, 1),
]
# fmt: on

# NeXT KMS scancodes (src/includes/kms.h). Same table as the station keymap.
NEXT = {
    "a": 0x39,
    "b": 0x35,
    "c": 0x33,
    "d": 0x3B,
    "e": 0x44,
    "f": 0x3C,
    "g": 0x3D,
    "h": 0x40,
    "i": 0x06,
    "j": 0x3F,
    "k": 0x3E,
    "l": 0x2D,
    "m": 0x36,
    "n": 0x37,
    "o": 0x07,
    "p": 0x08,
    "q": 0x42,
    "r": 0x45,
    "s": 0x3A,
    "t": 0x48,
    "u": 0x46,
    "v": 0x34,
    "w": 0x43,
    "x": 0x32,
    "y": 0x47,
    "z": 0x31,
    "0": 0x20,
    "1": 0x4A,
    "2": 0x4B,
    "3": 0x4C,
    "4": 0x4D,
    "5": 0x50,
    "6": 0x4F,
    "7": 0x4E,
    "8": 0x1E,
    "9": 0x1F,
    " ": 0x38,
    "\n": 0x2A,
    "-": 0x1D,
    "=": 0x1C,
    ".": 0x2F,
    ",": 0x2E,
    "/": 0x30,
    ";": 0x2C,
    "'": 0x2B,
    "[": 0x05,
    "]": 0x04,
    "\\": 0x03,
    "`": 0x26,
}
# The characters a NeXT keyboard reaches with Shift. Without this table a URL
# with a colon or a slash-shifted character raises KeyError halfway through a
# typed string, which on a guest that has already had half of it is worse than
# not typing at all.
SHIFTED = {
    "!": "1",
    "@": "2",
    "#": "3",
    "$": "4",
    "%": "5",
    "^": "6",
    "&": "7",
    "*": "8",
    "(": "9",
    ")": "0",
    "_": "-",
    "+": "=",
    "{": "[",
    "}": "]",
    "|": "\\",
    "~": "`",
    ":": ";",
    '"': "'",
    "<": ",",
    ">": ".",
    "?": "/",
}
RETURN = 0x2A
# The `me` folder in the File Viewer's BROWSER column -- not the identical-looking
# house on the SHELF above it, which only ever selects. Kept because it is the
# fallback if Command-u (Update Viewers) is ever unavailable; the scene itself
# uses the keyboard, which needs no working pointer.
BROWSER_HOME = (383, 155)


class Ctl:
    """mamectl/1 client -- the same wire streamhost's mamesock sink speaks."""

    def __init__(self, path, timeout=20.0):
        import socket

        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        hello = self.f.readline().decode().strip()
        assert hello.startswith("HELLO mamectl/1 "), hello
        self.seq = 0

    def cmd(self, line):
        self.seq += 1
        self.f.write(f"{self.seq} {line}\n".encode())
        self.f.flush()
        while True:
            r = self.f.readline().decode().strip()
            if not r:
                raise EOFError("control socket closed")
            n, kind = r.split(" ", 2)[:2]
            if int(n) == self.seq:
                return kind

    def close(self):
        # A criu dump FAILS while a client is CONNECTED to the control socket
        # ("unix: Unix socket ... not found"; --ext-unix-sk does not rescue it),
        # so every driver must let go before a bake. mamesock reconnects forever
        # with backoff, so this costs the daemon nothing.
        self.f.close()
        self.s.close()


class Fb:
    """The IFB1 mapping Previous publishes, read under its seqlock."""

    HDR = 64
    MAGIC = 0x31424649

    def __init__(self, path):
        import mmap
        import struct

        self.struct = struct
        # The mapping outlives this call and is read for the whole run, so the
        # file object is deliberately kept open on the instance rather than
        # closed by a context manager.
        self.f = open(path, "rb")  # noqa: SIM115
        self.m = mmap.mmap(self.f.fileno(), 0, prot=mmap.PROT_READ)
        magic, ver, self.w, self.h, self.stride, bpp = struct.unpack_from("<6I", self.m, 0)
        assert magic == self.MAGIC and ver == 1 and bpp == 32, (hex(magic), ver, bpp)

    def rgb(self):
        for _ in range(200):
            (s0,) = self.struct.unpack_from("<Q", self.m, 24)
            if s0 & 1:
                time.sleep(0.002)
                continue
            px = self.m[self.HDR : self.HDR + self.stride * self.h]
            (s1,) = self.struct.unpack_from("<Q", self.m, 24)
            if s1 == s0:
                a = np.frombuffer(px, dtype=np.uint8)
                a = a.reshape(self.h, self.stride)[:, : self.w * 4].reshape(self.h, self.w, 4)
                return a[:, :, [2, 1, 0]].copy()  # BGRA -> RGB
            time.sleep(0.002)
        raise RuntimeError("framebuffer never settled")


class Rig:
    def __init__(self, shm, ctl, evidence, telnet):
        self.fb = Fb(shm)
        self.c = Ctl(ctl)
        self.ev = evidence
        self.telnet = telnet
        os.makedirs(evidence, exist_ok=True)

    # ---------------------------------------------------------------- guest --
    def guest(self, *cmds):
        env = dict(os.environ, NSTEL_HOST=self.telnet[0], NSTEL_PORT=str(self.telnet[1]))
        out = subprocess.run(["python3", NSTEL, "me", *cmds], capture_output=True, text=True, env=env, timeout=300)
        return out.stdout

    # ---------------------------------------------------------------- frames --
    def png(self, name):
        from PIL import Image

        path = os.path.join(self.ev, name)
        Image.fromarray(self.fb.rgb()).save(path)
        return path

    def locate(self, img=None):
        img = self.fb.rgb() if img is None else img
        white = (img == 255).all(axis=2)
        black = (img == 0).all(axis=2)
        ok = np.ones((H, W), dtype=bool)
        seen = np.zeros((H, W), dtype=np.int16)
        for dx, dy, is_white in SIG:
            src = white if is_white else black
            seen[: H - dy, : W - dx] += 1
            sub = np.zeros((H, W), dtype=bool)
            sub[: H - dy, : W - dx] = src[dy:, dx:]
            sub[H - dy :, :] = True  # off-edge cannot disagree
            sub[:, W - dx :] = True
            ok &= sub
        ok &= seen >= 30
        ys, xs = np.nonzero(ok)
        return [(int(x) + 1, int(y) + 1) for x, y in zip(xs, ys)]

    def cursor(self):
        hits = self.locate()
        if len(hits) != 1:
            raise RuntimeError(f"cursor locator saw {len(hits)}: {hits[:6]}")
        return hits[0]

    # ------------------------------------------------------- pointer (pre) --
    # Before the tablet streams, MOVEA is dead reckoned through the relative KMS
    # mouse and NeXTSTEP's own acceleration curve decides what the guest does --
    # a 24 px step measures ~2.3x, and the curve keys off event TIMING as well as
    # size, so no calibrated step survives a differently-loaded box. ONE PIXEL is
    # the one input the curve cannot amplify: gain 1.000, measured.
    def park(self):
        for _ in range(22):
            self.c.cmd("MOVEP -56 -56")
            time.sleep(0.04)
        for _ in range(8):
            self.c.cmd("MOVEP 1 1")
            time.sleep(0.03)
        time.sleep(0.5)

    def walk(self, tx, ty, tol=4, rounds=4):
        cx = cy = -1
        was = None
        for _ in range(rounds):
            try:
                cx, cy = self.cursor()
            except RuntimeError:
                self.park()
                cx, cy = self.cursor()
            dx, dy = tx - cx, ty - cy
            log(f"walk ({tx},{ty}): at ({cx},{cy}) error ({dx},{dy})")
            if abs(dx) <= tol and abs(dy) <= tol:
                return cx, cy
            if (cx, cy) == was:
                log("walk: no progress on a short correction; stopping here")
                return cx, cy
            was = (cx, cy)
            sx, sy = (1 if dx > 0 else -1), (1 if dy > 0 else -1)
            diag = min(abs(dx), abs(dy))
            seq = [(sx, sy)] * diag + [(sx, 0)] * (abs(dx) - diag) + [(0, sy)] * (abs(dy) - diag)
            for a, b in seq:
                self.c.cmd(f"MOVEP {a} {b}")
                time.sleep(0.02)
            time.sleep(0.5)
        return cx, cy

    # ---------------------------------------------------------------- input --
    def click(self, n=1, gap=0.10):
        for _ in range(n):
            self.c.cmd("DOWN1")
            self.c.cmd("UP1")  # the injector's own BTN_HOLD floor paces it
            time.sleep(gap)
        time.sleep(0.5)

    def click_at(self, x, y, n=1):
        self.c.cmd(f"MOVEA {x} {y}")
        time.sleep(0.3)
        self.click(n)

    def tap(self, code, hold=0.05, gap=0.06):
        self.c.cmd(f"KEY 1 kms 0x{code:02x}")
        time.sleep(hold)
        self.c.cmd(f"KEY 0 kms 0x{code:02x}")
        time.sleep(gap)

    def type(self, s):
        for ch in s:
            shift = False
            if ch.isupper():
                shift, ch = True, ch.lower()
            elif ch in SHIFTED:
                shift, ch = True, SHIFTED[ch]
            code = NEXT[ch]
            if shift:
                self.c.cmd("KEY 1 mod lshift")
                time.sleep(0.03)
            self.tap(code)
            if shift:
                self.c.cmd("KEY 0 mod lshift")
                time.sleep(0.03)

    def command(self, ch):
        self.c.cmd("KEY 1 mod lcommand")
        time.sleep(0.05)
        self.tap(NEXT[ch])
        self.c.cmd("KEY 0 mod lcommand")
        time.sleep(0.3)

    # ------------------------------------------------------------ predicates --
    def workspace_ready(self):
        """The Workspace menu's black title block, top left. The mid-grey test
        alone is not enough: NeXTSTEP's boot panel sits on a full-screen grey
        that passes it, and a run that typed into that gap found nothing."""
        img = self.fb.rgb()
        return bool((img[2:19, 2:90, 0] < 40).mean() > 0.5)

    def wait_workspace(self, timeout=600):
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                if self.workspace_ready():
                    log(f"Workspace after {time.time() - t0:.0f}s")
                    return True
            except RuntimeError:
                pass
            time.sleep(4)
        return False

    def absolute_error(self, targets, settle=0.35):
        worst, rows = 0, []
        for tx, ty in targets:
            self.c.cmd(f"MOVEA {tx} {ty}")
            time.sleep(settle)
            hits = self.locate()
            if len(hits) != 1:
                rows.append((tx, ty, None))
                return None, rows
            worst = max(worst, abs(hits[0][0] - tx), abs(hits[0][1] - ty))
            rows.append((tx, ty, hits[0]))
        return worst, rows

    def install_panel(self):
        """Bounding box of the Install Tablet panel's white Status view, or None.
        The panel is placed by NeXTSTEP, so its buttons are found relative to the
        one unmistakable landmark: a wide block of pure white."""
        white = (self.fb.rgb() == 255).all(axis=2)
        hit = white.sum(axis=1) > 380
        best = run = 0
        end = -1
        for y in range(H):
            run = run + 1 if hit[y] else 0
            if run > best:
                best, end = run, y
        if best < 150:
            return None
        y0, y1 = end - best + 1, end
        cols = white[y0 : y1 + 1].sum(axis=0)
        xs = np.nonzero(cols > (y1 - y0) * 0.8)[0]
        if xs.size < 300:
            return None
        return int(xs[0]), y0, int(xs[-1]), y1


def log(msg):
    print("[scene {}] {}".format(time.strftime("%H:%M:%S"), msg), flush=True)

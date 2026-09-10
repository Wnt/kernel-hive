#!/usr/bin/env python3
"""irisrig.py — drive an Iris (SGI Indy) rig: control sockets + framebuffer.

Stream D (reset plane) of the `indyr4400` de-bridging. This is the bring-up
and proof harness for a HOST-NATIVE Iris station's checkpoint: it starts a
namespaced rig, speaks the three channels Iris exposes, and reads the guest's
framebuffer — the only thing that counts as proof (AGENTS.md rule 9).

Channels, and why there are three of them:

  monitor   TCP, `IRIS_MONITOR_ADDR` (upstream hardcodes 127.0.0.1:8888; the
            fork makes it a knob because it is a process-wide singleton and two
            rigs on one host would silently share it). Carries `rex fbdump`
            — the raw 2048x1024 VRAM planes plus a correct 24-bit PNG — and
            `ps2 type` / `ps2 mouse` / `ps2 status`.
  ci        JSON-lines unix socket from `--ci-socket`. Carries `start`,
            `serial-send`, `wait-serial`. OFF BY DEFAULT since 2026-09-10:
            measured on the integration rig, arming it costs the FRAME plane
            (REX3 stays undrawn, ~200 % CPU, no frame in ten minutes), because
            the ci SCC backend travels with the socket and not with `--ci`.
            `--ci-sock` turns it on for a bake that needs to type into the
            guest over the serial line and knows it is trading the picture for
            it.
  ctl       `mamectl/1` unix socket, `IRIS_CTL_SOCK`. ONE socket for all of it:
            MOVEA / DOWNn / KEY from the input plane AND SAVEST / LOADST /
            RESET / FBSYNC / CKPT from the reset plane, since they were merged
            on 2026-09-10. Identical wire to MAME's ctlsock, so `/root/mctl.py`,
            `reset-tile.sh` and the daemon all speak it unchanged. There is no
            `IRIS_KH_CTL_SOCK` any more.

The framebuffer channel here is `rex fbdump`, NOT the station's IFB1 shm
mapping: this harness has to work before stream A's publisher exists, and the
VRAM planes are a stricter proof anyway — they are the machine's own memory,
with no publisher, no shadow and no capture path in between. When the shm
plane lands, `fb_digest()` gains a second implementation and every proof below
keeps its meaning.

NOTE ON WAITS (rule 14): nothing here sleeps on a guess. `settle()` and
`change()` poll the framebuffer digest with a deadline and say what they saw.
"""

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time

TIMEOUT = 15.0


# ---------------------------------------------------------------------------
# channels
# ---------------------------------------------------------------------------


class Monitor:
    """Iris's interactive monitor console over TCP. Line in, text out.

    The console has no reply framing — it streams until it goes quiet — so every
    call reads until `idle` seconds pass with no bytes, bounded by `deadline`.
    That is the protocol, not a shortcut: `rex fbdump` writes 18 MB first.
    """

    def __init__(self, addr, timeout=TIMEOUT):
        host, port = addr.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.sock.settimeout(0.4)
        self._drain(idle=0.6, deadline=timeout)

    def _drain(self, idle, deadline):
        out = b""
        last = time.monotonic()
        end = last + deadline
        while time.monotonic() < end:
            try:
                b = self.sock.recv(65536)
            except socket.timeout:
                if time.monotonic() - last >= idle:
                    break
                continue
            if not b:
                break
            out += b
            last = time.monotonic()
        return out.decode("utf-8", "replace")

    def cmd(self, line, idle=0.6, deadline=90.0):
        self.sock.sendall((line + "\n").encode())
        return self._drain(idle=idle, deadline=deadline)

    def close(self):
        with contextlib.suppress(OSError):
            self.sock.close()


class Mctl:
    """mamectl/1 line client — the same wire `/root/mctl.py` speaks. Kept here
    rather than imported so the harness works on a rig with no box mctl.py."""

    def __init__(self, path, timeout=TIMEOUT):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.seq = 0
        self.banner = self._line(timeout)
        if not self.banner.startswith("HELLO mamectl/1 "):
            raise RuntimeError(f"bad banner: {self.banner!r}")

    def _line(self, timeout):
        end = time.monotonic() + timeout
        while b"\n" not in self.buf:
            if time.monotonic() > end:
                raise TimeoutError(f"no line within {timeout:.1f}s")
            self.sock.settimeout(max(0.1, end - time.monotonic()))
            b = self.sock.recv(65536)
            if not b:
                raise EOFError("control socket closed")
            self.buf += b
        line, self.buf = self.buf.split(b"\n", 1)
        return line.decode("utf-8", "replace").strip()

    def verb(self, line, timeout=120.0):
        """Send one verb, return (ok, text). Timeout is generous by default:
        SAVEST is a stop-the-world capture of 256 MB of RAM plus the COW
        overlay, and LOADST reads it back."""
        self.seq += 1
        s = str(self.seq)
        t0 = time.monotonic()
        self.sock.sendall((f"{s} {line}\n").encode())
        while True:
            got = self._line(timeout)
            if got.startswith("EV "):
                continue
            parts = got.split(" ", 2)
            if parts[0] != s:
                continue
            ms = (time.monotonic() - t0) * 1000.0
            return parts[1] == "OK", (parts[2] if len(parts) > 2 else ""), ms

    def close(self):
        with contextlib.suppress(OSError):
            self.sock.close()


class Ci:
    """Iris's --ci JSON-lines control socket."""

    def __init__(self, path, timeout=TIMEOUT):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""

    def cmd(self, name, timeout=180.0, **args):
        self.sock.sendall((json.dumps({"cmd": name, "args": args}) + "\n").encode())
        end = time.monotonic() + timeout
        while b"\n" not in self.buf:
            self.sock.settimeout(max(0.1, end - time.monotonic()))
            b = self.sock.recv(65536)
            if not b:
                raise EOFError("ci socket closed")
            self.buf += b
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def close(self):
        with contextlib.suppress(OSError):
            self.sock.close()


# ---------------------------------------------------------------------------
# the framebuffer
# ---------------------------------------------------------------------------


class Framebuffer:
    """`rex fbdump` as a frame channel.

    `rgb.bin` is the whole 2048x1024 VRAM plane, big-endian words; `rgb.png` is
    the same words rendered 24-bit (this encoder is the CORRECT one — Iris's
    RCtrl+PrintScreen path in `disp.rs` writes the blue byte as red, see
    IRIS-DEBRIDGE-BRIEF §2c). The digest is taken over `rgb.bin`, so it is a
    statement about the guest's memory rather than about any encoder.
    """

    def __init__(self, mon, workdir):
        self.mon = mon
        self.workdir = workdir
        os.makedirs(workdir, exist_ok=True)

    def dump(self, tag):
        d = os.path.join(self.workdir, tag)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        out = self.mon.cmd(f"rex fbdump {d}", idle=1.0, deadline=120.0)
        rgb = os.path.join(d, "rgb.bin")
        if not os.path.exists(rgb):
            raise RuntimeError(f"fbdump produced no rgb.bin: {out.strip()[-300:]}")
        h = hashlib.md5()
        with open(rgb, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return {"dir": d, "png": os.path.join(d, "rgb.png"), "md5": h.hexdigest()}

    def digest(self, tag="probe"):
        return self.dump(tag)["md5"]

    def settle(self, seconds=3.0, deadline=300.0, period=1.5):
        """Wait until the framebuffer digest holds still for `seconds`.
        Returns (settled: bool, digest, waited_s)."""
        t0 = time.monotonic()
        last, stable_since = None, None
        while time.monotonic() - t0 < deadline:
            d = self.digest("settle")
            now = time.monotonic()
            if d == last:
                if stable_since is not None and now - stable_since >= seconds:
                    return True, d, now - t0
            else:
                last, stable_since = d, now
            time.sleep(period)
        return False, last, time.monotonic() - t0

    def change(self, base, deadline=120.0, period=1.0):
        """Wait until the digest differs from `base`. Returns (changed, digest, waited)."""
        t0 = time.monotonic()
        while time.monotonic() - t0 < deadline:
            d = self.digest("change")
            if d != base:
                return True, d, time.monotonic() - t0
            time.sleep(period)
        return False, base, time.monotonic() - t0


# ---------------------------------------------------------------------------
# the rig
# ---------------------------------------------------------------------------


class Rig:
    """One namespaced Iris process under a sandbox directory.

    Every shared thing is derived from the rig directory, and the process is
    killed only through the pidfile this class wrote (AGENTS.md rule 5: never
    `pkill -f`, never a cmdline grep).
    """

    def __init__(self, rigdir, binary, monitor_port, state=None, ci=False):
        self.dir = os.path.abspath(rigdir)
        self.binary = os.path.abspath(binary)
        self.monitor_addr = f"127.0.0.1:{monitor_port}"
        self.ci_sock = os.path.join(self.dir, "ci.sock")
        self.ctl_sock = os.path.join(self.dir, "ctl.sock")
        self.pidfile = os.path.join(self.dir, "iris.pid")
        self.log = os.path.join(self.dir, "iris.log")
        self.state = state
        self.ci = ci

    def env(self):
        e = dict(os.environ)
        e["IRIS_MONITOR_ADDR"] = self.monitor_addr
        # ONE socket: the input plane binds it and routes the reset verbs to
        # kh_ctl (iris fork, src/ctlsock.rs). IRIS_KH_CTL_SOCK is gone, and a
        # rig that still set it got no listener at all — every Mctl() below
        # would have failed to connect.
        e["IRIS_CTL_SOCK"] = self.ctl_sock
        e["IRIS_CTL_SCREEN"] = "1280x1024"
        # The station's COW overlay must be deliberate and station-local: --ci
        # otherwise redirects it to /tmp/iris-ci-<pid>-scsiN.overlay, which
        # throws away every guest write on restart (machine.rs, gated by this
        # knob on the fork).
        e["IRIS_CI_OVERLAY_DIR"] = self.dir
        e["IRIS_STATE"] = self.state or ""
        return e

    def start(self):
        if self.alive():
            raise RuntimeError(f"rig already running (pid {self.pid()})")
        for s in (self.ci_sock, self.ctl_sock):
            if os.path.exists(s):
                os.unlink(s)
        # --no-window, NEVER --ci. `--ci` is a MODE: it swaps the SCC serial
        # backends and redirects every overlay=true disk to a throwaway
        # /tmp/iris-ci-<pid>-scsiN.overlay, which makes every launch a cold
        # first boot — on IRIX, the ~7-minute autoconfig relink, every time.
        cmd = [
            self.binary,
            "--config",
            os.path.join(self.dir, "iris.toml"),
            "--noaudio",
            "--no-window",
        ]
        if self.ci:
            cmd += ["--ci-socket", self.ci_sock]
        with open(self.log, "ab") as lf:
            lf.write(("\n=== {}: {}\n".format(time.strftime("%FT%TZ", time.gmtime()), " ".join(cmd))).encode())
            p = subprocess.Popen(
                cmd,
                cwd=self.dir,
                env=self.env(),
                stdout=lf,
                stderr=lf,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        with open(self.pidfile, "w") as f:
            f.write(str(p.pid))
        return p.pid

    def pid(self):
        try:
            with open(self.pidfile) as f:
                return int(f.read().strip())
        except (OSError, ValueError):
            return None

    def alive(self):
        p = self.pid()
        if not p:
            return False
        try:
            # Identity, not existence: a recycled pid must not read as our rig
            # (`/proc/<pid>/exe`, never a cmdline grep).
            return os.path.realpath(f"/proc/{p}/exe").startswith(self.binary)
        except OSError:
            return False

    def stop(self, hard=False, deadline=20.0):
        """SIGCONT, then TERM, then KILL — a SIGSTOPped standby never runs to
        handle SIGTERM (DEBRIDGE-HANDOVER §Lessons 7). `hard` skips straight to
        SIGKILL, which is how the "a checkpoint must not need a clean exit"
        proof kills the emulator."""
        p = self.pid()
        if not p or not self.alive():
            return "not running"
        if hard:
            os.kill(p, signal.SIGKILL)
        else:
            os.kill(p, signal.SIGCONT)
            os.kill(p, signal.SIGTERM)
        t0 = time.monotonic()
        while time.monotonic() - t0 < deadline:
            if not self.alive():
                return "stopped in %.1fs" % (time.monotonic() - t0)
            time.sleep(0.2)
        os.kill(p, signal.SIGKILL)
        time.sleep(0.5)
        return f"SIGKILLed after {deadline:.1f}s"

    def wait_sockets(self, deadline=60.0):
        t0 = time.monotonic()
        while time.monotonic() - t0 < deadline:
            if os.path.exists(self.ctl_sock) and (not self.ci or os.path.exists(self.ci_sock)):
                try:
                    m = Monitor(self.monitor_addr, timeout=3.0)
                    m.close()
                    return True, time.monotonic() - t0
                except OSError:
                    pass
            if not self.alive():
                return False, time.monotonic() - t0
            time.sleep(0.3)
        return False, time.monotonic() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--rig", required=True)
    ap.add_argument("--bin", required=True)
    # NO DEFAULT. The monitor console is a process-wide singleton on a
    # loopback port (upstream hardcodes 8888), so a default is a silent
    # collision: a second rig would talk to the FIRST rig's console and every
    # answer would look plausible. Name a port you have claimed
    # (`kh-claim take port <n>`), the way every other shared value on this box
    # is taken (AGENTS.md rule 7).
    ap.add_argument("--monitor-port", type=int, required=True)
    ap.add_argument("--state", default="")
    ap.add_argument(
        "--ci-sock",
        action="store_true",
        help="arm Iris's ci socket. OFF by default: measured 2026-09-10, arming "
        "it costs the frame plane entirely (no frame in ten minutes at ~200 %% CPU).",
    )
    sub = ap.add_subparsers(dest="action", required=True)
    sub.add_parser("start")
    sub.add_parser("stop").add_argument("--hard", action="store_true")
    sub.add_parser("status")
    sub.add_parser("shot").add_argument("tag", nargs="?", default="shot")
    v = sub.add_parser("verb")
    v.add_argument("line", nargs="+")
    a = ap.parse_args()

    rig = Rig(a.rig, a.bin, a.monitor_port, a.state or None, ci=a.ci_sock)
    if a.action == "start":
        pid = rig.start()
        ok, waited = rig.wait_sockets()
        print(f"started pid={pid} sockets={ok} after {waited:.1f}s")
        return 0 if ok else 1
    if a.action == "stop":
        print(rig.stop(hard=getattr(a, "hard", False)))
        return 0
    if a.action == "status":
        print(f"pid={rig.pid()} alive={rig.alive()}")
        return 0
    if a.action == "shot":
        mon = Monitor(rig.monitor_addr)
        fb = Framebuffer(mon, os.path.join(rig.dir, "fb"))
        d = fb.dump(a.tag)
        print("{}  {}".format(d["md5"], d["png"]))
        return 0
    if a.action == "verb":
        c = Mctl(rig.ctl_sock)
        ok, text, ms = c.verb(" ".join(a.line))
        print("{} {}  ({:.0f} ms)".format("OK" if ok else "ERR", text, ms))
        return 0 if ok else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())

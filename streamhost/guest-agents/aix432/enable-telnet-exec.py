#!/usr/bin/env python3
"""Arm `labctl exec aix432` inside the AIX guest, then prove it end to end.

RUNS ON LABHOST.  One-shot bring-up, idempotent, safe to re-run:

    ssh lab 'python3 /data/kernel-hive/streamhost/guest-agents/aix432/enable-telnet-exec.py'
    ssh lab '... --verify-only'                       # check, change nothing
    ssh lab '... --dir /data/vms/sandbox/<n>/rig --host 127.0.0.1:12323'   # a clone

WHY A SCRIPT AND NOT A README.  Everything it does lives on the guest's DISK,
so it is inside the `golden` snapshot -- and `loadvm golden` reverts the disk
too.  That means (a) the change only survives a `checkpoint-guard recapture`,
and (b) after any future re-bake from an older base the whole thing has to be
redone exactly.  A script is the only honest form for that.

WHAT IT CHANGES, and why each one is needed:

  1. /etc/inetd.conf gains ONE line:
         telnet  stream  tcp6    nowait  root    /usr/sbin/telnetd      telnetd -a
     The retronet bring-up stripped inetd.conf down to the three CDE services
     (ttdbserver, dtspc, cmsd) -- the pre-strip file is still there as
     /etc/inetd.conf.preretronet, and this is that file's own telnet line,
     byte for byte.  inetd itself was running the whole time; nothing was
     listening on 23.
  2. `refresh -s inetd` -- re-reads inetd.conf without a restart.
  3. `chuser rlogin=true root` -- AIX ships root with `rlogin = false` in
     /etc/security/user, so telnetd answers a CORRECT root password with
     "3004-306 Remote logins are not allowed for this account".  Without this
     the channel reads exactly like a wrong password.

WHAT IT DOES NOT CHANGE.  No device is added or removed (the golden's device
set is untouched, so the checkpoint stays restorable), no getty is created,
and the guest gains NO reach: AIXRN-IN still drops every guest-originated
packet to the host and the guest still has no default route.  The channel is
host->guest only, exactly like beos and w2kalpha.

WHY NOT THE SERIAL LINE.  The station has one serial port (sa1 / tty0) and the
golden already holds a live root ksh on it -- which is the PARENT of the CDE
Netscape the exhibit shows.  A getty there respawn-loops fighting that shell
("INIT: Command is respawning too rapidly"), and winning the fight means
killing Netscape.  The serial line stays what it is: the bootstrap this script
drives, and nothing else.

THE BOOTSTRAP.  That same root shell is how this script gets in.  It is a
plain shell with no login, so a live station gets a wake lease first: a paused
guest ACCEPTS every byte and executes none of them, which reads as a wedge.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time

sys.path.insert(0, "/data/kernel-hive/scripts/lib")

TELNET_LINE = "telnet  stream  tcp6    nowait  root    /usr/sbin/telnetd      telnetd -a"
BACKUP = "/etc/inetd.conf.pre-labctlexec"
SUNEXEC = os.environ.get("LABCTL_SUNEXEC", "/root/sunexec.py")
# The REGISTRY, not the generated /data/vms/streamhost/stations.json: this
# script runs during bring-up, which is exactly when the matrix has not been
# regenerated yet. Reading the matrix here made the end-to-end check dial
# 127.0.0.1 (the no-exec_host default) and report a working channel as broken.
REGISTRY = "/data/kernel-hive/registry/stations/%s.json"
OK, BAD = "ok", "NOT SET"


class Serial:
    """The guest's root ksh on tty0, over the station's serial.sock.

    Deliberately unframed: this is the BOOTSTRAP, used only to stand the real
    channel up. Once telnetd answers, use `labctl exec` -- it frames, captures
    and returns the guest's exit code, and this does none of that.
    """

    def __init__(self, path: str):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(10)
        self.s.connect(path)
        self.s.sendall(b"\r")
        self._drain(3.0)

    def _drain(self, secs: float) -> str:
        self.s.settimeout(secs)
        buf = b""
        last = time.time()
        while time.time() - last < secs:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            buf += d
            last = time.time() - secs + 1.2
        return buf.decode("latin-1")

    def run(self, cmd: str, wait: float = 20.0) -> str:
        self.s.sendall(cmd.encode() + b"\r")
        out = self._drain(wait)
        # Strip the echoed command line itself so callers match on OUTPUT.
        return out.split("\n", 1)[1] if "\n" in out else out

    def probe(self, cmd: str, wait: float = 20.0) -> str:
        """Run `cmd` and return only what it printed between two sentinels."""
        tag = "__KHX%d__" % (int(time.time() * 1000) % 1000000)
        out = self.run("echo %sB; %s; echo %sE" % (tag, cmd, tag), wait)
        m = re.search(re.escape(tag) + r"B\r?\n(.*?)" + re.escape(tag) + r"E", out, re.S)
        return m.group(1) if m else out


def state(ser: Serial) -> dict:
    return {
        "inetd_line": ser.probe("grep -c '^telnet[ \t]' /etc/inetd.conf").strip() not in ("", "0"),
        "rlogin": "rlogin=true" in ser.probe("lsuser -a rlogin root"),
        "listening": "LISTEN" in ser.probe("netstat -an | grep '\\.23 '"),
    }


def report(st: dict) -> None:
    for k, label in (
        ("inetd_line", "/etc/inetd.conf telnet line"),
        ("rlogin", "root rlogin=true"),
        ("listening", "telnetd LISTEN on *.23"),
    ):
        print("  %-32s %s" % (label, OK if st[k] else BAD))


def dial_target(station: str, override: str | None) -> tuple[str, int]:
    if override:
        host, _, port = override.partition(":")
        return host, int(port or 23)
    try:
        with open(REGISTRY % station) as fh:
            c = json.load(fh)["operator"]["labctl"]
        host, port = c.get("exec_host"), c.get("exec_port")
        if host and port:
            return host, int(port)
    except (OSError, KeyError, ValueError):
        pass
    sys.stderr.write(
        "no exec_host/exec_port in %s -- falling back to the documented address; "
        "pass --host to override\n" % (REGISTRY % station)
    )
    return "10.99.0.28", 23


def verify_end_to_end(station: str, target: tuple[str, int], dirpath: str) -> bool:
    """The only proof that matters: the real client, the real login, a real rc."""
    pw = os.environ.get("LABCTL_TELNET_PASSWORD")
    if pw is None:
        try:
            with open(os.path.join(dirpath, "telnet-exec.passwd")) as fh:
                pw = fh.read().strip()
        except OSError:
            print("  telnet-exec.passwd            %s (launcher publishes it from local.env "
                  "RN_AIX432_EXEC_PASS)" % BAD)
            return False
    env = {**os.environ, "SUN_USER": "root", "SUN_PASS": pw, "SUN_RC": "$?", "SUN_SUBSHELL": "1"}
    r = subprocess.run(
        ["python3", SUNEXEC, target[0], str(target[1]), "echo __KH_EXEC_OK__; (exit 7)"],
        env=env, capture_output=True, text=True, timeout=180,
    )
    good = "__KH_EXEC_OK__" in r.stdout and r.returncode == 7
    print("  end-to-end %s:%d              %s%s" % (
        target[0], target[1], OK if good else BAD,
        "" if good else "  (rc=%d, stdout=%r, stderr=%r)" % (r.returncode, r.stdout[-200:], r.stderr[-300:]),
    ))
    return good


def main() -> int:
    ap = argparse.ArgumentParser(description="arm labctl exec on aix432")
    ap.add_argument("--station", default="aix432", help="live station name (takes a wake lease)")
    ap.add_argument("--dir", default=None, help="dir holding serial.sock (default: the station's)")
    ap.add_argument("--host", default=None, help="host[:port] to dial for the end-to-end check")
    ap.add_argument("--verify-only", action="store_true", help="check, change nothing")
    ap.add_argument("--no-lease", action="store_true", help="skip the wake lease (a sandbox rig runs free)")
    args = ap.parse_args()

    dirpath = args.dir or "/data/vms/streamhost/stations/%s" % args.station
    sock = os.path.join(dirpath, "serial.sock")
    if not os.path.exists(sock):
        sys.stderr.write("no serial.sock at %s -- is the station running?\n" % sock)
        return 2

    lease = None
    if not args.no_lease:
        from guest_wake import WakeLease, wake  # noqa: E402

        lease = WakeLease(args.station)
        lease.__enter__()
        wake(_qmp(dirpath), args.station)

    try:
        ser = Serial(sock)
        st = state(ser)
        print("before:")
        report(st)

        if args.verify_only:
            done = all(st.values())
        else:
            if not st["inetd_line"]:
                ser.probe("test -f %s || cp /etc/inetd.conf %s" % (BACKUP, BACKUP))
                ser.probe("echo '%s' >> /etc/inetd.conf" % TELNET_LINE)
                ser.probe("refresh -s inetd", wait=25)
            if not st["rlogin"]:
                ser.probe("chuser rlogin=true root", wait=25)
            time.sleep(3)
            st = state(ser)
            print("after:")
            report(st)
            done = all(st.values())

        good = verify_end_to_end(args.station, dial_target(args.station, args.host), dirpath) and done
    finally:
        if lease is not None:
            lease.__exit__(None, None, None)

    if good:
        print(
            "\nlabctl exec is LIVE for %s.\n"
            "  It is NOT yet permanent: every byte of this lives on the guest disk, and\n"
            "  `loadvm golden` (labctl reset, and every station start) reverts it. Persist\n"
            "  it with:  ssh lab 'checkpoint-guard recapture %s'\n" % (args.station, args.station)
        )
    return 0 if good else 1


def _qmp(dirpath: str):
    """A minimal QMP `execute` for guest_wake, over the station's qmp.sock."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20)
    s.connect(os.path.join(dirpath, "qmp.sock"))
    f = s.makefile("rwb")
    f.readline()

    def rpc(cmd, **kw):
        msg = {"execute": cmd}
        if kw:
            msg["arguments"] = kw
        f.write((json.dumps(msg) + "\n").encode())
        f.flush()
        while True:
            line = f.readline()
            if not line:
                raise RuntimeError("qmp closed")
            m = json.loads(line)
            if "event" in m:
                continue
            if "error" in m:
                raise RuntimeError(m["error"])
            return m["return"]

    rpc("qmp_capabilities")
    return rpc


if __name__ == "__main__":
    sys.exit(main())

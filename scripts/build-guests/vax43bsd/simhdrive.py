#!/usr/bin/env python3
"""Drive a SIMH simulator over a pty with an expect/send script.

Usage: simhdrive.py <workdir> <binary> <ini> <scriptfile> [logfile]
Script lines: EXPECT <timeout_s> <regex>   |   SEND <text with \n escapes>
              SENDRAW <hex bytes>          |   DONE
"""

import contextlib
import os
import pty
import re
import select
import subprocess
import sys
import time

work, binary, ini, scriptf = sys.argv[1:5]
logf = sys.argv[5] if len(sys.argv) > 5 else os.path.join(work, "console.log")

steps = []
with open(scriptf) as _sf:
    _script_lines = _sf.readlines()
for raw in _script_lines:
    raw = raw.rstrip("\n")
    if not raw.strip() or raw.lstrip().startswith("#"):
        continue
    op, _, rest = raw.partition(" ")
    if op == "EXPECT":
        t, _, pat = rest.partition(" ")
        steps.append(("EXPECT", float(t), pat))
    elif op == "SEND":
        steps.append(("SEND", 0, rest.encode().decode("unicode_escape")))
    elif op == "SENDRAW":
        steps.append(("SENDRAW", 0, bytes.fromhex(rest)))
    else:
        raise SystemExit(f"bad op {op!r}")

mfd, sfd = pty.openpty()
p = subprocess.Popen([binary, ini], cwd=work, stdin=sfd, stdout=sfd, stderr=sfd, close_fds=True, preexec_fn=os.setsid)
os.close(sfd)
log = open(logf, "wb", buffering=0)  # noqa: SIM115 — closed in the finally block below
buf = b""


def pump(deadline):
    global buf
    while time.time() < deadline:
        r, _, _ = select.select([mfd], [], [], 0.2)
        if mfd in r:
            try:
                d = os.read(mfd, 65536)
            except OSError:
                return False
            if not d:
                return False
            log.write(d)
            buf += d
            return True
        if p.poll() is not None:
            return False
    return None


rc = 0
try:
    for op, t, arg in steps:
        if op == "EXPECT":
            rx = re.compile(arg.encode())
            deadline = time.time() + t
            while True:
                if rx.search(buf):
                    print(f"[ok] {arg}", flush=True)
                    buf = buf[rx.search(buf).end() :]
                    break
                if time.time() > deadline:
                    print(f"[TIMEOUT] {arg}", flush=True)
                    print(buf[-1500:].decode("latin1"), flush=True)
                    rc = 2
                    raise SystemExit(rc)
                got = pump(min(deadline, time.time() + 1.0))
                if got is False and p.poll() is not None:
                    print(f"[EXIT] simulator gone while waiting for {arg}", flush=True)
                    print(buf[-1500:].decode("latin1"), flush=True)
                    rc = 3
                    raise SystemExit(rc)
        elif op == "SEND":
            print(f"[send] {arg!r}", flush=True)
            os.write(mfd, arg.encode())
            time.sleep(0.25)
        else:
            print(f"[sendraw] {arg.hex()}", flush=True)
            os.write(mfd, arg)
            time.sleep(0.25)
    # drain a little
    pump(time.time() + 2)
except SystemExit as e:
    rc = e.code or 0
finally:
    try:
        p.wait(timeout=20)
    except Exception:
        with contextlib.suppress(Exception):
            os.killpg(os.getpgid(p.pid), 15)
    log.close()
print(f"[rc] {rc}", flush=True)
sys.exit(rc)

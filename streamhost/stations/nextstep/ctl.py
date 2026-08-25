#!/usr/bin/env python3
"""One-shot mamectl/1 client for the nextstep station's own plumbing.

The launcher and the bake script both need to say a word to the running
emulator's control socket -- NETUP after a criu restore, NETDOWN before a dump --
and bash cannot speak to a unix socket. Nothing else uses this: streamhost's own
mamesock sink is the daemon's, and it never sends these verbs.

    ctl.py <socket> <verb> [<verb> ...]        prints "<verb> -> OK|ERR ..."

Exit 0 only when every verb was acknowledged OK. The client disconnects on the
way out, which matters: a criu dump FAILS while a client is CONNECTED to this
socket, and succeeds with it merely listening.
"""

import socket
import sys


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path, verbs = sys.argv[1], sys.argv[2:]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(20.0)
    s.connect(path)
    f = s.makefile("rwb")
    hello = f.readline().decode().strip()
    if not hello.startswith("HELLO mamectl/1 "):
        print(f"bad banner: {hello!r}", file=sys.stderr)
        return 1
    rc = 0
    for i, v in enumerate(verbs, 1):
        f.write(f"{i} {v}\n".encode())
        f.flush()
        while True:
            line = f.readline().decode().strip()
            if not line:
                print(f"{v} -> peer closed", file=sys.stderr)
                return 1
            n, kind = line.split(" ", 2)[:2]
            if int(n) == i:
                print(f"{v} -> {line}")
                if kind != "OK":
                    rc = 1
                break
    f.close()
    s.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())

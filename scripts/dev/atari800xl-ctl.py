#!/usr/bin/env python3
"""atari800xl-ctl.py — throwaway golden-stream helper: send mamectl/1 verbs
over a MAME ctlsock unix socket and optionally poll SHOT frames until they
settle/change. Not a shared tool; lives only on the atari800xl-golden branch
for baking the golden savestate.

usage:
  atari800xl-ctl.py <sock> <verb...>            one command, print reply
  atari800xl-ctl.py <sock> --wait-settle <out_png> --timeout T [--interval I]
  atari800xl-ctl.py <sock> --wait-change <out_png> --timeout T [--interval I]
"""
import socket, sys, time, os

def send(sock_path, line, timeout=65.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    # read the HELLO banner line first
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.sendall(("1 " + line + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    s.close()
    return buf.decode(errors="replace").strip()

def shot(sock_path, path):
    return send(sock_path, "SHOT " + path)

def wait_loop(sock_path, out_png, timeout, interval, mode):
    from PIL import Image, ImageChops
    tmp = out_png + ".poll.png"
    t0 = time.time()
    first = None
    last_bytes = None
    last_change = 0.0
    while time.time() - t0 < timeout:
        r = shot(sock_path, tmp)
        if "OK" not in r:
            time.sleep(interval)
            continue
        with open(tmp, "rb") as f:
            data = f.read()
        if first is None:
            first = data
        if mode == "change":
            if data != first:
                os.replace(tmp, out_png)
                print(f"changed after {time.time()-t0:.1f}s")
                return 0
        elif mode == "settle":
            if data != last_bytes:
                last_change = time.time()
            last_bytes = data
            if time.time() - last_change >= float(os.environ.get("SETTLE_S", "3")):
                os.replace(tmp, out_png)
                print(f"settled after {time.time()-t0:.1f}s (last change at {last_change-t0:.1f}s)")
                return 0
        time.sleep(interval)
    if last_bytes is not None:
        with open(out_png, "wb") as f:
            f.write(last_bytes)
    print(f"timeout after {timeout:.1f}s")
    return 2

if __name__ == "__main__":
    args = sys.argv[1:]
    sock_path = args[0]
    if args[1] == "--wait-settle" or args[1] == "--wait-change":
        mode = "settle" if args[1] == "--wait-settle" else "change"
        out_png = args[2]
        timeout = 40.0
        interval = 1.0
        i = 3
        while i < len(args):
            if args[i] == "--timeout":
                timeout = float(args[i+1]); i += 2
            elif args[i] == "--interval":
                interval = float(args[i+1]); i += 2
            elif args[i] == "--settle-s":
                os.environ["SETTLE_S"] = args[i+1]; i += 2
            else:
                i += 1
        sys.exit(wait_loop(sock_path, out_png, timeout, interval, mode))
    else:
        verb = " ".join(args[1:])
        print(send(sock_path, verb))

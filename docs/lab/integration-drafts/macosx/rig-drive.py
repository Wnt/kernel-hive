#!/usr/bin/env python3
"""Tiny QMP driver for the macosx rigs: rel/abs pointer, click, keys, shot."""
import sys, os, json, time
sys.path.insert(0, "/data/vms/sandbox/macosx-work/repo/scripts/lib")
from labqmp import QMPClient

sock = sys.argv[1]
args = sys.argv[2:]
c = QMPClient(sock)

def ev(evts):
    c.execute("input-send-event", events=evts)

i = 0
while i < len(args):
    a = args[i]
    if a == "rel":
        dx, dy = int(args[i+1]), int(args[i+2]); i += 3
        step = 8
        # send in chunks so the guest's HID queue keeps up
        while dx or dy:
            sx = max(-step, min(step, dx)); sy = max(-step, min(step, dy))
            evts = []
            if sx: evts.append({"type": "rel", "data": {"axis": "x", "value": sx}})
            if sy: evts.append({"type": "rel", "data": {"axis": "y", "value": sy}})
            ev(evts); dx -= sx; dy -= sy
            time.sleep(0.004)
    elif a == "abs":
        x, y = int(args[i+1]), int(args[i+2]); i += 3
        ev([{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / 1023)}},
            {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / 767)}}])
    elif a == "click":
        i += 1
        ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
        time.sleep(0.12)
        ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
    elif a == "down":
        i += 1; ev([{"type": "btn", "data": {"down": True, "button": "left"}}])
    elif a == "up":
        i += 1; ev([{"type": "btn", "data": {"down": False, "button": "left"}}])
    elif a == "key":
        i += 1
        ks = []
        while i < len(args) and args[i] not in ("rel","abs","click","key","type","shot","sleep","down","up","hmp"):
            ks.append(args[i]); i += 1
        c.sendkey(*ks)
    elif a == "type":
        c.type(args[i+1]); i += 2
    elif a == "hmp":
        print(c.hmp(args[i+1])); i += 2
    elif a == "shot":
        c.screendump(args[i+1]); print("shot", args[i+1]); i += 2
    elif a == "sleep":
        time.sleep(float(args[i+1])); i += 2
    else:
        raise SystemExit("unknown action " + a)
c.close()

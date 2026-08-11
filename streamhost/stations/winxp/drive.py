#!/usr/bin/env python3
# QMP driver for the streamhost winxp golden-fixture work.
# Connects to a QMP unix socket and runs input / screendump / snapshot commands.
# winxp tile is usb-tablet (ABSOLUTE pointer), so the pointer is driven via the
# QMP abs input path (input-send-event type=abs, 0..32767 mapped over the screen).
# Keyboard is QMP qcode events. Mirrors the win95 drive.py verb surface.
import socket, json, sys, time, os

SOCK = sys.argv[1]
ARGS = sys.argv[2:]

# Screen size for abs-pointer pixel->0..32767 mapping. Override per-resolution
# via SCREEN_W/SCREEN_H (the usb-tablet maps 0..32767 across the current mode).
RES_W = int(os.environ.get("SCREEN_W", "1920"))
RES_H = int(os.environ.get("SCREEN_H", "1200"))

s = socket.socket(socket.AF_UNIX)
for _ in range(60):
    try:
        s.connect(SOCK); break
    except OSError:
        time.sleep(0.5)
else:
    print("ERR: cannot connect", SOCK); sys.exit(1)

buf = b""
def rd():
    global buf
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            return None
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)

def cmd(execute, **args):
    o = {"execute": execute}
    if args: o["arguments"] = args
    s.sendall((json.dumps(o) + "\n").encode())
    while True:
        r = rd()
        if r is None:
            return None
        if "return" in r or "error" in r:
            return r

rd()  # greeting
cmd("qmp_capabilities")

SPECIAL = {
    " ": ("spc", False), "\n": ("ret", False), ".": ("dot", False),
    ",": ("comma", False), "-": ("minus", False), "_": ("minus", True),
    "/": ("slash", False), "=": ("equal", False), ";": ("semicolon", False),
    ":": ("semicolon", True), "'": ("apostrophe", False), "!": ("1", True),
    "?": ("slash", True), "(": ("9", True), ")": ("0", True),
    "\\": ("backslash", False), '"': ("apostrophe", True),
    "[": ("bracket_left", False), "]": ("bracket_right", False),
}
def char_events(ch):
    if ch in "abcdefghijklmnopqrstuvwxyz0123456789":
        return (ch, False)
    if ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        return (ch.lower(), True)
    return SPECIAL.get(ch)

def send_key(qcode, shift=False, ctrl=False, alt=False):
    evs = []
    for m,on in (("shift",shift),("ctrl",ctrl),("alt",alt)):
        if on: evs.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":m}}})
    evs.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":qcode}}})
    evs.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":qcode}}})
    for m,on in (("alt",alt),("ctrl",ctrl),("shift",shift)):
        if on: evs.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":m}}})
    cmd("input-send-event", events=evs)

def hmc(line):
    return cmd("human-monitor-command", **{"command-line": line})

# --- absolute pointer (usb-tablet): map pixel coords to 0..32767 ---
def abs_move(x, y):
    ax = max(0, min(32767, int(float(x) * 32767 / (RES_W - 1))))
    ay = max(0, min(32767, int(float(y) * 32767 / (RES_H - 1))))
    cmd("input-send-event", events=[
        {"type":"abs","data":{"axis":"x","value":ax}},
        {"type":"abs","data":{"axis":"y","value":ay}}])

def click(x, y, button="left"):
    abs_move(x, y); time.sleep(0.15)
    b = "left" if button=="left" else ("right" if button=="right" else "middle")
    cmd("input-send-event", events=[{"type":"btn","data":{"down":True,"button":b}}])
    time.sleep(0.10)
    cmd("input-send-event", events=[{"type":"btn","data":{"down":False,"button":b}}])

VERBS=("shot","key","kc","type","mouse","click","rclick","raw","status","sleep",
       "savevm","loadvm","delvm","querysnap")
i=0
while i < len(ARGS):
    a=ARGS[i]
    if a=="shot":
        print(json.dumps(cmd("screendump", filename=ARGS[i+1]))); i+=2
    elif a=="key":            # bare qcodes: key ret esc up down ...
        j=i+1
        while j<len(ARGS) and ARGS[j] not in VERBS:
            send_key(ARGS[j]); time.sleep(0.06); j+=1
        i=j
    elif a=="kc":             # modified key: kc <mods> <qcode>  mods=c(ctrl)s(shift)a(alt)
        mods=ARGS[i+1]; qc=ARGS[i+2]
        send_key(qc, "s" in mods, "c" in mods, "a" in mods); i+=3
    elif a=="type":
        for ch in ARGS[i+1]:
            ev=char_events(ch)
            if ev: send_key(ev[0], ev[1]); time.sleep(0.05)
        i+=2
    elif a=="mouse":
        abs_move(ARGS[i+1], ARGS[i+2]); i+=3
    elif a=="click":
        click(ARGS[i+1], ARGS[i+2]); i+=3
    elif a=="rclick":
        click(ARGS[i+1], ARGS[i+2], "right"); i+=3
    elif a=="sleep":
        time.sleep(float(ARGS[i+1])); i+=2
    elif a=="status":
        print(json.dumps(cmd("query-status"))); i+=1
    elif a=="savevm":
        print(json.dumps(hmc("savevm "+ARGS[i+1]))); i+=2
    elif a=="loadvm":
        print(json.dumps(hmc("loadvm "+ARGS[i+1]))); i+=2
    elif a=="delvm":
        print(json.dumps(hmc("delvm "+ARGS[i+1]))); i+=2
    elif a=="querysnap":
        print(json.dumps(hmc("info snapshots"))); i+=1
    elif a=="raw":
        print(json.dumps(cmd(ARGS[i+1]))); i+=2
    else:
        print("unknown verb:", a); i+=1
s.close()

#!/usr/bin/env python3
# QMP driver for the streamhost tinycore golden-fixture work.
# Connects to a QMP unix socket and runs input / screendump / snapshot commands.
import socket, json, sys, time

SOCK = sys.argv[1]
ARGS = sys.argv[2:]

RES_W, RES_H = 1024, 768  # std VGA / ffmpeg video_size for this tile

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
}
def char_events(ch):
    if ch in "abcdefghijklmnopqrstuvwxyz0123456789":
        return (ch, False)
    if ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        return (ch.lower(), True)
    return SPECIAL.get(ch)

def send_key(qcode, shift=False):
    evs = []
    if shift:
        evs.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":"shift"}}})
    evs.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":qcode}}})
    evs.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":qcode}}})
    if shift:
        evs.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":"shift"}}})
    cmd("input-send-event", events=evs)

def hmc(line):
    return cmd("human-monitor-command", **{"command-line": line})

# tinyX is RELATIVE-ONLY (ignores usb-tablet). Pointer must be driven via the
# legacy PS/2 relative path (human-monitor-command mouse_move), which is 1:1 with
# no acceleration. Absolute positioning = slam to (0,0) then relative move to x,y.
def slam_origin():
    for _ in range(12):
        hmc("mouse_move -300 -300")
        time.sleep(0.01)

def abs_move(x, y):
    slam_origin()
    x = int(x); y = int(y)
    dx = 0
    while dx < x:
        step = min(100, x - dx); hmc("mouse_move %d 0" % step); dx += step; time.sleep(0.008)
    dy = 0
    while dy < y:
        step = min(100, y - dy); hmc("mouse_move 0 %d" % step); dy += step; time.sleep(0.008)

def click(x, y, button="left"):
    abs_move(x, y)
    time.sleep(0.2)
    b = 1 if button == "left" else (2 if button == "right" else 4)
    hmc("mouse_button %d" % b)
    time.sleep(0.12)
    hmc("mouse_button 0")

VERBS = ("shot","key","type","mouse","click","rclick","raw","status","sleep","savevm","loadvm","delvm","querysnap")
i = 0
while i < len(ARGS):
    a = ARGS[i]
    if a == "shot":
        path = ARGS[i+1]; i += 2
        print(json.dumps(cmd("screendump", filename=path)))
    elif a == "key":
        j = i+1
        while j < len(ARGS) and ARGS[j] not in VERBS:
            send_key(ARGS[j]); time.sleep(0.06); j += 1
        i = j
    elif a == "type":
        text = ARGS[i+1]; i += 2
        for ch in text:
            ev = char_events(ch)
            if ev:
                send_key(ev[0], ev[1]); time.sleep(0.05)
    elif a == "mouse":
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); i += 3
    elif a == "click":
        click(float(ARGS[i+1]), float(ARGS[i+2])); i += 3
    elif a == "rclick":
        click(float(ARGS[i+1]), float(ARGS[i+2]), "right"); i += 3
    elif a == "sleep":
        time.sleep(float(ARGS[i+1])); i += 2
    elif a == "status":
        print(json.dumps(cmd("query-status"))); i += 1
    elif a == "savevm":
        print(json.dumps(cmd("human-monitor-command", **{"command-line": "savevm " + ARGS[i+1]}))); i += 2
    elif a == "loadvm":
        print(json.dumps(cmd("human-monitor-command", **{"command-line": "loadvm " + ARGS[i+1]}))); i += 2
    elif a == "delvm":
        print(json.dumps(cmd("human-monitor-command", **{"command-line": "delvm " + ARGS[i+1]}))); i += 2
    elif a == "querysnap":
        print(json.dumps(cmd("human-monitor-command", **{"command-line": "info snapshots"}))); i += 1
    elif a == "raw":
        print(json.dumps(cmd(ARGS[i+1]))); i += 2
    else:
        print("unknown verb:", a); i += 1

s.close()

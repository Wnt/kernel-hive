#!/usr/bin/env python3
# QMP driver for the streamhost solariscde golden-fixture work.
# Connects to a QMP unix socket and runs input / screendump / snapshot commands.
# solariscde runs with a usb-tablet => ABSOLUTE pointer (SH_POINTER=abs), so the
# mouse is driven via input-send-event 'abs' axis events (0..32767 scaled to the
# 1920x1200 std-VGA framebuffer), 1:1 no accel. Keyboard is QMP qcode events.
import socket, json, sys, time

SOCK = sys.argv[1]
ARGS = sys.argv[2:]

RES_W, RES_H = 1920, 1200  # std VGA, Solaris X comes up 1920x1200
ABSMAX = 32767

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
    "@": ("2", True), "#": ("3", True), "$": ("4", True), "%": ("5", True),
    "^": ("6", True), "&": ("7", True), "*": ("8", True), "+": ("equal", True),
    "~": ("grave_accent", True), "`": ("grave_accent", False),
    "<": ("comma", True), ">": ("dot", True), "{": ("bracket_left", True),
    "}": ("bracket_right", True), "|": ("backslash", True),
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

# --- absolute pointer (usb-tablet) ---
def abs_move(x, y):
    ax = int(max(0, min(RES_W-1, x)) / RES_W * ABSMAX)
    ay = int(max(0, min(RES_H-1, y)) / RES_H * ABSMAX)
    cmd("input-send-event", events=[
        {"type":"abs","data":{"axis":"x","value":ax}},
        {"type":"abs","data":{"axis":"y","value":ay}},
    ])

def click(x, y, button="left"):
    abs_move(x, y); time.sleep(0.2)
    cmd("input-send-event", events=[{"type":"btn","data":{"down":True,"button":button}}])
    time.sleep(0.12)
    cmd("input-send-event", events=[{"type":"btn","data":{"down":False,"button":button}}])

def dblclick(x, y):
    click(x, y); time.sleep(0.12); click(x, y)

def btn(down, button="left"):
    cmd("input-send-event", events=[{"type":"btn","data":{"down":down,"button":button}}])

VERBS=("shot","key","kc","type","typefile","mouse","click","rclick","dclick","raw","status","sleep",
       "savevm","loadvm","delvm","querysnap","mdown","mup","mmove","rdown")
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
    elif a=="typefile":       # type a host file verbatim (chars + newlines)
        with open(ARGS[i+1]) as fh: data=fh.read()
        for ch in data:
            ev=char_events(ch)
            if ev: send_key(ev[0], ev[1]); time.sleep(0.03)
        i+=2
    elif a=="mouse":
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); i+=3
    elif a=="click":
        click(float(ARGS[i+1]), float(ARGS[i+2])); i+=3
    elif a=="rclick":
        click(float(ARGS[i+1]), float(ARGS[i+2]), "right"); i+=3
    elif a=="dclick":
        dblclick(float(ARGS[i+1]), float(ARGS[i+2])); i+=3
    elif a=="mdown":          # press-and-hold left at x y
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); time.sleep(0.15); btn(True); i+=3
    elif a=="rdown":          # press-and-hold right at x y
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); time.sleep(0.15); btn(True,"right"); i+=3
    elif a=="mmove":          # move (while held) to x y
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); i+=3
    elif a=="mup":            # release left at x y
        abs_move(float(ARGS[i+1]), float(ARGS[i+2])); time.sleep(0.15); btn(False); btn(False,"right"); i+=3
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

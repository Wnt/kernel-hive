#!/usr/bin/env python3
# QMP driver for the spike clone: HMP passthrough, screendump->png, ASCII typer.
import json, socket, sys, subprocess, os, time

def _conn(sock):
    s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(sock)
    f = s.makefile("rwb", buffering=0); f.readline()
    f.write(b'{"execute":"qmp_capabilities"}\n')
    while "return" not in json.loads(f.readline()): pass
    return s, f

def qmp(sock, cmd, args=None):
    s, f = _conn(sock)
    req = {"execute": cmd}
    if args is not None: req["arguments"] = args
    f.write(json.dumps(req).encode() + b"\n")
    out = None
    while True:
        r = json.loads(f.readline())
        if "return" in r: out = r["return"]; break
        if "error" in r: raise SystemExit("QMP error: " + json.dumps(r["error"]))
    s.close(); return out

def hmp(sock, line):
    r = qmp(sock, "human-monitor-command", {"command-line": line})
    if r: print(r, end="")
    return r

def shot(sock, outpng):
    ppm = "/tmp/_shot.ppm"
    qmp(sock, "screendump", {"filename": ppm})
    with open(outpng, "wb") as o:
        subprocess.run(["pnmtopng", ppm], stdout=o, stderr=subprocess.DEVNULL, check=False)
    print("shot:", outpng, os.path.getsize(outpng), "bytes")

# ASCII -> qcode (unshifted, shifted)
UN = {
 'a':'a','b':'b','c':'c','d':'d','e':'e','f':'f','g':'g','h':'h','i':'i','j':'j',
 'k':'k','l':'l','m':'m','n':'n','o':'o','p':'p','q':'q','r':'r','s':'s','t':'t',
 'u':'u','v':'v','w':'w','x':'x','y':'y','z':'z',
 '0':'0','1':'1','2':'2','3':'3','4':'4','5':'5','6':'6','7':'7','8':'8','9':'9',
 '-':'minus','=':'equal','[':'bracket_left',']':'bracket_right',';':'semicolon',
 "'":'apostrophe','`':'grave_accent','\\':'backslash',',':'comma','.':'dot',
 '/':'slash',' ':'spc','\t':'tab','\n':'ret',
}
SH = {
 '!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
 '_':'minus','+':'equal','{':'bracket_left','}':'bracket_right',':':'semicolon',
 '"':'apostrophe','~':'grave_accent','|':'backslash','<':'comma','>':'dot','?':'slash',
}

def type_str(sock, text):
    s, f = _conn(sock)
    def key(k):
        f.write(json.dumps({"execute":"human-monitor-command",
                "arguments":{"command-line":"sendkey "+k}}).encode()+b"\n")
        while True:
            r=json.loads(f.readline())
            if "return" in r or "error" in r: break
    for ch in text:
        if ch == '\n':
            key('ret'); time.sleep(0.6); continue   # let shell emit new prompt
        if ch in UN: key(UN[ch])
        elif ch.isupper(): key("shift-"+ch.lower())
        elif ch in SH: key("shift-"+SH[ch])
        else: raise SystemExit("unmapped char: %r"%ch)
        time.sleep(0.05)
    s.close()

if __name__ == "__main__":
    sock = sys.argv[1]; op = sys.argv[2]
    if op == "hmp": hmp(sock, sys.argv[3])
    elif op == "shot": shot(sock, sys.argv[3])
    elif op == "keys":
        for k in sys.argv[3].split(): hmp(sock, "sendkey " + k)
    elif op == "type":   # types argv[3] literally; add trailing \n yourself
        type_str(sock, sys.argv[3])
    elif op == "typef":  # types the verbatim contents of a local file
        with open(sys.argv[3]) as fh: type_str(sock, fh.read())
    else: raise SystemExit("op?")

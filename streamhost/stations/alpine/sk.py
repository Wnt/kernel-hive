#!/usr/bin/env python3
# HMP-sendkey typer for QEMU. Quoting-safe: text passed as base64.
#   sk.py <sock> text64 <b64>     # type literal chars (no Enter)
#   sk.py <sock> key <token>      # one raw HMP sendkey token/combo (e.g. ret, ctrl-c, left)
#   sk.py <sock> keys <t1> <t2>.. # several raw tokens in order
import socket,json,sys,time,base64
sock=sys.argv[1]; mode=sys.argv[2]
BASE={
 '0':'0','1':'1','2':'2','3':'3','4':'4','5':'5','6':'6','7':'7','8':'8','9':'9',
 ' ':'spc','-':'minus','=':'equal','[':'bracket_left',']':'bracket_right',
 ';':'semicolon',"'":'apostrophe','`':'grave_accent','\\':'backslash',
 ',':'comma','.':'dot','/':'slash','\t':'tab',
}
for c in 'abcdefghijklmnopqrstuvwxyz': BASE[c]=c
SHIFT={
 '!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
 '_':'minus','+':'equal','{':'bracket_left','}':'bracket_right',':':'semicolon',
 '"':'apostrophe','~':'grave_accent','|':'backslash','<':'comma','>':'dot','?':'slash',
}
def toks(ch):
    if ch in BASE: return [BASE[ch]]
    if ch.isalpha() and ch.isupper(): return ['shift-'+ch.lower()]
    if ch in SHIFT: return ['shift-'+SHIFT[ch]]
    raise SystemExit("no mapping for char %r"%ch)
s=socket.socket(socket.AF_UNIX); s.connect(sock); buf=b''
def rd():
    global buf
    while b'\n' not in buf: buf+=s.recv(4096)
    line,buf=buf.split(b'\n',1); return json.loads(line)
rd(); s.sendall(b'{"execute":"qmp_capabilities"}\n'); rd()
def sendkey(tok):
    s.sendall((json.dumps({"execute":"human-monitor-command","arguments":{"command-line":"sendkey "+tok}})+"\n").encode()); rd(); time.sleep(0.03)
if mode=='text64':
    txt=base64.b64decode(sys.argv[3]).decode()
    for ch in txt:
        for t in toks(ch): sendkey(t)
elif mode=='key': sendkey(sys.argv[3])
elif mode=='keys':
    for t in sys.argv[3:]: sendkey(t)
else: raise SystemExit("bad mode")
s.close(); print("ok")

#!/usr/bin/env python3
# cdrv.py <qmp.sock> <op> ...   drive a Solaris clone over QMP.
#   sh "<command>"       type a shell command into the focused terminal + Enter
#   type "<text>"        type text (no Enter)
#   key <qcode>...       send one key chord (e.g. key ctrl c ; key ret)
#   abs <x> <y>          move usb-tablet to absolute (0..32767)
#   rel <dx> <dy>        relative mouse motion
#   click <x> <y>        abs move + left click
#   dump <path.ppm>      screendump to host path
import socket, json, time, sys
sock=sys.argv[1]; op=sys.argv[2]
s=socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock); buf=b""
def rl():
    global buf
    while b"\n" not in buf: buf+=s.recv(65536)
    l,buf=buf.split(b"\n",1); return json.loads(l)
rl()
def cmd(o):
    s.sendall((json.dumps(o)+"\r\n").encode())
    while True:
        m=rl()
        if "return" in m or "error" in m: return m
cmd({"execute":"qmp_capabilities"})
def sk(*q): cmd({"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":x} for x in q]}}); time.sleep(0.045)
PLAIN={' ':'spc','\n':'ret','\t':'tab','-':'minus','=':'equal','[':'bracket_left',']':'bracket_right','\\':'backslash',';':'semicolon',"'":'apostrophe','`':'grave_accent',',':'comma','.':'dot','/':'slash'}
SH={'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0','_':'minus','+':'equal','{':'bracket_left','}':'bracket_right','|':'backslash',':':'semicolon','"':'apostrophe','~':'grave_accent','<':'comma','>':'dot','?':'slash'}
def typ(t):
    for c in t:
        if c.isalpha() and c.isupper(): sk('shift',c.lower())
        elif c.isalpha() or c.isdigit(): sk(c.lower())
        elif c in PLAIN: sk(PLAIN[c])
        elif c in SH: sk('shift',SH[c])
        else: sk('spc')
def absmove(x,y): cmd({"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":int(x)}},{"type":"abs","data":{"axis":"y","value":int(y)}}]}})
if op=='sh': typ(sys.argv[3]); sk('ret')
elif op=='type': typ(sys.argv[3])
elif op=='key': sk(*sys.argv[3:])
elif op=='abs': absmove(sys.argv[3],sys.argv[4])
elif op=='rel': cmd({"execute":"input-send-event","arguments":{"events":[{"type":"rel","data":{"axis":"x","value":int(sys.argv[3])}},{"type":"rel","data":{"axis":"y","value":int(sys.argv[4])}}]}})
elif op=='click':
    absmove(sys.argv[3],sys.argv[4]); time.sleep(0.2)
    cmd({"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":True}}]}}); time.sleep(0.1)
    cmd({"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":False}}]}})
elif op=='dump': cmd({"execute":"screendump","arguments":{"filename":sys.argv[3]}})
print("ok")

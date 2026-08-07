#!/usr/bin/env python3
# qmpc.py SOCK CMD [args...]  — minimal QMP client
# commands:
#   shot OUT.ppm
#   savevm NAME
#   loadvm NAME
#   delvm NAME
#   listvm
#   key K [K2 ...]            (qmp send-key, qcode names)
#   mmove DX DY               (rel pointer move)
#   mclick                    (left down+up)
#   raw '<json>'
import socket, json, sys, time

sock = sys.argv[1]; cmd = sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(15)

def send(obj):
    s.sendall((json.dumps(obj)+"\r\n").encode())
def recv_until_return():
    buf=b''
    while True:
        try: c=s.recv(65536)
        except socket.timeout: break
        if not c: break
        buf+=c
        # parse line by line
        for line in buf.split(b'\r\n'):
            if not line.strip(): continue
            try: j=json.loads(line)
            except ValueError: continue
            if 'return' in j or 'error' in j:
                return j
    return None

s.recv(65536)  # greeting
send({"execute":"qmp_capabilities"}); recv_until_return()

def do(obj):
    send(obj)
    r=recv_until_return()
    return r

if cmd=="shot":
    r=do({"execute":"screendump","arguments":{"filename":sys.argv[3]}})
elif cmd=="savevm":
    r=do({"execute":"human-monitor-command","arguments":{"command-line":"savevm "+sys.argv[3]}})
elif cmd=="loadvm":
    r=do({"execute":"human-monitor-command","arguments":{"command-line":"loadvm "+sys.argv[3]}})
elif cmd=="delvm":
    r=do({"execute":"human-monitor-command","arguments":{"command-line":"delvm "+sys.argv[3]}})
elif cmd=="listvm":
    r=do({"execute":"human-monitor-command","arguments":{"command-line":"info snapshots"}})
elif cmd=="key":
    keys=[{"type":"qcode","data":k} for k in sys.argv[3:]]
    r=do({"execute":"send-key","arguments":{"keys":keys}})
elif cmd=="mmove":
    dx=int(sys.argv[3]); dy=int(sys.argv[4])
    r=do({"execute":"input-send-event","arguments":{"events":[
        {"type":"rel","data":{"axis":"x","value":dx}},
        {"type":"rel","data":{"axis":"y","value":dy}}]}})
elif cmd=="mclick":
    do({"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":True}}]}})
    time.sleep(0.1)
    r=do({"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":False}}]}})
elif cmd=="raw":
    r=do(json.loads(sys.argv[3]))
else:
    r={"error":"unknown cmd"}
print(json.dumps(r))

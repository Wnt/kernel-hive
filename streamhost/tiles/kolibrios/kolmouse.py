import socket, json, sys, time
SOCK=sys.argv[1]
s=socket.socket(socket.AF_UNIX); s.connect(SOCK)
buf=b""
def rd():
    global buf
    while b"\n" not in buf:
        c=s.recv(4096); buf+=c
    l,buf=buf.split(b"\n",1)
    return json.loads(l)
def cmd(e,**a):
    o={"execute":e}
    if a:o["arguments"]=a
    s.sendall((json.dumps(o)+"\n").encode())
    while True:
        r=rd()
        if "return" in r or "error" in r: return r
rd(); cmd("qmp_capabilities")
def hmc(l): return cmd("human-monitor-command",**{"command-line":l})
def axis(d,horiz):
    step=2 if d>=0 else -2
    n=abs(d)//2
    for _ in range(n):
        hmc("mouse_move %d %d"%(step if horiz else 0, 0 if horiz else step)); time.sleep(0.004)
    r=d-(n*step)
    if r: hmc("mouse_move %d %d"%(r if horiz else 0,0 if horiz else r))
def origin():
    for _ in range(40): hmc("mouse_move -40 -40"); time.sleep(0.003)
def moveto(x,y):
    origin(); axis(x,True); axis(y,False)
SPECIAL={" ":("spc",0),"\n":("ret",0),".":("dot",0),",":("comma",0),"-":("minus",0),
 "_":("minus",1),"/":("slash",0),"=":("equal",0),";":("semicolon",0),":":("semicolon",1),
 "'":("apostrophe",0),"!":("1",1),"?":("slash",1),"(":("9",1),")":("0",1),"+":("equal",1),
 "*":("8",1),"\"":("apostrophe",1),">":("dot",1),"<":("comma",1)}
def kev(ch):
    if ch in "abcdefghijklmnopqrstuvwxyz0123456789": return (ch,0)
    if ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ": return (ch.lower(),1)
    return SPECIAL.get(ch)
def sendkey(qc,sh=0):
    ev=[]
    if sh: ev.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":"shift"}}})
    ev.append({"type":"key","data":{"down":True,"key":{"type":"qcode","data":qc}}})
    ev.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":qc}}})
    if sh: ev.append({"type":"key","data":{"down":False,"key":{"type":"qcode","data":"shift"}}})
    cmd("input-send-event",events=ev)
cmds=sys.argv[2:]; i=0
VERBS={"origin","move","click","rclick","shot","sleep","type","key","savevm","loadvm","querysnap","status"}
while i<len(cmds):
    a=cmds[i]
    if a=="origin": origin(); i+=1
    elif a=="move": moveto(int(cmds[i+1]),int(cmds[i+2])); i+=3
    elif a=="click": hmc("mouse_button 1"); time.sleep(0.12); hmc("mouse_button 0"); i+=1
    elif a=="rclick": hmc("mouse_button 2"); time.sleep(0.12); hmc("mouse_button 0"); i+=1
    elif a=="shot": cmd("screendump",filename=cmds[i+1]); i+=2
    elif a=="sleep": time.sleep(float(cmds[i+1])); i+=2
    elif a=="type":
        for ch in cmds[i+1]:
            e=kev(ch)
            if e: sendkey(e[0],e[1]); time.sleep(0.04)
        i+=2
    elif a=="key":
        j=i+1
        while j<len(cmds) and cmds[j] not in VERBS:
            sendkey(cmds[j]); time.sleep(0.05); j+=1
        i=j
    elif a=="savevm": print(hmc("savevm "+cmds[i+1])); i+=2
    elif a=="loadvm": print(hmc("loadvm "+cmds[i+1])); i+=2
    elif a=="querysnap": print(json.dumps(hmc("info snapshots"))); i+=1
    elif a=="status": print(json.dumps(cmd("query-status"))); i+=1
    else: print("?",a); i+=1
s.close()

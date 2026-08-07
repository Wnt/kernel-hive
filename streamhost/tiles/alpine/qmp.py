import socket,json,sys
sock=sys.argv[1]
cmds=json.loads(sys.argv[2])
s=socket.socket(socket.AF_UNIX); s.connect(sock)
buf=b""
def rd():
    global buf
    while b"\n" not in buf:
        buf+=s.recv(4096)
    line,buf=buf.split(b"\n",1)
    return json.loads(line)
rd()
s.sendall(b'{"execute":"qmp_capabilities"}\n'); rd()
for c in cmds:
    s.sendall((json.dumps(c)+"\n").encode())
    print(json.dumps(rd()))
s.close()

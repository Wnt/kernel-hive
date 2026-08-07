import socket,sys
c=socket.socket(socket.AF_UNIX);c.connect(sys.argv[1])
c.sendall(" ".join(sys.argv[2:]).encode());c.close()

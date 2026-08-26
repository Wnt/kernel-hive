#!/usr/bin/env python3
# Breakpoint at 0x74da8 (bl settime-date-update); skip the call (PC=0x74dac).
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1])
def csum(b): return sum(b) % 256
def send(p):
    b = p.encode(); s.sendall(b'$' + b + b'#' + f'{csum(b):02x}'.encode())
def recv_pkt():
    buf = b''
    while True:
        c = s.recv(4096)
        if not c: raise EOFError
        buf += c
        i = buf.find(b'$')
        if i >= 0 and b'#' in buf[i:]:
            j = buf.index(b'#', i)
            if len(buf) >= j+3:
                s.sendall(b'+'); return buf[i+1:j].decode()
def cmd(p): send(p); return recv_pkt()
def reg(n):
    r = cmd(f'p{n:x}'); return int(r,16) if r and not r.startswith('E') else 0
s.sendall(b'+'); cmd('qSupported')
print('bp:', cmd('Z0,74da8,4'), flush=True)
send('c')
while True:
    r = recv_pkt()
    if r.startswith('O'): continue
    pc = reg(0x40)
    if pc == 0x74da8:
        cmd('P40=00074dac')          # skip the bl
        print(f'skipped settime-date-update at t={time.time():.0f}', flush=True)
    else:
        print(f'unexpected stop {r[:40]} PC={pc:#x}', flush=True)
    send('c')

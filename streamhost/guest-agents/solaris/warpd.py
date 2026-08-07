# warpd.py - in-guest X pointer agent for Solaris 10 / Xorg.
# Bypasses the usb-tablet 1024x768 abs cap by driving the X pointer directly
# via XTEST (move/click/drag) and XWarpPointer (fallback), reaching full screen.
# Protocol: newline-delimited ASCII on a TCP socket. Commands:
#   M x y      move pointer to (x,y)
#   C x y      move to (x,y) then left-click
#   B n x y    move to (x,y) then click button n (1=L,2=M,3=R,4/5=wheel)
#   D x y      move to (x,y) then press button1 (drag start)
#   U x y      move to (x,y) then release button1 (drag end)
#   P n x y    move to (x,y) then PRESS button n (down; generic, for the daemon)
#   R n x y    move to (x,y) then RELEASE button n (up; generic, for the daemon)
#   W x y      XWarpPointer to (x,y) (no XTEST; pure warp)
#   E <cmd...> run <cmd> in the guest shell (2>&1), reply on THIS connection:
#                O <base64 of stdout+stderr, first 8KB>\n
#                X <exit code>\n
#                .\n
#              base64 avoids newline ambiguity; output is capped at 8KB. The
#              per-connection thread isolates this from other clients; existing
#              M/P/R/B verbs are unchanged and remain fire-and-forget.
#   QUIT       close this connection
import ctypes as C, socket, sys, os, threading, base64
DISP = os.environ.get("DISPLAY", ":0")
X = C.CDLL("/usr/openwin/lib/libX11.so")
T = C.CDLL("/usr/openwin/lib/libXtst.so.1")
X.XOpenDisplay.restype = C.c_void_p
X.XDefaultRootWindow.restype = C.c_ulong
X.XFlush.argtypes = [C.c_void_p]
X.XWarpPointer.argtypes = [C.c_void_p, C.c_ulong, C.c_ulong, C.c_int, C.c_int,
                           C.c_uint, C.c_uint, C.c_int, C.c_int]
X.XSync.argtypes = [C.c_void_p, C.c_int]
T.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
T.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
d = X.XOpenDisplay(DISP)
if not d:
    sys.stderr.write("warpd: cannot open DISPLAY %s\n" % DISP); sys.exit(1)
root = X.XDefaultRootWindow(d)
def move(x, y):
    T.XTestFakeMotionEvent(d, 0, int(x), int(y), 0); X.XFlush(d)
def button(n, press):
    # XSync (round-trip) so the button-down/up is applied to the core-pointer
    # button state BEFORE any following motion -> held-button motion carries
    # ButtonMask, enabling real drags (text-select / window-move / slider).
    # Motion (move()) stays on XFlush -> zero added latency on the hot path.
    T.XTestFakeButtonEvent(d, int(n), 1 if press else 0, 0); X.XSync(d, 0)
CAP = 8192
def run_exec(cmdstr):
    # Run cmdstr in a shell, merge stderr into stdout, return (first CAP bytes, rc).
    # subprocess (py2.4+) is the primary path; os.popen is the fallback. We drain
    # the child's output fully so it never blocks on a full pipe, but only keep the
    # first CAP bytes. Errors are reported in-band rather than killing the thread.
    try:
        import subprocess
        p = subprocess.Popen(cmdstr, shell=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = ""
        while True:
            chunk = p.stdout.read(4096)
            if not chunk: break
            if len(out) < CAP: out += chunk
        p.stdout.close()
        rc = p.wait()
        return out[:CAP], rc
    except ImportError:
        f = os.popen(cmdstr + " 2>&1")
        out = f.read(CAP)
        try: f.read()  # drain remainder so the child can exit
        except Exception: pass
        st = f.close()
        if st is None: rc = 0
        elif os.WIFEXITED(st): rc = os.WEXITSTATUS(st)
        else: rc = 1
        return out, rc
    except Exception, e:
        return "warpd exec error: %s" % e, 127
def handle(line):
    p = line.split()
    if not p: return
    c = p[0].upper()
    if   c == "M" and len(p) >= 3: move(p[1], p[2])
    elif c == "C" and len(p) >= 3: move(p[1], p[2]); button(1, 1); button(1, 0)
    elif c == "B" and len(p) >= 4: move(p[2], p[3]); button(p[1], 1); button(p[1], 0)
    elif c == "D" and len(p) >= 3: move(p[1], p[2]); button(1, 1)
    elif c == "U" and len(p) >= 3: move(p[1], p[2]); button(1, 0)
    elif c == "P" and len(p) >= 4: move(p[2], p[3]); button(p[1], 1)
    elif c == "R" and len(p) >= 4: move(p[2], p[3]); button(p[1], 0)
    elif c == "W" and len(p) >= 3:
        X.XWarpPointer(d, 0, root, 0, 0, 0, 0, int(p[1]), int(p[2])); X.XFlush(d)
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", PORT)); s.listen(8)
open("/tmp/warpd.started", "w").write("listening %d disp %s\n" % (PORT, DISP))
sys.stderr.write("warpd: listening on %d, DISPLAY=%s\n" % (PORT, DISP))
def serve(conn):
    f = conn.makefile("r")
    try:
        for line in f:
            line = line.strip()
            if line == "QUIT": break
            parts = line.split(None, 1)
            if parts and parts[0].upper() == "E":
                # Real exec channel: run + reply framed on THIS connection only.
                cmdstr = parts[1] if len(parts) > 1 else ""
                out, rc = run_exec(cmdstr)
                try:
                    conn.sendall("O " + base64.b64encode(out) +
                                 "\nX " + str(rc) + "\n.\n")
                except Exception, e:
                    sys.stderr.write("warpd: E reply err %s\n" % e)
                continue
            handle(line)
    except Exception, e:
        sys.stderr.write("warpd: err %s\n" % e)
    try: conn.close()
    except: pass
# One thread per connection so multiple viewers (streamhost sessions) can drive
# the pointer concurrently; X calls are serialized enough for our low rate.
while True:
    conn, addr = s.accept()
    t = threading.Thread(target=serve, args=(conn,)); t.setDaemon(True); t.start()

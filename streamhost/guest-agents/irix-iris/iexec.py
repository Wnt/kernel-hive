#!/usr/bin/env python3
"""iexec.py — run a command inside the IRIX guest of the indyr4400 tile and
capture its stdout + exit status.

Iris exposes the emulated Indy's two SCC serial ports as telnet listeners on
127.0.0.1:8880 / :8881 inside the bridge kiosk. IRIX runs a getty on the
second one, so this is a real login shell -- no framebuffer typing, no
key-pacing games, and the output comes back as text.

Usage:  iexec.py "<shell command>" [timeout_s]
        iexec.py --login          # just prove the login works
Exit code is the guest command's exit code.
"""
import socket, sys, time, re

HOST, PORT = "127.0.0.1", 8881
IAC, DONT, WONT, WILL, DO, SB, SE = 255, 254, 252, 251, 253, 250, 240


class Term:
    def __init__(self, timeout=180):
        self.s = socket.create_connection((HOST, PORT), 10)
        self.s.settimeout(0.5)
        self.buf = ""
        self.deadline = time.time() + timeout

    def _negotiate(self, data):
        """Answer telnet option negotiation so the far end stops asking."""
        out, i, resp = bytearray(), 0, bytearray()
        while i < len(data):
            if data[i] == IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (WILL, WONT) and i + 2 < len(data):
                    resp += bytes([IAC, DONT, data[i + 2]]); i += 3; continue
                if cmd in (DO, DONT) and i + 2 < len(data):
                    resp += bytes([IAC, WONT, data[i + 2]]); i += 3; continue
                if cmd == SB:
                    j = data.find(bytes([IAC, SE]), i)
                    i = len(data) if j < 0 else j + 2
                    continue
                i += 2; continue
            out.append(data[i]); i += 1
        if resp:
            self.s.sendall(bytes(resp))
        return bytes(out)

    def pump(self):
        try:
            d = self.s.recv(65536)
            if d:
                self.buf += self._negotiate(d).decode("latin-1")
        except socket.timeout:
            pass
        except OSError:
            pass

    def expect(self, pattern, tries=240):
        rx = re.compile(pattern)
        for _ in range(tries):
            if time.time() > self.deadline:
                raise TimeoutError("deadline waiting for %r" % pattern)
            m = rx.search(self.buf)
            if m:
                return m
            self.pump()
        raise TimeoutError("timeout waiting for %r; tail=%r" % (pattern, self.buf[-400:]))

    def send(self, line):
        self.s.sendall(line.encode("latin-1") + b"\r")

    def login(self):
        # Nudge the getty; it may already be at a prompt or mid-session.
        self.send("")
        for _ in range(60):
            self.pump()
            if re.search(r"login:\s*$", self.buf) or "login:" in self.buf[-200:]:
                self.buf = ""
                self.send("root")
                break
            if re.search(r"[#%>]\s*$", self.buf):
                break            # already logged in
            self.send("")
            time.sleep(0.4)
        # A password prompt may or may not appear (root has an empty password).
        t0 = time.time()
        while time.time() - t0 < 25:
            self.pump()
            if "Password" in self.buf or "password" in self.buf:
                self.buf = ""
                self.send("")
            if re.search(r"\n[^\n]*[#%]\s*$", self.buf):
                break
            time.sleep(0.3)
        self._ensure_sh()

    def _ensure_sh(self):
        """root's login shell on IRIX is csh, where `$?` is undefined ("Variable
        syntax") and the marker protocol below cannot work. `exec /bin/sh` is
        racy right after login -- csh is still sourcing .cshrc and swallows it --
        so probe and retry rather than sleeping a fixed amount."""
        for attempt in range(8):
            self.buf = ""
            self.send("echo IEXEC_SH_PROBE$?")
            time.sleep(1.5)
            self.pump()
            if "IEXEC_SH_PROBE0" in self.buf:
                self.buf = ""
                self.send("PS1='IEXEC> '; export PS1; TERM=dumb; export TERM; stty -echo 2>/dev/null")
                time.sleep(1.0)
                self.pump()
                self.buf = ""
                return
            self.buf = ""
            self.send("exec /bin/sh")
            time.sleep(2.5)
            self.pump()
        raise RuntimeError("could not get a Bourne shell on the IRIX serial console")

    def run(self, cmd):
        """Run cmd, return (stdout, exit_code). Output is fenced by unique
        markers so shell echo, prompts and getty noise cannot be mistaken for
        program output."""
        b, e = "IEXEC_B_7391", "IEXEC_E_7391"
        self.buf = ""
        self.send("echo %s; %s; echo %s$?" % (b, cmd, e))
        m = self.expect(re.escape(e) + r"(\d+)")
        code = int(m.group(1))
        # The tty echoes the command line, so BOTH markers appear once in that
        # echo before the real output. Anchor on the LAST begin marker that
        # precedes the terminating end marker.
        out = self.buf[:m.start()]
        i = out.rfind(b)
        if i >= 0:
            out = out[i + len(b):]
        out = out.replace("\r\n", "\n").replace("\r", "\n")
        return out.strip("\n"), code


    def put(self, local, remote):
        """Copy a local file into the guest over the serial console with a
        quoted here-doc, so nothing in the payload is shell-interpreted.
        Verifies with `wc -c` -- the serial line is lossy if pushed too hard."""
        data = open(local, "rb").read().decode("latin-1")
        lines = data.split("\n")
        if lines and lines[-1] == "":
            lines.pop()   # a trailing newline is not an extra line to send
        delim = "IEXEC_EOF_7391"
        assert delim not in data, "delimiter collides with payload"
        self.buf = ""
        self.send("cat > %s <<'%s'" % (remote, delim))
        time.sleep(0.5)
        for ln in lines:
            self.send(ln)
            time.sleep(0.06)
            self.pump()
        self.send(delim)
        time.sleep(1.0)
        out, code = self.run("wc -c < %s" % remote)
        got = int(out.split()[0])
        want = len(data) if data.endswith("\n") else len(data) + 1  # here-doc always ends the last line
        if got != want:
            raise IOError("push of %s truncated: guest has %d bytes, want %d"
                          % (remote, got, want))
        return got


def main():
    if len(sys.argv) < 2:
        print(__doc__); return 2
    if sys.argv[1] == "--put":
        timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 300
    else:
        timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 180
    t = Term(timeout)
    t.login()
    if sys.argv[1] == "--put":
        n = t.put(sys.argv[2], sys.argv[3])
        print("pushed %s -> %s (%d bytes)" % (sys.argv[2], sys.argv[3], n))
        return 0
    if sys.argv[1] == "--login":
        out, code = t.run("uname -a; id")
        print(out); return code
    out, code = t.run(sys.argv[1])
    print(out)
    return code


if __name__ == "__main__":
    sys.exit(main())

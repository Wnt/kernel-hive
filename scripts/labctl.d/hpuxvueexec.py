"""labctl exec over the golden's already-logged-in serial shell (exec_kind
"serial_shell").

hpuxvue is not `serial_getty`: its checkpoint bakes a *live* root session on
tty1p0 (`-sh`, PS1 `KHPROMPT>`), and Mosaic — a window of the exhibit scene — is
a CHILD of that shell. So there is no login to perform and, more importantly,
nothing here may ever end the session: `exit` would take Mosaic with it. The
client attaches to the running shell, frames one command between sentinels,
drains to the END sentinel and lets go.

Two measured properties of this line shape the client (docs/guests/hpuxvue.md):

* **Shell builtins are reliable; exec of an external binary is not.** Builtins
  (`echo`, redirection, globs, `while read`, `case`, subshell forks) measured
  120/120 and 20/20; running an external binary wedges the session roughly half
  the time. A wedge is permanent — the tty still echoes, nothing executes, and
  no getty respawns because init's respawn slot is held by the shell that is
  still there — so this client reports it as exit 125 with the heal.
* **The heal is `labctl reset hpuxvue`** (loadvm golden), which restored the
  channel in every trial. It also resets the visitor's scene, so it is the
  operator's call and this client never does it.

The command runs in a SUBSHELL (a forking subshell measured 10/10 here, and
`exit N` must not reach the login shell), so a bare `exit 3` returns 3 instead of
being refused as "There are running jobs". The command line is sent whole: the
guest's line editor mangles the ECHO past ~70 characters but still executes the
line, so output is cut at the BEGIN sentinel rather than by stripping an echo.
"""

from __future__ import annotations

import os
import re
import socket
import sys
import time

PROMPT = "KHPROMPT>"
DEFAULT_TIMEOUT = 120.0
SYNC_TIMEOUT = 12.0
SENTINEL = "__KH_HPUX_%d__"
WEDGED = (
    "the serial session is wedged: the tty still echoes but nothing executes. "
    "This is the station's known external-command wedge; heal it with "
    "`labctl reset hpuxvue` (loadvm golden), which also resets the visitor's "
    "scene. See docs/guests/hpuxvue.md."
)


class _Line:
    def __init__(self, path: str) -> None:
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(0.5)
        self.s.connect(path)
        self.buf = ""

    def read_until(self, needle: str, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self.s.recv(65536)
                if not chunk:
                    return False
                self.buf += chunk.decode("latin1")
            except socket.timeout:
                pass
            except OSError:
                return False
            if needle in self.buf:
                return True
        return False

    def read_until_re(self, pattern: "re.Pattern[str]", timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self.s.recv(65536)
                if not chunk:
                    return False
                self.buf += chunk.decode("latin1")
            except socket.timeout:
                pass
            except OSError:
                return False
            if pattern.search(self.buf):
                return True
        return False

    def send(self, text: str) -> None:
        self.s.sendall(text.encode("latin1"))

    def close(self) -> None:
        try:
            self.s.close()
        except OSError:
            pass


def run(station_dir: str, cmdline: str, timeout: float = DEFAULT_TIMEOUT) -> tuple[int, str, str]:
    """Return (exit_code, stdout_text, diagnostic). 125 = channel wedged/down."""
    path = os.path.join(station_dir, "serial.sock")
    try:
        line = _Line(path)
    except OSError as exc:
        return 125, "", f"serial.sock: {exc}"
    try:
        line.buf = ""
        line.send("\r")
        if not line.read_until(PROMPT, SYNC_TIMEOUT):
            return 125, "", WEDGED
        tag = SENTINEL % (int(time.time()) % 100000)
        line.buf = ""
        line.send(f"echo {tag}-B; ( {cmdline} ); echo {tag}-E-$?\r")
        end = re.compile(re.escape(tag) + r"-E-(\d+)")
        if not line.read_until_re(end, timeout):
            return 125, line.buf, f"no result after {timeout}s — {WEDGED}"
        text = line.buf.replace("\r\n", "\n").replace("\r", "\n")
        match = end.search(text)
        begin = text.find(tag + "-B\n")
        out = text[begin + len(tag) + 3 : match.start()] if begin >= 0 else text[: match.start()]
        # drain the trailing prompt: closing while output is still in flight is
        # one of the ways this line wedges.
        line.read_until(PROMPT, 5.0)
        return int(match.group(1)), out, ""
    finally:
        line.close()


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.stderr.write("usage: hpuxvueexec.py <station-dir> <cmd> [--timeout S]\n")
        return 2
    station_dir, cmdline = argv[0], argv[1]
    timeout = DEFAULT_TIMEOUT
    if "--timeout" in argv[2:]:
        timeout = float(argv[argv.index("--timeout") + 1])
    code, out, diag = run(station_dir, cmdline, timeout)
    sys.stdout.write(out)
    if diag:
        sys.stderr.write("hpuxvueexec: " + diag + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

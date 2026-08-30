"""labctl.d/guest.py — the guest-driving verbs: type/key/sh/exec/mctl/
reset/clone, plus the x11 Lua-agent + mamectl command-injection plumbing
they share. Moved verbatim out of scripts/labctl (size-exclusions.json
split, step 3b). Imports from labctl.d/common, labctl.d/keys and
labctl.d/capture only — never from labctl.
"""

import os, re, subprocess, sys, time

from common import TILES_DIR, cdrv, die, ensure_running, hmp, is_x11_tile, read_env, tile_conf
from keys import key_pacing, send_chords_paced, type_text, warn_unpaced
from capture import capture_png_any

SOL_CLONE = "/data/vms/sandbox/launch-clone.sh"
GENERIC_CLONE = "/data/vms/sandbox/clone-tile.sh"
MCTL = os.environ.get("LABCTL_MCTL", "/root/mctl.py")


def x11_cmd_file(c, name):
    """The legacy Lua-agent command file. Only a valid input route while the
    tile runs the Lua agent, i.e. has no ctl socket — the compiled-in mamectl
    module does not tail this file, so writes there would be silently dead."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    env = read_env(os.path.join(tile_dir, "station.env"))
    return env.get("SH_X11_CMD_FILE", os.path.join(tile_dir, "irix_cmd"))


def ctl_sock(c, name):
    """The mamectl/1 control socket of the compiled-in MAME ctlsock module
    (issue #45), or None. station.env's SH_MAMECTL_SOCK is the live truth — the
    matrix 'ctl' field is labctl-gen's snapshot of the same var — so an env
    flip takes effect before the next 'labctl gen'."""
    tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
    env = read_env(os.path.join(tile_dir, "station.env"))
    return env.get("SH_MAMECTL_SOCK") or c.get("ctl")


def mctl_run(sock, verb=None, timeout=None, lines=None):
    """Shell out to the mamectl/1 client (/root/mctl.py): one request line
    (verb) or a batch over a single connection (lines, via --stdin). The
    client's exit discipline passes through unchanged: 0 OK ack / 1 ERR ack /
    2 badverb|unsupported / 125 channel down."""
    cmd = ["python3", MCTL, sock]
    if timeout is not None:
        cmd += ["--timeout", str(timeout)]
    if lines is not None:
        cmd.append("--stdin")
        return subprocess.run(cmd, input="\n".join(lines) + "\n", capture_output=True, text=True)
    return subprocess.run(cmd + [verb], capture_output=True, text=True)


def x11_cmd_append(c, name, lines):
    """Append Lua-agent commands (POST/CODE/CLICK1/...) to an x11 tile's cmd
    file; the in-emulator agent consumes+truncates them."""
    path = x11_cmd_file(c, name)
    try:
        with open(path, "a") as f:
            for line in lines:
                f.write(line + "\n")
    except OSError as exc:
        die("cannot write x11 cmd file %s: %s" % (path, exc))


def x11_cmd_send(c, name, lines):
    """Deliver agent-syntax input lines (POST/CODE/CLICK1/... — the mamectl
    module parses the same command language as the Lua agent) to an x11 tile.
    Socket-first: with a ctl socket the module is the ONLY injector and does
    not tail the cmd file, so a file append there would be silently dead —
    failures stay loud instead of falling back. The file append remains the
    route only for tiles without a ctl socket (Lua-agent arm). Returns the
    route taken, for user messages."""
    sock = ctl_sock(c, name)
    if not sock:
        x11_cmd_append(c, name, lines)
        return "x11 Lua agent cmd file"
    r = mctl_run(sock, lines=lines)
    if r.returncode:
        detail = (r.stderr or "").strip() or (r.stdout or "").strip() or "no detail"
        die("mamectl input via %s failed:\n%s" % (sock, detail), code=r.returncode)
    return "mamectl socket"


def cmd_type(argv):
    if len(argv) < 2:
        die('usage: labctl type <tile> "<text>" [--verify]')
    verify = "--verify" in argv[2:]
    name = argv[0]
    c = tile_conf(name)
    ensure_running(c, name)
    if is_x11_tile(c):
        warn_unpaced(c, name)
        route = x11_cmd_send(c, name, ["POST " + argv[1]])
        print("ok: queued POST (%d chars) to %s via the %s" % (len(argv[1]), name, route))
        return
    route = type_text(c, name, argv[1])
    print("ok: typed %d chars into %s via %s" % (len(argv[1]), name, route))
    if verify:
        # Inlined cmd_shot's body (guest.py cannot import labctl's cmd_shot —
        # labctl imports from labctl.d, never the reverse) rather than
        # duplicating labctl.d/capture.py's capture_png_any call: identical
        # output (bare screendump path printed) to `labctl shot <tile> <path>`.
        shot = "/tmp/%s-type-verify.png" % name
        time.sleep(1.0)
        try:
            capture_png_any(name, c, shot, resume=True)
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            die(str(exc))
        print(shot)


# QMP qcode -> MAME natkeyboard coded token, for the x11/mamectl CODE route.
# Only keys natkeyboard expresses as one coded token; modifier chords have no
# coded form (raw matrix edges: labctl mctl <tile> "KEY <0|1> <port> <field>").
X11_KEY_CODES = {
    "ret": "{ENTER}",
    "kp_enter": "{ENTER}",
    "esc": "{ESC}",
    "tab": "{TAB}",
    "backspace": "{BACKSPACE}",
    "spc": "{SPACE}",
    "delete": "{DEL}",
    "insert": "{INS}",
    "up": "{UP}",
    "down": "{DOWN}",
    "left": "{LEFT}",
    "right": "{RIGHT}",
    "home": "{HOME}",
    "end": "{END}",
    "pgup": "{PGUP}",
    "pgdn": "{PGDN}",
}
X11_KEY_CODES.update({"f%d" % n: "{F%d}" % n for n in range(1, 13)})


def cmd_key(argv):
    if len(argv) < 2:
        die("usage: labctl key <tile> <qcode> [qcode ...]   (e.g. ctrl c ; or: ret)")
    name = argv[0]
    c = tile_conf(name)
    ensure_running(c, name)
    if is_x11_tile(c):
        keys = argv[1:]
        if len(keys) == 1 and keys[0] in X11_KEY_CODES and ctl_sock(c, name):
            route = x11_cmd_send(c, name, ["CODE " + X11_KEY_CODES[keys[0]]])
            print("ok: sent %s to %s via the %s" % (X11_KEY_CODES[keys[0]], name, route))
            return
        die(
            "x11 tile '%s' has no QMP send-key. Single mappable qcodes (%s) go "
            "over the mamectl socket when the tile has one; anything else routes "
            'by hand: labctl mctl %s "CODE {ENTER}" / "KEY <0|1> <port> <field>" '
            "(KEYDUMP lists ports), or the Lua cmd file (%s) on the rollback arm. "
            "'labctl type %s \"<text>\"' does POST for you."
            % (name, " ".join(sorted(X11_KEY_CODES)), name, x11_cmd_file(c, name), name)
        )
    keys = argv[1:]
    hold_ms, gap_ms = key_pacing(c, name)
    if hold_ms is None and gap_ms is None:
        r = cdrv(c["qmp"], "key", *keys)
        if r.returncode != 0:
            die("key failed: %s" % r.stderr.strip())
    else:
        # One chord: the hold is what matters (the emulator must sample the
        # port while the key is down). The gap still applies after it, so a
        # following key from the next labctl invocation is not merged in.
        try:
            send_chords_paced(c["qmp"], [keys], hold_ms, gap_ms)
            if gap_ms:
                time.sleep(gap_ms / 1000.0)
        except (OSError, RuntimeError) as exc:
            die("key failed: %s" % exc)
    print("ok: sent key chord [%s] to %s" % (" ".join(keys), argv[0]))


def cmd_sh(argv):
    if len(argv) < 2:
        die('usage: labctl sh <tile> "<cmd>"')
    name = argv[0]
    c = tile_conf(name)
    ensure_running(c, name)
    if is_x11_tile(c):
        route = x11_cmd_send(c, name, ["POST " + argv[1], "CODE {ENTER}"])
        sys.stderr.write(
            "labctl: WARNING — x11 'sh' is BLIND: it POSTs the line + Enter through "
            "natkeyboard (%s) with NO stdout/exit capture. For real captured "
            "output use 'labctl exec %s ...' where a channel exists.\n" % (route, name)
        )
        print("ok: POSTed shell line + Enter into %s (blind, via the %s)" % (name, route))
        return
    type_text(c, name, argv[1], trailing=["ret"])
    sys.stderr.write(
        "labctl: WARNING — 'sh' is BLIND: it types the line into the guest "
        "console and presses Enter, but captures NO stdout/exit code. For real "
        "captured output use 'labctl exec %s ...' where a channel exists "
        "(see 'labctl ls' EXEC column).\n" % name
    )
    print("ok: typed shell line into %s console (blind)" % name)


GEXEC = "/root/gexec.py"
IRIXEXEC = os.environ.get("LABCTL_IRIXEXEC", "/root/irixexec.py")
W2KTELNETEXEC = os.environ.get("LABCTL_W2KTELNETEXEC", "/root/w2ktelnetexec.py")
TRU64EXEC = os.environ.get("LABCTL_TRU64EXEC", "/root/tru64exec.py")
SUNEXEC = os.environ.get("LABCTL_SUNEXEC", "/root/sunexec.py")
NEWSOSEXEC = os.environ.get("LABCTL_NEWSOSEXEC", "/root/newsosexec.py")
# w2kalpha's guest telnet server rides the retronet bridge vmbr-rn at its
# reserved DHCP address (the host end and the dec21143 pcap adapter are set up by
# streamhost/stations/w2kalpha/rn-tapnet.sh, called from x11-runtime.sh). labhost
# dials it over the bridge; the guest only ever replies (ESTABLISHED), so the
# W2KALPHARN-IN containment chain leaves the exec channel working. No per-tile
# host field is needed.
W2K_TELNET_HOST = "10.99.0.17"


def cmd_exec(argv):
    if len(argv) < 2:
        die('usage: labctl exec <tile> "<cmd>"')
    name = argv[0]
    c = tile_conf(name)
    # Every exec channel — in-guest ssh/warpd on a QEMU tile, the emulated
    # serial line on an x11 one — needs the guest actually executing.
    ensure_running(c, name)
    cmdline = argv[1]
    kind = c.get("exec_kind")
    port = c.get("exec_port")
    if kind == "serial_e":
        # irix: irixser/2 to the in-guest agent over MAME's -ioc2:rs232a pty.
        # There is no port — the client scrapes the pty out of MAME's fd table,
        # which is authoritative across relaunches. Extra argv is passed through
        # so operators can reach --detach / --fast / --timeout.
        r = subprocess.run(["python3", IRIXEXEC, c["dir"], cmdline, *argv[2:]])
        sys.exit(r.returncode)
    if kind == "serialcon_e":
        # tru64: the guest has NO network device, so exec rides the emulated
        # com2 that es40 already carries — a getty on /dev/tty01, lent one
        # client at a time by the tile's pumps.py over serial-exec.sock in the
        # tile dir. No port: the tile DIRECTORY is the address, which is what
        # keeps the channel stable across relaunches. Extra argv passes through
        # (--timeout).
        r = subprocess.run(["python3", TRU64EXEC, c["dir"], cmdline, *argv[2:]])
        sys.exit(r.returncode)
    if kind == "serialcsh_e":
        # newsos: like tru64's serialcon_e (getty login, sentinel-framed
        # capture, the guest's exit code) but the transport is irix's — MAME's
        # -serial0 pty scraped straight out of the emulator's fd table, no pump.
        # The guest's login shell is csh with no ksh, so newsosexec.py does
        # `exec /bin/sh` and sets PATH. No port: the station DIRECTORY is the
        # address. Extra argv passes through (--timeout).
        r = subprocess.run(["python3", NEWSOSEXEC, c["dir"], cmdline, *argv[2:]])
        sys.exit(r.returncode)
    if kind == "serial_getty":
        # rhapsody: a getty on the guest's COM1 (`<dir>/serial.sock`), one login
        # session per command, sentinel-framed capture, the guest's exit code.
        # No agent in the guest; the tile DIRECTORY is the address. Password
        # from LABCTL_SERIAL_PASSWORD or <dir>/serial-exec.passwd (never the
        # registry). Extra argv passes through (--timeout).
        import serialexec

        user = c.get("exec_user") or "root"
        timeout = serialexec.DEFAULT_TIMEOUT
        if "--timeout" in argv[2:]:
            timeout = float(argv[argv.index("--timeout") + 1])
        code, out, diag = serialexec.run(c["dir"], user, cmdline, timeout)
        sys.stdout.write(out)
        if diag:
            sys.stderr.write("labctl exec: " + diag + "\n")
        sys.exit(code)
    if kind == "warpd_e" and port:
        # real captured exec over warpd's 'E' verb (gexec.py frames the reply and
        # exits with the guest's exit code). exec_host tells gexec.py where warpd
        # listens: unset -> 127.0.0.1 (solaris' slirp hostfwd); win98se sets it to
        # the guest's bridge IP (n0 is a real tap on vmbr-rn, reached directly).
        host = c.get("exec_host")
        env = {**os.environ, "GEXEC_HOST": host} if host else os.environ
        r = subprocess.run(["python3", GEXEC, str(port), cmdline], env=env)
        sys.exit(r.returncode)
    if kind == "telnet_e":
        # w2kalpha: captured exec over the guest W2K Telnet Server on the
        # host-only veth. w2ktelnetexec.py logs in (user from exec_user, blank
        # password), runs the command with errorlevel-bearing sentinels, renders
        # the VT100 console back to plain text, and exits with the guest's code.
        user = c.get("exec_user") or "Administrator"
        r = subprocess.run(
            ["python3", W2KTELNETEXEC, W2K_TELNET_HOST, cmdline],
            env={**os.environ, "W2K_USER": user},
        )
        sys.exit(r.returncode)
    if kind == "telnet_unix_e" and port:
        # Captured exec over an in-guest UNIX telnetd. sunexec.py logs in (user
        # from exec_user), runs the command bracketed by unique markers, prints
        # stdout+stderr and exits with the guest's code. Two stations:
        #   sunos414 — SLIRP, reached at 127.0.0.1:<exec_port> through the
        #     hostfwd the launcher (re-)adds on every start; csh; no password.
        #   beos     — a real tap on vmbr-rn, so exec_host is the guest's own
        #     bridge IP and exec_port is a plain :23 (no hostfwd, no slirp);
        #     bash, so the exit code is $?; and its telnetd DOES want a
        #     password.
        #   aix432   — like beos (tap on vmbr-rn at 10.99.0.28:23, ksh so the
        #     exit code is $?, password from the station dir) plus
        #     exec_subshell: AIX's ksh IS the login shell, so a bare `exit N`
        #     would end the session and surface as a channel fault.
        # The password is read from the STATION DIR (<dir>/telnet-exec.passwd,
        # written by the launcher from the gitignored registry/local.env), never
        # from the committed registry — same rule as serial_getty's
        # serial-exec.passwd. LABCTL_TELNET_PASSWORD overrides for a one-off.
        user = c.get("exec_user") or "root"
        host = c.get("exec_host") or "127.0.0.1"
        env = {**os.environ, "SUN_USER": user}
        if c.get("exec_shell") == "sh":
            env["SUN_RC"] = "$?"
        if c.get("exec_subshell"):
            env["SUN_SUBSHELL"] = "1"
        pw = os.environ.get("LABCTL_TELNET_PASSWORD")
        if pw is None:
            pwfile = os.path.join(c["dir"], "telnet-exec.passwd")
            try:
                with open(pwfile) as fh:
                    pw = fh.read().strip()
            except OSError:
                pw = None
        if pw is not None:
            env["SUN_PASS"] = pw
        # Keep the guest AWAKE for the whole call. ensure_running() above thaws a
        # guest the daemon idle-paused, but the daemon's reconciler re-asserts
        # that pause ~60 s after the last visitor -- and on a TCG station a
        # telnet login plus one command can easily outlive that window, which
        # looks exactly like a broken exec channel: the socket connects, the
        # login banner never arrives, and the client times out on an empty read.
        # So re-issue `cont` while the client runs. Bounded by the client's own
        # timeouts, and a no-op on a guest that is already running.
        proc = subprocess.Popen(["python3", SUNEXEC, host, str(port), cmdline], env=env)
        qmp = c.get("qmp")
        while True:
            try:
                sys.exit(proc.wait(timeout=15))
            except subprocess.TimeoutExpired:
                if qmp:
                    try:
                        hmp(qmp, "cont", timeout=10)
                    except Exception:
                        pass
    if kind == "ssh" and port:
        user = c.get("exec_user") or "root"
        key = c.get("exec_key")
        cmd = [
            "ssh",
            "-p",
            str(port),
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=10",
        ]
        if key:
            cmd += ["-i", key]
        cmd += ["%s@127.0.0.1" % user, cmdline]
        r = subprocess.run(cmd, capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        if r.stderr:
            sys.stderr.write(r.stderr)
        sys.exit(r.returncode)
    # no wired exec channel — print tile-specific alternatives
    alt = [
        "This tile has NO exec channel (no live ssh; warpd is a fire-and-forget pointer agent with no exec/E verb).",
        "Alternatives:",
        '  * labctl sh %s "<cmd>"   (BLIND — types into console, no capture)' % name,
    ]
    if name == "solaris":
        alt.append("  * labctl clone solaris <N>  then: ssh -p $((2300+N)) root@127.0.0.1 '<cmd>'  (clone has ssh 22)")
    alt.append(
        "  * to add a live ssh channel safely: qmp_hmp.py <qmp> "
        "'hostfwd_add net0 tcp:127.0.0.1:<port>-:22' (adds to the "
        "EXISTING -netdev user; does NOT change the device set) — "
        "requires sshd running in the guest."
    )
    die("\n".join(alt))


def cmd_reset(argv):
    if not argv:
        die("usage: labctl reset <tile>")
    name = argv[0]
    c = tile_conf(name)
    # x11 relaunch: a service restart runs ExecStop (stop-tile-x11 kills MAME+Xvfb
    # by pidfile) then ExecStartPre (ensure-tile-x11 relaunches a pristine Xvfb+
    # MAME) synchronously before ExecStart, so no QMP wait — the runtime is up
    # when systemctl returns.
    if c.get("reset_mode") == "relaunch" or (is_x11_tile(c) and c.get("reset_mode") != "restart"):
        # mamectl-first: with a ctl socket and a baked savestate (IRIX_STATE is
        # the launcher's own restore name) reset is an in-place "LOADST <name>"
        # — ~5 s, no Xvfb+MAME relaunch. The ack is COMPLETION of a ~12 s
        # worst-case stop-the-world load, hence timeout 60. Fall back to the
        # relaunch ONLY on a downed channel (exit 125); an ERR ack is a real
        # failure and stays loud.
        sock = ctl_sock(c, name)
        tile_dir = c.get("dir", os.path.join(TILES_DIR, name))
        state = read_env(os.path.join(tile_dir, "station.env")).get("IRIX_STATE")
        if sock and state:
            r = mctl_run(sock, verb="LOADST " + state, timeout=60)
            if r.returncode == 0:
                print("ok: %s restored to '%s' savestate (mamectl LOADST)" % (name, state))
                return
            if r.returncode != 125:
                die("reset failed (mamectl LOADST %s):\n%s" % (state, (r.stderr or r.stdout).strip()), code=1)
            sys.stderr.write("labctl: mamectl socket down (%s) — falling back to relaunch\n" % sock)
        unit = "streamhost@%s.service" % name
        r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
        if r.returncode:
            die("reset failed (x11 relaunch):\n%s" % (r.stderr or r.stdout).strip())
        print("ok: %s relaunched through %s (pristine RAM overlay)" % (name, unit))
        return
    if c.get("reset_mode") == "restart":
        unit = "streamhost@%s.service" % name
        r = subprocess.run(["systemctl", "restart", unit], capture_output=True, text=True)
        if r.returncode:
            die("reset failed (cold service restart):\n%s" % (r.stderr or r.stdout).strip())
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if os.path.exists(c["qmp"]):
                print("ok: %s cold-restarted through %s" % (name, unit))
                return
            time.sleep(0.5)
        die("reset failed: %s restarted but QMP did not return" % unit)
    if c.get("golden_snapshot") is False:
        die("tile '%s' has NO 'golden' snapshot — it boots cold; 'reset' cannot restore it. (see tiles.json)" % name)
    # Resume first: loadvm works on a paused guest but would leave it paused;
    # cont-then-loadvm guarantees the restored golden state is RUNNING.
    ensure_running(c, name)
    r = hmp(c["qmp"], "loadvm golden")
    out = (r.stdout or "") + (r.stderr or "")
    # HMP loadvm prints nothing on success; any 'Error'/'no such' means failure.
    if re.search(r"[Ee]rror|no such|does not|Device", out):
        die("reset failed:\n%s" % out.strip())
    print("ok: %s restored to golden snapshot (loadvm golden)" % name)


def cmd_mctl(argv):
    """Raw mamectl/1 verb passthrough for tiles with a ctl socket. The client's
    output and exit discipline (0/1/2/125) stream through untouched; per-ack
    timeout matters for SAVEST/LOADST (completion acks, use --timeout 60+)."""
    usage = 'usage: labctl mctl <tile> "<verb line>" [--timeout S]'
    if len(argv) < 2:
        die(usage)
    name = argv[0]
    timeout = None
    verb = []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--timeout" and i + 1 < len(argv):
            timeout = argv[i + 1]
            i += 2
            continue
        if a.startswith("--timeout="):
            timeout = a.split("=", 1)[1]
            i += 1
            continue
        verb.append(a)
        i += 1
    if not verb:
        die(usage)
    c = tile_conf(name)
    sock = ctl_sock(c, name)
    if not sock:
        die(
            "tile '%s' has no mamectl control socket (no SH_MAMECTL_SOCK in its "
            "station.env, no 'ctl' field in tiles.json). See 'labctl exec/sh/type' "
            "for this tile's wired channels." % name
        )
    # A SIGSTOPped emulator answers nothing on its ctl socket, so this used to
    # be the one driving verb that could hang on a frozen guest with no
    # explanation. ensure_running also holds the wake lease for the rest of this
    # process, which is what keeps a SAVEST/LOADST (--timeout 60+) from being
    # cut in half by the daemon's 60 s pause re-assert.
    ensure_running(c, name)
    cmd = ["python3", MCTL, sock]
    if timeout is not None:
        cmd += ["--timeout", timeout]
    cmd.append(" ".join(verb))
    sys.exit(subprocess.run(cmd).returncode)


def cmd_clone(argv):
    if len(argv) < 2:
        die("usage: labctl clone <tile> <N>   (N should be a fresh id >= 40 for solaris)")
    name, n = argv[0], argv[1]
    tile_conf(name)  # validate + guardrail
    if name == "solaris":
        if not os.path.exists(SOL_CLONE):
            die("solaris clone tool missing: %s" % SOL_CLONE)
        r = subprocess.run(["bash", SOL_CLONE, str(n)], capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        if r.returncode != 0:
            die("clone failed:\n%s" % r.stderr.strip())
        return
    # No dedicated clone tool for other tiles.
    print("No dedicated clone tool for tile '%s'. Manual recipe:" % name)
    print("  The generic helper %s derives a clone dir + copies the golden qcow2" % GENERIC_CLONE)
    print("  but requires per-tile adaptation of the qemu line (disk/qmp/pidfile,")
    print("  hostfwds). Use the solaris launch-clone.sh as the reference pattern:")
    print("    %s" % SOL_CLONE)
    print("  Steps: cp the tile's golden qcow2 to a fresh work dir, reproduce the")
    print("  EXACT device set from %s/%s/qemu-streamhost.sh (so 'loadvm golden'" % (TILES_DIR, name))
    print("  still matches), swap in a private qmp.sock + pidfile, add any hostfwd")
    print("  you need on the EXISTING -netdev user, and launch with a fresh VMID.")

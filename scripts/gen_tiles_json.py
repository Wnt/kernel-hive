#!/usr/bin/env python3
# gen_tiles_json.py — build /data/vms/streamhost/tiles.json capability matrix.
# Seeds each tile from the canonical registry's generated declaration, verifies
# that declaration against tile.env + qemu-streamhost.sh, then adds a live HMP
# 'info snapshots' probe (read-only). Run ON THE BOX.
import argparse
import contextlib
import json
import os
import re
import socket

TILES_DIR = "/data/vms/streamhost/tiles"
OUT = "/data/vms/streamhost/tiles.json"
DECLARATIONS = "/data/vms/streamhost/build/registry/generated/labctl-declarations.json"
# Note on riscos / windows11: ordinary gallery tiles (old protection removed
# 2026-07-08) but NOT streamhost tiles — no /data/vms/streamhost/tiles/<tile>/
# dir, no streamhost@<tile> unit, no serve/tiles.json entry. The SPA binds them
# directly in archetypeRegistry as showcase posters. The declaration seed
# naturally omits them; the old hard-block BLOCK set was removed in the 2026-07
# restructure.


def read_env(p):
    d = {}
    try:
        with open(p) as f:
            for ln in f:
                ln = ln.strip()
                if not ln or ln.startswith("#") or "=" not in ln:
                    continue
                k, v = ln.split("=", 1)
                d[k.strip()] = v.split("#", 1)[0].strip()
    except OSError:
        pass
    return d


def pointer_mode(env):
    """Return the client pointer semantic from unified or legacy daemon config."""
    backend = env.get("SH_INPUT_BACKEND", "").lower()
    if backend in ("dbus-abs", "gallery-hid"):
        return "abs"
    if backend == "dbus-rel":
        return "rel"
    if backend == "warpd":
        return "warpd"
    # Keyboard-only exhibits (mpf2) run the daemon with no pointer sink at all.
    if backend == "disabled":
        return "none"
    # Legacy SH_INPUT_BACKEND=dbus still needs SH_POINTER to distinguish abs/rel.
    return env.get("SH_POINTER", "abs")


def probe_golden(sock, timeout=8):
    """Return True/False/None(unknown) whether internal snapshot 'golden' exists."""
    if not os.path.exists(sock):
        return None
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(timeout)
        s.connect(sock)
        buf = b""

        def rl():
            nonlocal buf
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    raise OSError("eof")
                buf += chunk
            l, buf = buf.split(b"\n", 1)[0], buf.split(b"\n", 1)[1]
            return json.loads(l)

        rl()  # greeting

        def cmd(o):
            s.sendall((json.dumps(o) + "\r\n").encode())
            while True:
                m = rl()
                if "return" in m or "error" in m:
                    return m

        cmd({"execute": "qmp_capabilities"})
        r = cmd({"execute": "human-monitor-command", "arguments": {"command-line": "info snapshots"}})
        s.close()
        out = r.get("return", "") or ""
        # 'info snapshots' lists a table; a golden row contains the tag 'golden'
        return bool(re.search(r"\bgolden\b", out))
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--declarations", default=DECLARATIONS)
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()
    with open(args.declarations) as f:
        declarations = json.load(f)["tiles"]
    live_dirs = {t for t in os.listdir(TILES_DIR) if os.path.isdir(os.path.join(TILES_DIR, t))}
    if live_dirs != set(declarations):
        raise SystemExit(f"declared/live tile set mismatch: declared={sorted(declarations)} live={sorted(live_dirs)}")
    tiles = {}
    for t in sorted(declarations):
        declared = declarations[t]
        d = os.path.join(TILES_DIR, t)
        env = read_env(os.path.join(d, "tile.env"))
        launcher = ""
        lp = os.path.join(d, "qemu-streamhost.sh")
        with contextlib.suppress(OSError), open(lp) as f:
            launcher = f.read()
        pointer = pointer_mode(env)
        # x11 runtime tiles (SH_CAPTURE=x11, IRIX/issue #20) have no QEMU/QMP: no
        # SH_QMP in tile.env, no qmp.sock, no snapshot to probe. Reflect that as a
        # null qmp + null golden instead of synthesizing a dead socket path.
        is_x11 = env.get("SH_TILE_RUNTIME") == "x11" or env.get("SH_CAPTURE") == "x11"
        qmp = None if is_x11 else env.get("SH_QMP", os.path.join(d, "qmp.sock"))
        # warpd channel address the daemon dials (SH_WARPD_ADDR): tcp host:port
        # OR "unix:<path>" (serial-chardev agents like win311 speak COM1 —
        # no TCP hostfwd exists or is needed for those).
        warpd_addr = env.get("SH_WARPD_ADDR") or None
        # warpd port: hostfwd host-port -> guest :7777
        warpd_port = None
        m = re.search(r"hostfwd=tcp:127\.0\.0\.1:(\d+)-[\d.]*:?7777", launcher)
        if m:
            warpd_port = int(m.group(1))
        # ssh port: hostfwd host-port -> guest :22
        ssh_port = None
        m = re.search(r"hostfwd=tcp:127\.0\.0\.1:(\d+)-[\d.]*:?22\b", launcher)
        if m:
            ssh_port = int(m.group(1))
        observed = {
            "dir": d,
            "qmp": qmp,
            "pointer_mode": pointer,
            "warpd_addr": warpd_addr,
            "udp_port": int(env["SH_PORT"]) if env.get("SH_PORT", "").isdigit() else None,
        }
        for key, value in observed.items():
            if declared.get(key) != value:
                raise SystemExit(f"declared/live mismatch {t}.{key}: declared={declared.get(key)!r} live={value!r}")
        if warpd_port is not None and declared.get("warpd_port") != warpd_port:
            raise SystemExit(f"declared/live mismatch {t}.warpd_port")
        if ssh_port is not None and declared.get("ssh_port") != ssh_port:
            raise SystemExit(f"declared/live mismatch {t}.ssh_port")
        golden = None if is_x11 else probe_golden(qmp)
        notes = [declared["notes"]] if declared.get("notes") else []
        if is_x11:
            pass  # x11 tiles reset by relaunch (pristine RAM overlay), not a snapshot
        elif golden is False:
            notes.append("no 'golden' snapshot found: reset (loadvm golden) will fail; tile boots cold")
        elif golden is None:
            notes.append("golden snapshot state unknown (probe failed)")
        tiles[t] = dict(declared)
        tiles[t]["golden_snapshot"] = golden
        tiles[t]["reset_mode"] = env.get("SH_RESET_MODE", "loadvm")
        # mamectl/1 control socket (issue #45): derived from tile.env, not
        # declared — tiles without SH_MAMECTL_SOCK carry no field at all.
        if env.get("SH_MAMECTL_SOCK"):
            tiles[t]["ctl"] = env["SH_MAMECTL_SOCK"]
        tiles[t]["notes"] = "; ".join(notes) if notes else ""
    doc = {
        "_generated_by": "gen_tiles_json.py (see the scripts/labctl header in the osgallery repo)",
        "_schema": {
            "qmp": "unix QMP socket path",
            "pointer_mode": "abs|rel|warpd|none client semantic, derived from SH_INPUT_BACKEND or legacy SH_POINTER",
            "warpd_port": "host TCP port fwd to guest warpd :7777, or null "
            "(null is NORMAL for serial-chardev agents — see warpd_addr)",
            "warpd_addr": "SH_WARPD_ADDR the daemon dials: tcp host:port or unix:<path> serial chardev, or null",
            "ssh_port": "host TCP port fwd to guest sshd :22, or null",
            "exec_port": "port for REAL captured exec (ssh port or warpd port), or null",
            "exec_kind": "ssh | warpd_e | serial_e | null — how 'labctl exec' reaches this tile",
            "ctl": "mamectl/1 unix socket of the MAME ctlsock module (SH_MAMECTL_SOCK); "
            "labctl mctl/type/sh/reset route over it — field absent when the tile has none",
            "exec_user": "ssh login user for exec_kind=ssh, else null",
            "exec_key": "ssh private key path for exec_kind=ssh, else null",
            "console": "fb (framebuffer via QMP send-key) | ssh",
            "golden_snapshot": "true|false|null(unknown) — internal 'golden' snapshot present",
            "reset_mode": "loadvm|restart|pve-rollback from the tile environment",
            "notes": "free text",
        },
        "tiles": tiles,
    }
    with open(args.out, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {args.out} ({len(tiles)} tiles)")
    for t, c in tiles.items():
        print(
            f"  {t:<13} ptr={c['pointer_mode']:<5} warpd={c['warpd_port']} ssh={c['ssh_port']} "
            f"exec={c['exec_port']}({c['exec_kind']}) golden={c['golden_snapshot']}"
        )


if __name__ == "__main__":
    main()

#!/bin/bash
# ============================================================================
# reset-tile.sh <osId> — reset ONE streamhost station to its golden fixture.
# ----------------------------------------------------------------------------
# The single authoritative reset used by BOTH the Playwright input suite
# (reset-before-run) AND the UI "Restore to golden" button
# (POST /restore/<osId> in osgallery-https-server.py).
#
# Reads golden-manifest.json (same dir). Per-station resetMode:
#   loadvm   -> QMP `loadvm <snapshot>` on the station's live qmp.sock. Fast,
#              no restart, restores RAM+devices EXACTLY. Non-destructive: it
#              only RESTORES from the in-qcow2 snapshot, never `savevm`.
#   restart  -> re-run the station's qemu-streamhost.sh (kills by pidfile +
#              relaunches -> cold-boots the curated fixture) then restart
#              streamhost@<tileDir> so the daemon re-attaches to the new QMP
#              socket. For stations whose backing store can't hold a vmstate snap.
#   pve-rollback -> `qm rollback <vmid> golden`, then restart streamhost so it
#              re-attaches to the dedicated QMP socket recreated by PVE.
#
# Optional per-station `postRestoreKeys` (registry-declared, loadvm only): a list of
# HMP sendkey chords sent to the guest AFTER a successful restore. Used where the
# fixture is an emulator inside the guest and the exhibit wants the emulated
# machine itself to re-run its own power-on sequence (mpf2: scroll_lock toggles
# MAME's UI keys on, f3 soft-resets the emulated MPF-II — a genuine ROM reboot,
# beep and all — scroll_lock hands the keyboard back to the guest).
#
# Exit 0 on success; prints one status line. Local QEMU kill is by pidfile only
# (inside qemu-streamhost.sh); PVE rollback is limited to the registry VMID.
# ============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${GOLDEN_MANIFEST:-$HERE/golden-manifest.json}"
TILES_ROOT="${STREAMHOST_TILES_DIR:-/data/vms/streamhost/tiles}"

OSID="${1:-}"
if [ -z "$OSID" ]; then
  echo "usage: reset-tile.sh <osId>" >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "reset: manifest not found: $MANIFEST" >&2
  exit 2
fi

# Pull this station's fields out of the manifest with python3 (always present here).
read -r TILEDIR RESETMODE SNAP PVE_VMID POSTKEYS < <(
  python3 - "$MANIFEST" "$OSID" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["tiles"]
t=m.get(sys.argv[2])
if not t: print("__MISSING__ __ __ __ -"); sys.exit(0)
keys=",".join(t.get("postRestoreKeys") or []) or "-"
print(t["tileDir"], t["resetMode"], t.get("snapshot") or "-", t.get("pveVmid") or "-", keys)
PY
)

if [ "$TILEDIR" = "__MISSING__" ]; then
  echo "reset: unknown osId '$OSID' (not in manifest)" >&2
  exit 3
fi

TDIR="$TILES_ROOT/$TILEDIR"
SOCK="$TDIR/qmp.sock"

qmp_loadvm() {
  # human-monitor-command loadvm <snap> over the QMP unix socket. HMP loadvm
  # prints nothing on success; any text (e.g. "no such snapshot") is an error.
  python3 - "$SOCK" "$1" <<'PY'
import socket,json,sys
sock,snap=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
buf=b""; stage=0; out=None
def send(o): s.sendall((json.dumps(o)+"\r\n").encode())
while True:
    d=s.recv(65536)
    if not d: break
    buf+=d
    while b"\r\n" in buf:
        line,buf=buf.split(b"\r\n",1)
        if not line.strip(): continue
        try: m=json.loads(line)
        except: continue
        if stage==0 and "QMP" in m: send({"execute":"qmp_capabilities"}); stage=1
        elif stage==1 and "return" in m:
            send({"execute":"human-monitor-command","arguments":{"command-line":"loadvm %s"%snap}}); stage=2
        elif stage==2 and "return" in m: out=m["return"]; s.close();
        elif "error" in m: print("QMPERR:"+json.dumps(m["error"])); sys.exit(1)
    if out is not None: break
txt=(out or "").strip()
if txt and ("error" in txt.lower() or "no such" in txt.lower() or "does not" in txt.lower()):
    print("LOADVMERR:"+txt); sys.exit(1)
print("OK")
PY
}

qmp_sendkey() {
  # HMP `sendkey <chord>` for each comma-separated chord in $1, paced so an
  # emulator inside the guest sees discrete presses.
  python3 - "$SOCK" "$1" <<'PY'
import socket,json,sys,time
sock,keys=sys.argv[1],[k for k in sys.argv[2].split(",") if k]
s=socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(sock)
def rx():
    buf=b""
    while b"\r\n" not in buf: buf+=s.recv(65536)
    return buf
rx(); s.sendall(b'{"execute":"qmp_capabilities"}\r\n'); rx()
for k in keys:
    s.sendall((json.dumps({"execute":"human-monitor-command",
        "arguments":{"command-line":"sendkey %s"%k}})+"\r\n").encode())
    rx(); time.sleep(0.6)
print("OK")
PY
}

case "$RESETMODE" in
  loadvm)
    if [ ! -S "$SOCK" ]; then
      echo "reset $OSID: FAIL (no qmp.sock at $SOCK)" >&2
      exit 4
    fi
    # gallery-hid's Unix connection is process-local and deliberately excluded
    # from VMState. Coordinate Solaris restore with the daemon so QEMU receives
    # a fresh GHIN/GHOK and the kernel re-arms before the first pointer event.
    # SIGUSR1/2 are handled only by the gallery backend; no service/QEMU restart.
    GHID_PID=""
    GHID_SOCK="$TDIR/gallery-hid.sock"
    if [ "$TILEDIR" = "solaris" ] &&
      grep -q '^SH_INPUT_BACKEND=gallery-hid$' "$TDIR/tile.env" 2>/dev/null; then
      GHID_PID="$(systemctl show -p MainPID --value "streamhost@${TILEDIR}.service" 2>/dev/null)"
      case "$GHID_PID" in
        '' | 0 | *[!0-9]*)
          echo "reset $OSID: FAIL (gallery streamhost pid unavailable)" >&2
          exit 4
          ;;
      esac
      kill -USR1 "$GHID_PID" 2>/dev/null || {
        echo "reset $OSID: FAIL (gallery restore-pause signal)" >&2
        exit 4
      }
      disconnected=0
      for _ in $(seq 1 40); do
        if ! ss -xapH 2>/dev/null | grep -F "$GHID_SOCK" | grep -q '^u_str ESTAB'; then
          disconnected=1
          break
        fi
        sleep 0.05
      done
      if [ "$disconnected" -ne 1 ]; then
        kill -USR2 "$GHID_PID" 2>/dev/null || true
        echo "reset $OSID: FAIL (gallery backend did not pause)" >&2
        exit 4
      fi
    fi
    R="$(qmp_loadvm "$SNAP" 2>&1)"
    if [ -n "$GHID_PID" ]; then
      kill -USR2 "$GHID_PID" 2>/dev/null || true
      reconnected=0
      for _ in $(seq 1 100); do
        if ss -xapH 2>/dev/null | grep -F "$GHID_SOCK" | grep -q '^u_str ESTAB'; then
          reconnected=1
          break
        fi
        sleep 0.05
      done
      if [ "$reconnected" -ne 1 ]; then
        echo "reset $OSID: FAIL (gallery backend did not resume)" >&2
        exit 5
      fi
      # LINK IRQ -> Solaris DRIVER_READY is asynchronous after GHOK.
      sleep 0.25
    fi
    if echo "$R" | grep -q '^OK'; then
      if [ "$POSTKEYS" != "-" ]; then
        # Give the restored guest a moment to re-arm its input stack, then send
        # the registry-declared post-restore chords.
        sleep 1
        K="$(qmp_sendkey "$POSTKEYS" 2>&1)"
        if ! echo "$K" | grep -q '^OK'; then
          echo "reset $OSID: FAIL (post-restore keys $POSTKEYS: $K)" >&2
          exit 5
        fi
        echo "reset $OSID: OK (loadvm $SNAP on $TILEDIR; post-restore keys $POSTKEYS)"
        exit 0
      fi
      echo "reset $OSID: OK (loadvm $SNAP on $TILEDIR)"
      exit 0
    fi
    echo "reset $OSID: FAIL (loadvm $SNAP: $R)" >&2
    exit 5
    ;;
  restart | relaunch)
    # relaunch = the x11/shm runtime stations (irix). They have no QMP monitor and
    # no vmstate snapshot, so "restore to golden" means relaunching the emulator:
    # the launcher rebuilds disk.chd from the immutable golden CHD on every
    # start, so a fresh launch IS the golden state.
    #
    # It has to be the whole SERVICE, not just MAME. x11-runtime.sh --mame-only
    # would restore the disk faster, but the new MAME creates a FRESH framebuffer
    # file while the daemon keeps its mapping of the old one — the daemon then
    # encodes a frozen buffer forever, and says nothing, because a static frame
    # still produces its periodic keyframes and every health check reads normal.
    # Restarting the service re-maps it. (Observed 2026-08-04 after a boot-watchdog
    # relaunch: station streamed black while labctl shot, which opens the file by
    # path, showed a live desktop.)
    systemctl restart "streamhost@${TILEDIR}.service" >/dev/null 2>&1 || {
      echo "reset $OSID: FAIL (cold service restart)" >&2
      exit 5
    }
    echo "reset $OSID: OK (cold service restart $TILEDIR)"
    exit 0
    ;;
  pve-rollback)
    case "$PVE_VMID" in
      '' | - | *[!0-9]*)
        echo "reset $OSID: FAIL (invalid PVE VMID '$PVE_VMID')" >&2
        exit 4
        ;;
    esac
    if [ "$SNAP" != "golden" ]; then
      echo "reset $OSID: FAIL (PVE snapshot must be golden, got '$SNAP')" >&2
      exit 4
    fi
    qm rollback "$PVE_VMID" golden >/dev/null 2>&1 || {
      echo "reset $OSID: FAIL (qm rollback $PVE_VMID golden)" >&2
      exit 5
    }
    systemctl restart "streamhost@${TILEDIR}.service" >/dev/null 2>&1 || {
      echo "reset $OSID: FAIL (streamhost re-attach)" >&2
      exit 5
    }
    echo "reset $OSID: OK (PVE rollback golden on VM $PVE_VMID; re-attached $TILEDIR)"
    exit 0
    ;;
  *)
    echo "reset $OSID: FAIL (unknown resetMode '$RESETMODE')" >&2
    exit 6
    ;;
esac

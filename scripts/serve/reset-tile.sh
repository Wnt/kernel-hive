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
#              streamhost@<stationDir> so the daemon re-attaches to the new QMP
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
# IN-PROCESS CONTROL-SOCKET RESET (relaunch mode; nokia9300 is the first user).
# A station whose emulator is SUPERVISED by its own launcher — an inner loop that
# relaunches it from the golden whenever it exits — resets by asking the running
# emulator to exit. The daemon keeps streaming the same display the whole time,
# so the visitor's stream never drops (a service restart would drop it). The
# station says so in station.env:
#   SH_RESET_CTL_SOCK=<path>   a line-protocol control socket: one greeting line
#                              on connect, one command line in, one `OK …`/`ERR …`
#                              line out (EKA2L1's ekactl/1). Relative = to the
#                              station dir, so rig and production share the line.
#   SH_RESET_CTL_VERB=<verb>   the command that ends the emulator (`quit`).
#   SH_RESET_CTL_MARK=<path>   optional: touched before the verb and removed if
#                              it fails, so the supervisor can tell a requested
#                              exit from a crash — EKA2L1 answers `quit` with
#                              `OK bye` and then segfaults on its way out (rc 139,
#                              measured 2026-09-25), which the inner loop would
#                              otherwise count toward its crash back-off.
# Success waits until the relaunched emulator answers `ping` on a fresh socket.
#
# DARK-LAUNCHED RIGS. A golden-manifest row may carry `stationPath` (the rig's
# station dir, under /data/vms/) and `stationEnv` (its env file; rigs call it
# stream.env). `scripts/dev/darklaunch-station.py publish --reset` writes that
# row, so the Restore button reaches a rig that has no streamhost@ unit. A row
# with a stationPath NEVER falls back to `systemctl restart streamhost@…`: that
# would start the production unit of a station that is not deployed.
#
# Exit 0 on success; prints one status line. Local QEMU kill is by pidfile only
# (inside qemu-streamhost.sh); PVE rollback is limited to the registry VMID.
# ============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${GOLDEN_MANIFEST:-$HERE/golden-manifest.json}"
TILES_ROOT="${STREAMHOST_TILES_DIR:-/data/vms/streamhost/stations}"

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
read -r TILEDIR RESETMODE SNAP PVE_VMID POSTKEYS STATIONPATH STATIONENV < <(
  python3 - "$MANIFEST" "$OSID" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["tiles"]
t=m.get(sys.argv[2])
if not t: print("__MISSING__ __ __ __ - - -"); sys.exit(0)
keys=",".join(t.get("postRestoreKeys") or []) or "-"
print(t["stationDir"], t["resetMode"], t.get("snapshot") or "-", t.get("pveVmid") or "-", keys,
      t.get("stationPath") or "-", t.get("stationEnv") or "-")
PY
)

if [ "$TILEDIR" = "__MISSING__" ]; then
  echo "reset: unknown osId '$OSID' (not in manifest)" >&2
  exit 3
fi

TDIR="$TILES_ROOT/$TILEDIR"
RIG=0
if [ "$STATIONPATH" != "-" ]; then
  case "$STATIONPATH" in
    /data/vms/*) ;;
    *)
      echo "reset $OSID: FAIL (stationPath '$STATIONPATH' is not under /data/vms/)" >&2
      exit 4
      ;;
  esac
  TDIR="$STATIONPATH"
  RIG=1
fi
ENVF="$TDIR/station.env"
[ "$STATIONENV" = "-" ] || ENVF="$STATIONENV"
SOCK="$TDIR/qmp.sock"

envval() { sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -1; }

# ctl_reset <sock> <verb> [proc-match] [mark]: the in-process reset described in the
# header. Prints the one-line detail; non-zero on any failure (the caller falls
# back). A SIGSTOPped emulator (idle-paused) would never answer, so it is
# resumed first, exactly as labctl does before it drives a paused guest.
ctl_reset() {
  local epid state
  epid="$(cat "$TDIR/mame.pid" 2>/dev/null || true)"
  state="$(awk '{print $3}' "/proc/${epid:-0}/stat" 2>/dev/null || true)"
  if [ "$state" = T ] && { [ -z "${3:-}" ] || tr '\0' ' ' <"/proc/$epid/cmdline" | grep -qF -- "$3"; }; then
    kill -CONT "$epid" 2>/dev/null || true
  fi
  [ -z "${4:-}" ] || : >"$4"
  python3 - "$1" "$2" <<'PY'
import socket, sys, time
path, verb = sys.argv[1], sys.argv[2]
def talk(cmd, timeout=10):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(path)
    f = s.makefile("rwb"); f.readline()
    f.write((cmd + "\n").encode()); f.flush()
    reply = f.readline().decode().strip(); s.close()
    return reply
t0 = time.time()
try:
    r = talk(verb)
except OSError as e:
    print(f"ctl {verb}: {e}"); sys.exit(1)
if not r.startswith("OK"):
    print(f"ctl {verb}: {r or 'no reply'}"); sys.exit(1)
gone = False
while time.time() - t0 < 15:          # the old process lets go of the socket
    try:
        talk("ping", 2)
    except OSError:
        gone = True; break
    time.sleep(0.1)
if not gone:
    print(f"ctl {verb}: acked but the emulator still answers after 15 s"); sys.exit(1)
while time.time() - t0 < 60:          # the supervisor's relaunch answers
    try:
        if talk("ping", 2).startswith("OK"):
            print(f"ctl {verb}, relaunched from the golden in {time.time() - t0:.1f} s"); sys.exit(0)
    except OSError:
        pass
    time.sleep(0.2)
print(f"ctl {verb}: the emulator exited but no relaunch answered within 60 s"); sys.exit(1)
PY
  local rc=$?
  [ "$rc" = 0 ] || [ -z "${4:-}" ] || rm -f "$4"
  return "$rc"
}

qmp_loadvm() {
  # human-monitor-command loadvm <snap> over the QMP unix socket. HMP loadvm
  # prints nothing on success; any text (e.g. "no such snapshot") is an error.
  python3 - "$SOCK" "$1" <<'PY'
import socket,json,sys
sock,snap=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
buf=b""; stage=0; out=None; done=False
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
        elif stage==2 and "return" in m:
            out=m["return"]
            txt=(out or "").strip()
            if txt and ("error" in txt.lower() or "no such" in txt.lower() or "does not" in txt.lower()):
                print("LOADVMERR:"+txt); sys.exit(1)
            # The instant-restore golden is saved with the vCPUs STOPPED
            # (-loadvm golden -S at daemon start), so a runtime `loadvm` restores
            # them stopped too — a mid-session Restore would otherwise freeze the
            # whole guest (query-status: prelaunch/running:false), which reads as
            # "the cursor won't move". `cont` resumes it; it is a no-op on an
            # already-running guest, so every loadvm station is safe.
            send({"execute":"cont"}); stage=3
        elif stage==3 and "return" in m: done=True; s.close()
        elif "error" in m: print("QMPERR:"+json.dumps(m["error"])); sys.exit(1)
    if done: break
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
      grep -q '^SH_INPUT_BACKEND=gallery-hid$' "$ENVF" 2>/dev/null; then
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
      # Relative-pointer stations (dbus-rel): the loadvm just teleported the
      # guest cursor to the checkpoint's position behind the daemon's
      # dead-reckoning model. SIGUSR2 = "guest state replaced" -> the bridge
      # re-homes on the next motion (streamhost rel_bridge.rs; the daemon only
      # listens when SH_REL_HOME_ON includes `reset`). Best effort, never fatal.
      if grep -q '^SH_INPUT_BACKEND=dbus-rel$' "$ENVF" 2>/dev/null; then
        REL_PID="$(systemctl show -p MainPID --value "streamhost@${TILEDIR}.service" 2>/dev/null)"
        case "$REL_PID" in
          '' | 0 | *[!0-9]*) ;;
          *) kill -USR2 "$REL_PID" 2>/dev/null || true ;;
        esac
      fi
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
    # MAMECTL-FIRST (2026-09-08): a host-native MAME station whose launcher
    # restored a golden savestate (`-state golden`, MAME_NATIVE_CHECKPOINT=1)
    # can restore it again IN-PROCESS through its ctlsock — `LOADST golden`
    # acks on completion in well under a second on the 8-bit machines (samcoupe
    # 11 KB state, apple2e 27 KB), against the ~16 s a service restart costs:
    # ~10 s for ExecStop to give up on a SIGTERM the shm binary ignores and
    # SIGKILL it, then the relaunch. Same MAME process, same framebuffer
    # mapping, so the frozen-buffer hazard the service restart below exists
    # for does not apply. The service restart stays the fallback for every
    # other case: no ctl socket, no baked state, a SIGSTOPped (idle-paused)
    # emulator that would never ack, or an ERR/timeout from the module.
    # SH_MAME_RESET_INPROCESS=0 opts a station OUT of the in-process path and
    # down to the service restart below. It exists for one measured reason
    # (domainos, 2026-09-10): MAME's apollo driver repaints the screen from
    # its image memory ONLY when apollo_v.cpp's m_update_flag is set, so an
    # in-process LOADST restores the machine — the emulated clock rewinds, the
    # guest forgets the windows it opened — while the PREVIOUS VISITOR'S PIXELS
    # stay on the glass, which is exactly what a reset exists to prevent. A
    # fresh process starts with a blank framebuffer and paints the restored
    # state in full, so the service restart is correct where the fast path is
    # not. Costs ~16 s instead of ~0.4 s; correctness wins. Delete the opt-out
    # when the driver repaints after a restore, not before.
    if [ -f "$ENVF" ]; then
      RSOCK="$(envval SH_RESET_CTL_SOCK)"
      RVERB="$(envval SH_RESET_CTL_VERB)"
      if [ -n "$RSOCK" ] && [ -n "$RVERB" ]; then
        case "$RSOCK" in /*) ;; *) RSOCK="$TDIR/$RSOCK" ;; esac
        RMARK="$(envval SH_RESET_CTL_MARK)"
        case "$RMARK" in '' | /*) ;; *) RMARK="$TDIR/$RMARK" ;; esac
        if [ -S "$RSOCK" ] && OUT="$(ctl_reset "$RSOCK" "$RVERB" "$(envval SH_IDLE_PAUSE_PROC_MATCH)" "$RMARK" 2>&1)"; then
          echo "reset $OSID: OK ($OUT on $TILEDIR, in-process; the stream stays up)"
          exit 0
        fi
        echo "reset $OSID: in-process ctl reset failed on $TILEDIR (${OUT:-no socket at $RSOCK})" >&2
      fi
      CTL="$(envval SH_MAMECTL_SOCK)"
      DRV="$(envval MAME_NATIVE_DRIVER)"
      CKPT="$(envval MAME_NATIVE_CHECKPOINT)"
      INPROC="$(envval SH_MAME_RESET_INPROCESS)"
      EPID="$(cat "$TDIR/mame.pid" 2>/dev/null || true)"
      ESTATE="$(awk '{print $3}' "/proc/${EPID:-0}/stat" 2>/dev/null || true)"
      # THE SAME FAST PATH FOR A NON-MAME mamectl STATION. Every condition
      # above this line is MAME's file layout — a driver name and a
      # `sta/<driver>/golden.sta` on disk — which a station whose emulator
      # keeps its checkpoints in its own format cannot satisfy, so `indyr4400`
      # (host-native Iris) would always have paid the full service restart:
      # ~30 s of container teardown, startup restore and first frame, against
      # a measured 0.19-0.25 s for the in-process rewind.
      #
      # `SH_RESET_INPROCESS_CHECKPOINT=<name>` in station.env is that station
      # saying "my control socket serves LOADST <name> and it is the reset".
      # The emulator owns the existence check — it answers ERR if the snapshot
      # is missing or its provenance does not match the running binary — so
      # there is nothing to stat here. Every other guard is shared with the
      # MAME path: a real socket, mctl.py present, and an emulator that is not
      # SIGSTOPped (an idle-paused one would never ack).
      #
      # The stale-pixel hazard that made `domainos` opt out does not apply:
      # this station's frame publisher republishes a whole frame
      # unconditionally after every restore (Iris fork, `shmpub` FBSYNC hook),
      # which is the fix domainos's driver lacks.
      KHCP="$(envval SH_RESET_INPROCESS_CHECKPOINT)"
      if [ "${INPROC:-1}" != 0 ] && [ -n "$KHCP" ] && [ -S "${CTL:-/nonexistent}" ] &&
        [ -f /root/mctl.py ] && [ -n "$ESTATE" ] && [ "$ESTATE" != T ] && [ "$ESTATE" != t ]; then
        if OUT="$(python3 /root/mctl.py "$CTL" --timeout 60 LOADST "$KHCP" 2>&1)"; then
          echo "reset $OSID: OK (mamectl LOADST $KHCP on $TILEDIR, in-process)"
          exit 0
        fi
        echo "reset $OSID: mamectl LOADST $KHCP failed on $TILEDIR (${OUT//$'\n'/ }) — falling back to a service restart" >&2
      fi
      if [ "${INPROC:-1}" != 0 ] && [ -S "${CTL:-/nonexistent}" ] && [ -n "$DRV" ] && [ "${CKPT:-1}" = 1 ] &&
        [ -f "$TDIR/sta/$DRV/golden.sta" ] && [ -f /root/mctl.py ] &&
        [ -n "$ESTATE" ] && [ "$ESTATE" != T ] && [ "$ESTATE" != t ]; then
        if OUT="$(python3 /root/mctl.py "$CTL" --timeout 60 LOADST golden 2>&1)"; then
          echo "reset $OSID: OK (mamectl LOADST golden on $TILEDIR, in-process)"
          exit 0
        fi
        echo "reset $OSID: mamectl LOADST golden failed on $TILEDIR (${OUT//$'\n'/ }) — falling back to a service restart" >&2
      fi
    fi
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
    if [ "$RIG" = 1 ]; then
      echo "reset $OSID: FAIL (dark-launched rig at $TDIR: no in-process reset answered, and a rig has no streamhost@ unit to restart)" >&2
      exit 5
    fi
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

#!/usr/bin/env bash
# verify-tile.sh <osId> [--restore] [--evidence DIR]
#
# Mechanical portion of docs/lab/ADD-NEW-OS-PLAYBOOK.md section 7.3.
# Runs on the lab box. The default is strictly read-only: HTTPS GETs, QMP
# query/screendump, systemd-derived labctl health, and bundle reads. --restore
# opts into the manifest's restore action only after a zero-session health gate.
set -uo pipefail

OSID="${1:-}"
if [ -z "$OSID" ] || [ "$OSID" = "-h" ] || [ "$OSID" = "--help" ]; then
  echo "usage: verify-tile.sh <osId> [--restore] [--evidence DIR]" >&2
  exit "$([ -n "$OSID" ] && echo 0 || echo 2)"
fi
shift

DO_RESTORE=0
EVIDENCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --restore) DO_RESTORE=1 ;;
    --evidence)
      [ "$#" -ge 2 ] || {
        echo "verify-tile: --evidence needs a directory" >&2
        exit 2
      }
      EVIDENCE="$2"
      shift
      ;;
    *)
      echo "verify-tile: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

LABCTL="${LABCTL:-labctl}"
BASE_URL="${VERIFY_TILE_BASE_URL:-https://192.0.2.10:8443}"
MATRIX="${LABCTL_TILES_JSON:-/data/vms/streamhost/tiles.json}"
MANIFEST="${GOLDEN_MANIFEST:-/data/vms/streamhost/serve/golden-manifest.json}"
RESET_TOOL="${RESET_TOOL:-/data/vms/streamhost/serve/reset-tile.sh}"
WEBROOT="${WEBROOT:-/data/vms/streamhost/serve/webroot}"
IDLE_DELAY="${VERIFY_IDLE_DELAY_SECS:-2}"
RESTORE_DELAY="${VERIFY_RESTORE_SETTLE_SECS:-3}"
IDLE_SSIM="${VERIFY_IDLE_SSIM:-0.995}"
GOLDEN_SSIM="${VERIFY_GOLDEN_SSIM:-0.995}"
MIN_NONBLACK="${VERIFY_MIN_NONBLACK_PCT:-0.1}"

PASS_COUNT=0
FAIL_COUNT=0
PARK_COUNT=0
pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %-24s %s\n' "$1" "$2"
}
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %-24s %s\n' "$1" "$2"
}
park() {
  PARK_COUNT=$((PARK_COUNT + 1))
  printf 'PARK  %-24s %s\n' "$1" "$2"
}

for required in python3 curl ffmpeg "$LABCTL"; do
  command -v "$required" >/dev/null 2>&1 || {
    fail prerequisites "missing command: $required"
    printf '\nSUMMARY: %d PASS, %d FAIL, %d PARK\n' "$PASS_COUNT" "$FAIL_COUNT" "$PARK_COUNT"
    exit 1
  }
done

[ -r "$MATRIX" ] || {
  fail matrix "not readable: $MATRIX"
  exit 1
}
[ -r "$MANIFEST" ] || {
  fail golden-manifest "not readable: $MANIFEST"
  exit 1
}

META="$(
  python3 - "$MANIFEST" "$MATRIX" "$OSID" <<'PY'
import json, sys
manifest, matrix, osid = sys.argv[1:]
try:
    reset = json.load(open(manifest))["tiles"].get(osid)
    if not reset:
        raise KeyError("osId is absent from golden manifest")
    tile = reset["tileDir"]
    conf = json.load(open(matrix))["tiles"].get(tile)
    if not conf:
        raise KeyError("tileDir is absent from live capability matrix")
    print("|".join((tile, conf["qmp"], str(conf.get("udp_port") or ""),
                     str(conf.get("exec_kind") or ""), reset.get("resetMode", ""))))
except Exception as exc:
    print("ERROR|%s" % exc)
PY
)"
if [[ "$META" == ERROR\|* ]]; then
  fail identity "${META#*|}"
  printf '\nSUMMARY: %d PASS, %d FAIL, %d PARK\n' "$PASS_COUNT" "$FAIL_COUNT" "$PARK_COUNT"
  exit 1
fi
IFS='|' read -r TILE QMP UDP_PORT EXEC_KIND RESET_MODE <<<"$META"
pass identity "osId=$OSID tileDir=$TILE reset=$RESET_MODE"

if [ -n "$EVIDENCE" ]; then
  mkdir -p "$EVIDENCE" || {
    fail evidence "cannot create $EVIDENCE"
    exit 1
  }
  KEEP_EVIDENCE=1
else
  EVIDENCE="$(mktemp -d "/tmp/verify-tile-${OSID}.XXXXXX")" || exit 1
  KEEP_EVIDENCE=0
fi
cleanup() { [ "$KEEP_EVIDENCE" -eq 1 ] || rm -rf "$EVIDENCE"; }
trap cleanup EXIT

# HTTPS signaling: require a 200 and validate without printing the certificate hash.
SIGNAL="$EVIDENCE/signal.json"
HTTP_CODE="$(curl -ksS -o "$SIGNAL" -w '%{http_code}' "$BASE_URL/signal/$OSID.json" 2>/dev/null || true)"
SIGNAL_RESULT="$(
  python3 - "$SIGNAL" "$UDP_PORT" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ok = (isinstance(d.get("host"), str) and bool(d["host"]) and
          isinstance(d.get("udpPort"), int) and d["udpPort"] > 0 and
          isinstance(d.get("certHashB64"), str) and bool(d["certHashB64"]))
    if sys.argv[2]: ok = ok and d["udpPort"] == int(sys.argv[2])
    print("ok" if ok else "invalid fields or UDP mismatch")
except Exception as exc:
    print("invalid JSON: %s" % type(exc).__name__)
PY
)"
if [ "$HTTP_CODE" = 200 ] && [ "$SIGNAL_RESULT" = ok ]; then
  pass signal-json "HTTP 200; host/udpPort/certHashB64 valid; UDP=$UDP_PORT"
else
  fail signal-json "HTTP=${HTTP_CODE:-error}; $SIGNAL_RESULT"
fi

# qmp_screendump is read-only. It deliberately does not issue cont first.
qmp_screendump() {
  python3 - "$QMP" "$1" <<'PY'
import json, os, socket, sys, time
sock_path, out = sys.argv[1:]
try: os.unlink(out)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(20); s.connect(sock_path)
f = s.makefile("rwb", buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    m=json.loads(f.readline())
    if "return" in m: break
command={"execute":"human-monitor-command","arguments":{"command-line":"screendump %s -f ppm" % out}}
f.write((json.dumps(command)+"\n").encode())
while True:
    m=json.loads(f.readline())
    if "error" in m: raise RuntimeError(m["error"].get("desc", "QMP error"))
    if "return" in m: break
s.close()
for _ in range(40):
    if os.path.getsize(out) if os.path.exists(out) else 0: break
    time.sleep(.1)
if not os.path.exists(out) or os.path.getsize(out) == 0: raise RuntimeError("empty screendump")
PY
}

ppm_stats() {
  python3 - "$1" <<'PY'
import sys
d=open(sys.argv[1],'rb').read(); i=0
def token():
    global i
    while i < len(d):
        if d[i:i+1] == b'#':
            i=d.find(b'\n',i)+1
        elif d[i] in b' \t\r\n': i+=1
        else: break
    j=i
    while i < len(d) and d[i] not in b' \t\r\n#': i+=1
    return d[j:i]
magic=token(); w=int(token()); h=int(token()); maxv=int(token())
while i < len(d) and d[i] in b' \t\r\n': i+=1
if magic != b'P6' or maxv != 255: raise SystemExit(2)
pixels=d[i:i+w*h*3]
if len(pixels) != w*h*3: raise SystemExit(2)
step=max(1,(w*h)//200000)
n=nb=0
for p in range(0,w*h,step):
    j=p*3; n+=1
    if pixels[j]+pixels[j+1]+pixels[j+2] > 30: nb+=1
print("%dx%d %.4f" % (w,h,100.0*nb/max(1,n)))
PY
}

ssim() {
  ffmpeg -hide_banner -nostats -i "$1" -i "$2" \
    -lavfi '[0:v]format=gray[x];[1:v]format=gray[y];[x][y]ssim' \
    -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1
}

numeric_ge() {
  python3 - "$1" "$2" <<'PY'
import sys
try: raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
except ValueError: raise SystemExit(1)
PY
}

FRAME_A="$EVIDENCE/idle-a.ppm"
FRAME_B="$EVIDENCE/idle-b.ppm"
FRAME_OK=0
IDLE_OK=0
if qmp_screendump "$FRAME_A" 2>"$EVIDENCE/screendump.err"; then
  STATS="$(ppm_stats "$FRAME_A" 2>/dev/null || true)"
  read -r DIMS NONBLACK <<<"$STATS"
  if [ -n "${NONBLACK:-}" ] && numeric_ge "$NONBLACK" "$MIN_NONBLACK"; then
    FRAME_OK=1
    pass framebuffer "QMP screendump $DIMS; non-black=${NONBLACK}%"
  else
    fail framebuffer "undecodable or black frame (${STATS:-no stats})"
  fi
else
  fail framebuffer "QMP screendump failed (details kept only in evidence)"
fi

if [ -s "$FRAME_A" ]; then
  sleep "$IDLE_DELAY"
  if qmp_screendump "$FRAME_B" 2>"$EVIDENCE/screendump-2.err"; then
    if cmp -s "$FRAME_A" "$FRAME_B"; then
      IDLE_SCORE=1.000000
      IDLE_OK=1
      pass idle-determinism "byte-identical over ${IDLE_DELAY}s"
    else
      IDLE_SCORE="$(ssim "$FRAME_A" "$FRAME_B")"
      if [ -n "$IDLE_SCORE" ] && numeric_ge "$IDLE_SCORE" "$IDLE_SSIM"; then
        IDLE_OK=1
        pass idle-determinism "SSIM=$IDLE_SCORE over ${IDLE_DELAY}s (need >=$IDLE_SSIM)"
      else
        fail idle-determinism "SSIM=${IDLE_SCORE:-unavailable} over ${IDLE_DELAY}s (need >=$IDLE_SSIM)"
      fi
    fi
  else
    fail idle-determinism "second QMP screendump failed"
  fi
else
  fail idle-determinism "no first framebuffer"
fi

if [ "$DO_RESTORE" -eq 1 ]; then
  HEALTH_JSON="$($LABCTL health "$TILE" --json 2>/dev/null || true)"
  read -r SESSIONS HEALTHY <<<"$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("sessions",-1), str(bool(d.get("healthy"))).lower())' <<<"$HEALTH_JSON" 2>/dev/null || echo '-1 false')"
  if [ "$SESSIONS" != 0 ]; then
    fail golden-roundtrip "REFUSED restore: health reports sessions=$SESSIONS (must be zero)"
  elif [ "$HEALTHY" != true ]; then
    fail golden-roundtrip "REFUSED restore: tile health is not healthy"
  elif [ "$FRAME_OK" -ne 1 ] || [ "$IDLE_OK" -ne 1 ]; then
    fail golden-roundtrip "REFUSED restore: live reference was not non-black and idle-deterministic"
  elif [ ! -x "$RESET_TOOL" ]; then
    fail golden-roundtrip "reset tool is not executable"
  elif [ ! -s "$FRAME_A" ]; then
    fail golden-roundtrip "no pre-restore idle reference"
  elif "$RESET_TOOL" "$OSID" >"$EVIDENCE/restore.out" 2>"$EVIDENCE/restore.err"; then
    sleep "$RESTORE_DELAY"
    RESTORED="$EVIDENCE/restored.ppm"
    if qmp_screendump "$RESTORED" 2>"$EVIDENCE/screendump-restored.err"; then
      if cmp -s "$FRAME_A" "$RESTORED"; then
        pass golden-roundtrip "restore -> golden; byte-identical to idle reference"
      else
        SCORE="$(ssim "$FRAME_A" "$RESTORED")"
        if [ -n "$SCORE" ] && numeric_ge "$SCORE" "$GOLDEN_SSIM"; then
          pass golden-roundtrip "restore -> golden; SSIM=$SCORE (need >=$GOLDEN_SSIM)"
        else
          fail golden-roundtrip "restore completed; SSIM=${SCORE:-unavailable} (need >=$GOLDEN_SSIM)"
        fi
      fi
    else
      fail golden-roundtrip "restore completed; post-restore screendump failed"
    fi
  else
    fail golden-roundtrip "manifest restore failed (details kept only in evidence)"
  fi
else
  park golden-roundtrip "read-only default; rerun on an idle tile with --restore"
fi

if [ -n "$EXEC_KIND" ] && [ "$EXEC_KIND" != none ]; then
  HEALTH_JSON="${HEALTH_JSON:-$($LABCTL health "$TILE" --json 2>/dev/null || true)}"
  QEMU_STATE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("qemu_status","unknown"))' <<<"$HEALTH_JSON" 2>/dev/null || echo unknown)"
  if [ "$QEMU_STATE" = paused ] && [ "$DO_RESTORE" -ne 1 ]; then
    park exec-exit-0 "wired ($EXEC_KIND), but read-only run will not resume idle-paused QEMU"
  elif "$LABCTL" exec "$TILE" "uname -a" >/dev/null 2>"$EVIDENCE/exec.err"; then
    pass exec-exit-0 "wired via $EXEC_KIND; uname -a exited 0"
  else
    fail exec-exit-0 "wired via $EXEC_KIND; command failed"
  fi
else
  park exec-exit-0 "no captured-output exec channel declared"
fi

# Scan textual bundle assets for high-risk private material. Optional colon-
# separated VERIFY_TILE_SECRET_FILES are compared in-process and never printed,
# placed in argv, or copied to evidence.
if python3 - "$WEBROOT" <<'PY'; then
import os, pathlib, re, sys
root=pathlib.Path(sys.argv[1])
if not root.is_dir(): raise SystemExit(2)
patterns=re.compile(rb'BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|humanify-token|clientcmd\.token|rootCA\.key|/root/\.ssh/(?:id_|lab_key)|\b(?:uptoken|unifitoken)\b')
secrets=[]
for name in os.environ.get('VERIFY_TILE_SECRET_FILES','').split(':'):
    if not name: continue
    try:
        for line in pathlib.Path(name).read_bytes().splitlines():
            line=line.strip()
            if len(line) >= 8: secrets.append(line)
    except OSError: raise SystemExit(2)
for path in root.rglob('*'):
    if not path.is_file() or path.suffix.lower() not in {'.js','.css','.html','.json','.map'}: continue
    try: data=path.read_bytes()
    except OSError: raise SystemExit(2)
    if patterns.search(data) or any(secret in data for secret in secrets): raise SystemExit(1)
PY
  pass bundle-secret-scan "no private-key/token/path markers or supplied secret values found"
else
  rc=$?
  if [ "$rc" -eq 1 ]; then
    fail bundle-secret-scan "potential credential material found (value/path suppressed)"
  else fail bundle-secret-scan "bundle or optional secret source unreadable"; fi
fi

printf '\nHUMAN RESIDUAL (irreducibly visual / interactive)\n'
printf '  PARK  placard/archetype appears exactly once and is historically correct\n'
printf '  PARK  browser receives moving frames and audio (where enabled)\n'
printf '  PARK  pointer edges, click/drag/wheel, keyboard, pointer-lock and touch semantics\n'
printf '  PARK  reset fixture looks curated and accepts input immediately\n'
printf '  PARK  cold restart reaches the fixture without human action\n'
printf '  PARK  optional boot clip audio/scrub/handoff seam\n'
printf '  PARK  stopping/restarting this tile does not affect another tile\n'

printf '\nSUMMARY: %d PASS, %d FAIL, %d PARK (plus 7 human residual)\n' \
  "$PASS_COUNT" "$FAIL_COUNT" "$PARK_COUNT"
if [ "$KEEP_EVIDENCE" -eq 1 ]; then printf 'Evidence: %s\n' "$EVIDENCE"; fi
[ "$FAIL_COUNT" -eq 0 ]

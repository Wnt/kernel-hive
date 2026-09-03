#!/usr/bin/env bash
# wave.d/alloc.sh — ONE atomic allocation of everything a station wave shares.
#
# Runs ON LABHOST (shipped there by `wave.sh alloc` via labrun; it needs
# kh-claim, the box registry and, for --retronet, root to re-render DHCP).
# Never call it by hand — `scripts/dev/wave.sh alloc <id>` is the door.
#
# usage: alloc.sh <id> <session> <retronet 0|1> <x11warp 0|1> <apply 0|1>
#
# It prints a KEY=VALUE block on stdout (wave.sh turns that into the ledger row
# and .wave.env) and narrates on stderr. Everything shared is taken through
# kh-claim under <session>: a value another session holds is a hard failure
# with the holder named, never a silent bump (AGENTS.md rule 7).
#
# IDEMPOTENT for the same session: re-running reuses the slot/address this
# session already holds and skips the local.env edit when RN_<ID>_MAC is
# already there. It is NOT idempotent across sessions — that is the point.
set -uo pipefail

id="${1:-}"
session="${2:-}"
want_rn="${3:-0}"
want_x11="${4:-0}"
apply="${5:-0}"
[ -n "$id" ] && [ -n "$session" ] || {
  echo "alloc.sh: usage: alloc.sh <id> <session> <rn 0|1> <x11 0|1> <apply 0|1>" >&2
  exit 2
}
export KH_SESSION="$session"

REG=/data/kernel-hive/registry
LOCAL_ENV="$REG/local.env"
INSTALL_DHCP=/data/kernel-hive/scripts/retronet/web/install-dhcp.sh
ID_UP="$(printf '%s' "$id" | tr '[:lower:]-' '[:upper:]_')"

say() { printf '   %s\n' "$*" >&2; }
die() {
  printf 'wave alloc: FAIL: %s\n' "$*" >&2
  exit 1
}
take() { # take <class> <name> <purpose> — refuse loudly, never bump
  kh-claim take "$1" "$2" --purpose "$3" >/dev/null 2>&1 && {
    say "claimed $1 $2"
    return 0
  }
  local who
  who="$(kh-claim who "$1" "$2" 2>&1 | tr '\n' ' ')"
  case "$who" in
    *"$session"*)
      say "claimed $1 $2 (already mine)"
      return 0
      ;;
  esac
  die "$1 $2 is held by someone else — $who"
}
mine() { # mine <class> -> the first name of <class> this session holds
  kh-claim ls --mine --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for c in json.load(sys.stdin) or []:
    if c.get("class") == want:
        print(c["name"])
        break
' "$1" 2>/dev/null
}

# ---- slot / UDP port / VMID -------------------------------------------------
# Same next-free rule smoke-rig.sh and the registry scaffold use: above every
# registry slot AND every slot claim anyone holds.
slot="$(mine slot)"
if [ -z "$slot" ]; then
  slot="$(
    python3 - <<'PY'
import glob, json, subprocess
taken = set()
for f in glob.glob("/data/kernel-hive/registry/stations/*.json"):
    try:
        taken.add(int(json.load(open(f)).get("stream", {}).get("slot", 0)))
    except Exception:
        pass
try:
    for c in json.loads(subprocess.run(["kh-claim", "ls", "--all", "--json"],
                                       capture_output=True, text=True).stdout or "[]"):
        if c.get("class") == "slot" and str(c.get("name", "")).isdigit():
            taken.add(int(c["name"]))
except Exception:
    pass
print(max(taken or {99}) + 1)
PY
  )"
fi
[ "$slot" -ge 101 ] 2>/dev/null || die "computed slot '$slot' is not a sane station slot (>=101)"
port=$((54000 + slot))
take slot "$slot" "$id station slot (wave $session)"
take port "$port" "$id streamhost UDP (slot $slot)"
take vmid "$slot" "$id VMID label (slot $slot)"

echo "WAVE_ID=$id"
echo "WAVE_SESSION=$session"
echo "WAVE_SLOT=$slot"
echo "WAVE_UDP_PORT=$port"
echo "WAVE_VMID=$slot"

# ---- x11warp display --------------------------------------------------------
# Convention from the 2026-09-03 waves: display :<slot-100>, reached through a
# loopback hostfwd on 6<slot-100> (slot 179 -> :79 -> 127.0.0.1:6079).
if [ "$want_x11" = 1 ]; then
  dnum=$((slot - 100))
  dport=$((6000 + dnum))
  take display ":$dnum" "$id x11warp guest display (slot $slot)"
  take port "$dport" "$id x11warp loopback door (display :$dnum)"
  echo "WAVE_X11_DISPLAY=:$dnum"
  echo "WAVE_X11_HOSTFWD=127.0.0.1:$dport"
  echo "WAVE_SH_X11WARP_DISPLAY=127.0.0.1:$dnum"
fi

# ---- retronet address / MAC / tap / chain / UIN -----------------------------
if [ "$want_rn" = 1 ]; then
  addr="$(mine rnip)"
  if [ -z "$addr" ]; then
    addr="$(
      python3 - <<'PY'
import glob, json, re, subprocess, sys
taken = {1, 2}  # .1 labhost side, .2 the gateway CT
for f in glob.glob("/data/kernel-hive/registry/stations/*.json"):
    try:
        a = (json.load(open(f)).get("retronet") or {}).get("address") or ""
    except Exception:
        continue
    m = re.match(r"^10\.99\.0\.(\d+)$", a)
    if m:
        taken.add(int(m.group(1)))
try:
    for line in open("/data/kernel-hive/registry/local.env"):
        if line.startswith("RETRONET_DHCP_RESERVATIONS"):
            for m in re.finditer(r"10\.99\.0\.(\d+)", line):
                taken.add(int(m.group(1)))
except OSError:
    pass
try:
    for c in json.loads(subprocess.run(["kh-claim", "ls", "--all", "--json"],
                                       capture_output=True, text=True).stdout or "[]"):
        if c.get("class") == "rnip":
            m = re.match(r"^10\.99\.0\.(\d+)$", str(c.get("name", "")))
            if m:
                taken.add(int(m.group(1)))
except Exception:
    pass
n = max(taken) + 1
# The DHCP pool is .100-.200; a reservation must stay out of it.
if n > 99:
    sys.exit("retronet host range 10.99.0.3-.99 is full")
print("10.99.0.%d" % n)
PY
    )"
    [ -n "$addr" ] || die "could not compute a free retronet address (range full?)"
  fi
  n="${addr##*.}"
  mac="$(printf '52:54:00:52:4e:%02x' "$n")"
  tap="${id}rn0"
  chain="$(printf '%sRN-IN' "$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')")"
  uin="${slot}00"
  take rnip "$addr" "$id retronet address"
  take tap "$tap" "$id retronet tap on vmbr-rn"
  take chain "$chain" "$id retronet guard chain"
  take uin "$uin" "$id retronet ICQ UIN"
  echo "WAVE_RN_ADDRESS=$addr"
  echo "WAVE_RN_MAC=$mac"
  echo "WAVE_RN_TAP=$tap"
  echo "WAVE_RN_CHAIN=$chain"
  echo "WAVE_RN_UIN=$uin"
  echo "WAVE_RN_MAC_VAR=RN_${ID_UP}_MAC"

  # local.env: the reservation ledger AND the launcher's own MAC variable, in
  # ONE rewrite. scripts/lib/local-env.sh parses KEY=VALUE literally (it does
  # NOT expand $VAR and it keeps the FIRST assignment of a key), so appending a
  # second, self-referencing RETRONET_DHCP_RESERVATIONS= line would be read as
  # the literal string and ignored. The value is edited in place instead, with
  # a timestamped backup beside it.
  if grep -q "^RN_${ID_UP}_MAC=" "$LOCAL_ENV" 2>/dev/null; then
    say "local.env already carries RN_${ID_UP}_MAC — not touching it"
  elif [ "$apply" = 0 ]; then
    say "PLAN: add $mac=$addr to RETRONET_DHCP_RESERVATIONS and RN_${ID_UP}_MAC=$mac in $LOCAL_ENV"
    say "PLAN: $INSTALL_DHCP --apply install   (the reservation is NOT live until this runs)"
  else
    [ -w "$LOCAL_ENV" ] || die "$LOCAL_ENV not writable (run this as root on labhost)"
    cp -a "$LOCAL_ENV" "$LOCAL_ENV.bak-wave-$(date -u +%Y%m%dT%H%M%SZ)"
    python3 - "$LOCAL_ENV" "$mac" "$addr" "RN_${ID_UP}_MAC" <<'PY' || die "local.env edit failed"
import sys
path, mac, addr, macvar = sys.argv[1:5]
lines = open(path).read().splitlines()
pair = "%s=%s" % (mac, addr)
hit = False
for i, ln in enumerate(lines):
    if ln.startswith("RETRONET_DHCP_RESERVATIONS="):
        v = ln.split("=", 1)[1].strip()
        q = v[0] if v[:1] in ('"', "'") else ""
        inner = v[1:-1] if q and v.endswith(q) and len(v) > 1 else v
        if pair not in inner.split():
            inner = (inner + " " + pair).strip()
        lines[i] = 'RETRONET_DHCP_RESERVATIONS=%s%s%s' % (q or '"', inner, q or '"')
        hit = True
        break
if not hit:
    lines.append('RETRONET_DHCP_RESERVATIONS="%s"' % pair)
lines.append("%s=%s" % (macvar, mac))
open(path, "w").write("\n".join(lines) + "\n")
PY
    say "local.env: reservation $mac=$addr + RN_${ID_UP}_MAC written (backup kept)"
    say "re-rendering DHCP in CT 951 (a local.env edit alone is NOT live)"
    "$INSTALL_DHCP" --apply install >&2 || die "install-dhcp.sh --apply install failed"
    say "DHCP re-rendered; verify with: $INSTALL_DHCP verify"
  fi
fi

say "allocation complete for $id under session $session"

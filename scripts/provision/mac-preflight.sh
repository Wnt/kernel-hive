#!/usr/bin/env bash
# mac-preflight.sh — verify the Mac is ready to drive the NVMe migration BEFORE
# labhost goes offline. Run this on the Mac while CT950 is still alive; fix
# every [FAIL] before taking the hardware down (once CT950 is gone you cannot
# re-fetch the secrets/memory it holds).
#
#   scripts/provision/mac-preflight.sh
#
# Override defaults via env:
#   ASSETS_DIR=~/osgallery-assets-staging   (copied from box /data/assets-staging)
#   ISO_DIR=~/osgallery-migration-isos       (PVE + SystemRescue ISOs)
#   VZDUMP_DIR=~                              (where the CT950 vzdump landed)
#   BMC_HOST=192.0.2.13  LAB=lab  DEV=osgallery-dev
#
# It reads nothing secret — only checks that secret FILES exist and are non-empty.
set -u

LAB="${LAB:-lab}"
DEV="${DEV:-osgallery-dev}"
BMC_HOST="${BMC_HOST:-192.0.2.13}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ASSETS_DIR="${ASSETS_DIR:-$HOME/osgallery-assets-staging}"
ISO_DIR="${ISO_DIR:-$HOME/osgallery-migration-isos}"
VZDUMP_DIR="${VZDUMP_DIR:-$HOME}"
MAC_MEM="${MAC_MEM:-$HOME/.claude/projects/-Users-wnt-osgallery/memory}"

P=0
F=0
W=0
if [ -t 1 ]; then
  G=$'\033[32m'
  R=$'\033[31m'
  Y=$'\033[33m'
  D=$'\033[2m'
  Z=$'\033[0m'
else
  G=
  R=
  Y=
  D=
  Z=
fi
pass() {
  printf '  %sPASS%s %s\n' "$G" "$Z" "$1"
  P=$((P + 1))
}
fail() {
  printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"
  F=$((F + 1))
}
warn() {
  printf '  %sWARN%s %s\n' "$Y" "$Z" "$1"
  W=$((W + 1))
}
sec() { printf '\n%s== %s ==%s\n' "$D" "$1" "$Z"; }
have() { command -v "$1" >/dev/null 2>&1; }
sz() { wc -c <"$1" 2>/dev/null | tr -d ' '; }
nonempty() { [ -f "$1" ] && [ "$(sz "$1")" -gt 0 ] 2>/dev/null; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"

sec "Local tooling (Mac needs ONLY these — do NOT install a full dev stack here)"
for t in ssh scp rsync curl python3 git; do
  have "$t" && pass "$t present" || fail "$t missing"
done
have ipmitool && pass "ipmitool present" || fail "ipmitool missing (brew install ipmitool)"
if have shasum; then SHA="shasum -a 256"; elif have sha256sum; then SHA="sha256sum"; else
  SHA=""
  warn "no shasum/sha256sum — cannot verify bundle integrity"
fi

sec "Repo"
if [ -d "$REPO/.git" ]; then
  br="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$br" = main ] && pass "on branch main" || warn "on branch '$br' (expected main)"
  git -C "$REPO" fetch -q origin 2>/dev/null
  la="$(git -C "$REPO" rev-list --count '@{u}..HEAD' 2>/dev/null || echo '?')"
  be="$(git -C "$REPO" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo '?')"
  [ "$la" = 0 ] && [ "$be" = 0 ] && pass "in sync with origin/main" || warn "not in sync (ahead $la / behind $be) — git pull"
else fail "no git repo at $REPO"; fi

sec "Connectivity (both must work NOW — CT950 holds secrets + memory)"
if $SSH "$LAB" true 2>/dev/null; then pass "ssh $LAB (the box) reachable"; else fail "ssh $LAB failed — fix ~/.ssh/config + lab_key"; fi
if $SSH "$DEV" true 2>/dev/null; then pass "ssh $DEV (CT950) reachable"; else fail "ssh $DEV failed — needed to sync secrets/memory"; fi

sec "Gitignored secrets synced into the Mac clone (existence/size only)"
# gallery-credentials.md carries the BMC password → the Mac needs it NOW to drive
# Redfish. It is a hard requirement.
if nonempty "$REPO/docs/gallery-credentials.md"; then
  pass "docs/gallery-credentials.md present ($(sz "$REPO/docs/gallery-credentials.md") B) — has the BMC creds"
else fail "docs/gallery-credentials.md missing — needed NOW for BMC/Redfish; scp from $DEV"; fi
# The rest are insurance: they ride back inside CT950's subvol on restore, and are only
# needed if you must rebuild CT950 from scratch (provision-dev-ct.sh). Sync them anyway.
for f in uptoken unifitoken spa/src/data/credentials.ts; do
  nonempty "$REPO/$f" && pass "$f present ($(sz "$REPO/$f") B)" || warn "$f not synced — insurance only (rides back in CT950's subvol); scp from $DEV to be safe"
done
# PKI: the CA cert is worth carrying to avoid re-trusting; the leaf is regenerated on
# the new box by gen-local-ca.sh (IP unchanged). Not a blocker.
if [ -f "$REPO/scripts/serve/pki/rootCA.pem" ]; then
  pass "scripts/serve/pki/rootCA.pem present (leaf regenerates via gen-local-ca.sh)"
else warn "scripts/serve/pki/rootCA.pem absent — regenerable on the new box; carry it only to skip re-trusting the CA"; fi

sec "Claude memory synced to the Mac project path (session continuity)"
if [ -d "$MAC_MEM" ] && ls "$MAC_MEM"/*.md >/dev/null 2>&1; then
  # shellcheck disable=SC2012 # counting our own memory *.md files; filenames are not adversarial
  pass "memory present ($(ls "$MAC_MEM"/*.md | wc -l | tr -d ' ') files) at $MAC_MEM"
else fail "no memory at $MAC_MEM — rsync from $DEV:~/.claude/.../memory/"; fi

sec "Staged assets bundle copied off the box (irreplaceable inputs)"
if [ -d "$ASSETS_DIR" ]; then
  if [ -f "$ASSETS_DIR/MANIFEST.sha256" ] && [ -n "$SHA" ]; then
    if (cd "$ASSETS_DIR" && $SHA -c MANIFEST.sha256 >/dev/null 2>&1); then
      pass "assets bundle verified against MANIFEST.sha256 ($ASSETS_DIR)"
    else fail "assets bundle FAILS checksum — re-copy from $LAB:/data/assets-staging/"; fi
  else warn "assets dir exists but no MANIFEST.sha256 to verify"; fi
else fail "no assets bundle at $ASSETS_DIR — rsync from $LAB:/data/assets-staging/"; fi

sec "CT950 vzdump (belt-and-braces dev-seat backup for pct restore)"
if ls "$VZDUMP_DIR"/vzdump-lxc-950-*.zst "$VZDUMP_DIR"/vzdump-lxc-950-*.tar* >/dev/null 2>&1; then
  # shellcheck disable=SC2012 # picking the first vzdump archive by name; our own predictable backup filenames, not adversarial
  vd="$(ls -1 "$VZDUMP_DIR"/vzdump-lxc-950-* 2>/dev/null | head -1)"
  pass "CT950 vzdump present ($(basename "$vd"))"
else warn "no CT950 vzdump in $VZDUMP_DIR — 'vzdump 950' on the box + scp (fastest seat-return path)"; fi

sec "Install media downloaded"
# shellcheck disable=SC2012 # naming the first matching ISO by name; our own downloaded-media filenames, not adversarial
if ls "$ISO_DIR"/proxmox-ve_*.iso >/dev/null 2>&1; then pass "PVE ISO present ($(ls "$ISO_DIR"/proxmox-ve_*.iso | head -1 | xargs basename))"; else fail "no proxmox-ve_*.iso in $ISO_DIR"; fi
if ls "$ISO_DIR"/*ystem*escue*.iso >/dev/null 2>&1 || ls "$ISO_DIR"/*ystemRescue*.iso >/dev/null 2>&1; then pass "SystemRescue ISO present"; else warn "no SystemRescue ISO in $ISO_DIR (rescue/rollback aid)"; fi

sec "Provisioning kit present + Range serving works on THIS Mac's python3"
KIT="$REPO/scripts/provision"
for f in isoserver.py boot.ipxe.tmpl pve-answer.toml.tmpl README.md; do
  [ -f "$KIT/$f" ] && pass "provision/$f present" || fail "provision/$f MISSING"
done
if have python3 && python3 -m py_compile "$KIT/isoserver.py" 2>/dev/null; then
  pass "isoserver.py compiles"
  TMP="$(mktemp -d)"
  head -c 467 /dev/urandom >"$TMP/probe.bin"
  PORT=58099
  (python3 "$KIT/isoserver.py" "$TMP" --bind 127.0.0.1 --port "$PORT" >/dev/null 2>&1) &
  SPID=$!
  sleep 1.5
  HDR="$(curl -sI "http://127.0.0.1:$PORT/probe.bin" 2>/dev/null)"
  echo "$HDR" | grep -qi 'Accept-Ranges: bytes' && pass "HEAD returns 'Accept-Ranges: bytes' (BMC requirement)" || fail "HEAD missing Accept-Ranges — BMC vmedia will fail 'Connect failure'"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -r 2-8 "http://127.0.0.1:$PORT/probe.bin" 2>/dev/null)"
  [ "$CODE" = 206 ] && pass "range GET returns 206 Partial Content" || fail "range GET returned '$CODE' (expected 206)"
  kill "$SPID" 2>/dev/null
  wait "$SPID" 2>/dev/null
  rm -rf "$TMP"
else fail "isoserver.py does not compile under this python3"; fi

sec "BMC reachable (drive the install via Redfish/IPMI)"
if have nc; then
  nc -z -w 3 "$BMC_HOST" 443 2>/dev/null && pass "BMC $BMC_HOST:443 (Redfish) open" || warn "BMC $BMC_HOST:443 not reachable (check network/DHCP-reservation)"
else warn "nc absent — cannot probe BMC $BMC_HOST"; fi

printf '\n%s========================================%s\n' "$D" "$Z"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' "$G" "$P" "$Z" "$Y" "$W" "$Z" "$R" "$F" "$Z"
if [ "$F" -gt 0 ]; then
  printf '  %s→ Fix every FAIL while CT950 is still up, then re-run. Do NOT take the box offline yet.%s\n' "$R" "$Z"
  exit 1
elif [ "$W" -gt 0 ]; then
  printf '  %s→ No blockers, but review WARNs before you commit.%s\n' "$Y" "$Z"
  exit 0
else
  printf '  %s→ Mac is ready. Safe to take the hardware offline and start Phase 1.%s\n' "$G" "$Z"
  exit 0
fi

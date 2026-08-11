#!/usr/bin/env bash
# =============================================================================
# scripts/dev/verify-emit.sh — launcher-parity gate for the registry production roster.
#
# Proves that this repo's streamhost/tiles-manifest.sh + streamhost-tile.sh
# reproduce every LIVE station's {tile.env,qemu-streamhost.sh,x11-runtime.sh}
# BYTE-FOR-BYTE,
# modulo the whitelisted-and-justified deltas in verify-emit-allow.diffpatterns.
# This checker is the definition of done for launcher-emit completeness: run it
# after ANY change to the manifest, the emitter, or a tracked per-station file.
#
# What it does (labhost's /data is treated as READ-ONLY; only /tmp is written):
#   1. rsync the repo's streamhost/{scripts,tiles,tiles-manifest.sh} to
#      $HOST:/tmp/verify-emit.<id>/streamhost/   (NEVER into live paths)
#   1b. copy labhost's /data/kernel-hive/registry/local.env (if present) into
#      the kit as registry/local.env, so the emitter resolves the operator's
#      real SH_HOST_IP/SH_ADVERTISE_HOST exactly as a production emit does.
#      Without it every tile.env diffs on the two address lines and the gate
#      was blind (2026-08-11). No secret leaves labhost: the file is copied
#      labhost-side into the /tmp scratch kit the EXIT trap removes.
#   2. on labhost: tiles-manifest.sh --out-root /tmp/verify-emit.<id>/out
#      (emits every registry production station into the scratch dir; file CONTENTS still reference
#      the live runtime root, so a clean emit is byte-identical to live)
#   3. per station, per emitted file: diff LIVE (left, `<`) vs EMITTED (right,
#      `>`). Only files the emit PRODUCED are compared — an x11 station emits
#      x11-runtime.sh and no qemu-streamhost.sh, and demanding the latter
#      used to hard-fail irix/w2kalpha on every run (NO-LIVE artifact).
#   4. filter each diff through the whitelist and print a per-station report:
#         PASS   byte-identical
#         PASS*  differs only in whitelisted lines (intentional deltas)
#         DIFF   unexplained delta — the gate FAILS
#
# Usage:
#   scripts/dev/verify-emit.sh [--host lab|--local] [--pin-machine] [--keep] [--verbose]
#     --host <ssh-host>  box to verify against (default: lab)
#     --local            run directly on labhost (no second SSH hop)
#     --pin-machine      emit versioned machine types for fresh-rebuild parity
#     --keep             keep the remote scratch dir (prints its path)
#     --verbose          print the residual (non-whitelisted) diff lines,
#                        and the whitelisted ones for PASS* stations
# Exit: 0 iff every station is PASS or PASS*.
# =============================================================================
set -u
HOST=lab
LOCAL_MODE=0
PIN_MACHINE=0
KEEP=0
VERBOSE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host)
      HOST="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --local)
      LOCAL_MODE=1
      HOST=local
      shift
      ;;
    --pin-machine)
      PIN_MACHINE=1
      shift
      ;;
    --verbose | -v)
      VERBOSE=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOW="$REPO/scripts/dev/verify-emit-allow.diffpatterns"
LIVE_ROOT=/data/vms/streamhost/tiles
RID="verify-emit.$$.$(date +%s)"
REMOTE="/tmp/$RID"
LOCAL="$(mktemp -d)"
host_run() {
  # shellcheck disable=SC2029 # the supplied command is intentionally evaluated on the selected host
  if [ "$LOCAL_MODE" = 1 ]; then bash -c "$1"; else ssh "$HOST" "$1"; fi
}
# shellcheck disable=SC2317 # invoked by the EXIT trap
cleanup() {
  rm -rf "$LOCAL"
  if [ "$KEEP" != 1 ]; then host_run "rm -rf $REMOTE" 2>/dev/null; fi
}
trap cleanup EXIT
PIN_ARG=""
[ "$PIN_MACHINE" = 1 ] && PIN_ARG="--pin-machine"

[ -f "$ALLOW" ] || {
  echo "FATAL: whitelist $ALLOW missing" >&2
  exit 1
}

echo "[verify-emit] rsync repo emit kit -> $HOST:$REMOTE/streamhost/"
host_run "mkdir -p $REMOTE/streamhost" || {
  echo "FATAL: cannot create $REMOTE on $HOST" >&2
  exit 1
}
if [ "$LOCAL_MODE" = 1 ]; then
  DEST="$REMOTE/streamhost/"
else
  DEST="$HOST:$REMOTE/streamhost/"
fi
rsync -a --delete "$REPO/streamhost/scripts" "$REPO/streamhost/tiles" \
  "$REPO/streamhost/tiles-manifest.sh" "$DEST" || {
  echo "FATAL: rsync failed" >&2
  exit 1
}

# The operator's real addresses, from labhost's own canonical checkout (see
# header 1b). Absent file = placeholder emit, exactly the old blind behaviour.
host_run "if [ -f /data/kernel-hive/registry/local.env ]; then mkdir -p $REMOTE/registry && cp /data/kernel-hive/registry/local.env $REMOTE/registry/local.env; fi"

echo "[verify-emit] emit registry production tiles into $REMOTE/out (scratch; live paths untouched)"
host_run "bash $REMOTE/streamhost/tiles-manifest.sh --out-root $REMOTE/out $PIN_ARG" \
  >"$LOCAL/emit.log" 2>&1 || {
  echo "FATAL: emit failed —"
  tail -20 "$LOCAL/emit.log"
  exit 1
}

echo "[verify-emit] diff emitted vs live ($LIVE_ROOT)"
host_run "cd $REMOTE/out && mkdir -p $REMOTE/diffs && for t in */; do t=\${t%/}; \
  for f in tile.env qemu-streamhost.sh x11-runtime.sh; do \
    [ -f \$t/\$f ] || continue; \
    if [ ! -f $LIVE_ROOT/\$t/\$f ]; then echo 'LIVE FILE MISSING' > $REMOTE/diffs/\$t--\$f.diff; \
    else diff $LIVE_ROOT/\$t/\$f \$t/\$f > $REMOTE/diffs/\$t--\$f.diff; fi; done; done; \
  ls $REMOTE/out > $REMOTE/diffs/EMITTED_TILES; ls $LIVE_ROOT > $REMOTE/diffs/LIVE_TILES" ||
  {
    echo "FATAL: remote diff run failed" >&2
    exit 1
  }
if [ "$LOCAL_MODE" = 1 ]; then
  rsync -a "$REMOTE/diffs/" "$LOCAL/diffs/" >/dev/null
else
  rsync -a "$HOST:$REMOTE/diffs/" "$LOCAL/diffs/" >/dev/null
fi

# ---- station-set sanity -------------------------------------------------------
if ! diff -q "$LOCAL/diffs/EMITTED_TILES" "$LOCAL/diffs/LIVE_TILES" >/dev/null; then
  echo "WARN: emitted tile set != live tile set:"
  diff "$LOCAL/diffs/EMITTED_TILES" "$LOCAL/diffs/LIVE_TILES" | sed 's/^/  /'
fi

# ---- whitelist filter -------------------------------------------------------
# Whitelist line format:  <tile>|<file>|<extended-regex>
#   station: exact station-dir name or *      file: tile.env | qemu-streamhost.sh | *
# The regex is matched against each diff CONTENT line INCLUDING its leading
# "< " (live-only line) or "> " (emitted/repo-only line). Hunk headers are
# ignored. A station file PASSes* when every content line matches some pattern.
allowed_for() { # $1=tile $2=file -> prints applicable regexes, one per line
  # split ONLY on the first two '|' — the regex field may itself contain pipes
  awk -v t="$1" -v f="$2" '
    /^[[:space:]]*(#|$)/ {next}
    {
      n1=index($0,"|"); if (n1==0) next
      tile=substr($0,1,n1-1); rest=substr($0,n1+1)
      n2=index(rest,"|"); if (n2==0) next
      file=substr(rest,1,n2-1); pat=substr(rest,n2+1)
      if ((tile==t || tile=="*") && (file==f || file=="*")) print pat
    }' "$ALLOW"
}

overall_rc=0
printf '%-14s %-12s %-22s %-16s %s\n' "TILE" "tile.env" "qemu-streamhost.sh" "x11-runtime.sh" "notes"
printf '%-14s %-12s %-22s %-16s %s\n' "----" "--------" "------------------" "--------------" "-----"
while IFS= read -r t; do
  notes=""
  declare -A verdict=()
  for f in tile.env qemu-streamhost.sh x11-runtime.sh; do
    d="$LOCAL/diffs/$t--$f.diff"
    if [ ! -f "$d" ]; then
      # No diff file = the emit did not produce this file for this station (an
      # x11 station has no qemu-streamhost.sh and vice versa) — not a failure.
      # tile.env is emitted for every station, so its absence IS one.
      if [ "$f" = tile.env ]; then
        verdict[$f]="MISSING"
        overall_rc=1
      else
        verdict[$f]="-"
      fi
      continue
    fi
    if grep -q '^LIVE FILE MISSING' "$d"; then
      verdict[$f]="NO-LIVE"
      overall_rc=1
      continue
    fi
    if [ ! -s "$d" ]; then
      verdict[$f]="PASS"
      continue
    fi
    mapfile -t content < <(grep '^[<>]' "$d" || true)
    mapfile -t pats < <(allowed_for "$t" "$f")
    residual=()
    wl=0
    for line in "${content[@]}"; do
      ok=0
      for p in "${pats[@]}"; do [ -n "$p" ] && grep -qE -- "$p" <<<"$line" && {
        ok=1
        break
      }; done
      if [ "$ok" = 1 ]; then
        wl=$((wl + 1))
        [ "$VERBOSE" = 1 ] && echo "  [$t/$f] whitelisted: $line"
      else residual+=("$line"); fi
    done
    if [ "${#residual[@]}" -eq 0 ]; then
      verdict[$f]="PASS*"
      notes="$notes $f:${wl}wl"
    else
      verdict[$f]="DIFF(${#residual[@]})"
      overall_rc=1
      if [ "$VERBOSE" = 1 ]; then
        for r in "${residual[@]}"; do echo "  [$t/$f] RESIDUAL: $r"; done
      else notes="$notes $f:${#residual[@]}residual"; fi
    fi
  done
  printf '%-14s %-12s %-22s %-16s %s\n' "$t" "${verdict["tile.env"]}" "${verdict["qemu-streamhost.sh"]}" "${verdict["x11-runtime.sh"]}" "${notes# }"
done <"$LOCAL/diffs/EMITTED_TILES"

echo
if [ "$overall_rc" = 0 ]; then
  echo "[verify-emit] OK — every tile PASS or whitelisted (PASS*)."
else
  echo "[verify-emit] FAIL — unexplained deltas above. Re-run with --verbose for the residual lines."
fi
[ "$KEEP" = 1 ] && echo "[verify-emit] remote scratch kept at $HOST:$REMOTE"
exit "$overall_rc"

#!/usr/bin/env bash
# box-sync-pairs-selfcheck.sh — prove the pair TABLE is well formed, offline.
#
# WHY. scripts/lib/box-sync-pairs.sh is the one declaration of every repo→box
# mirror pair, and the only thing that ever read it was the gate, which needs
# labhost. So a bad row — a duplicate label, two repo files racing to the same
# box path, a helper the tree ships that no row carries — was invisible until a
# deploy, a launcher `bash "$B/rn-tapnet.sh" up`, or a station that would not
# start. beos, w2kalpha and rhapsody each lost a boot cycle to the last one; on
# 2026-09-03 the file hit its 600-line hard cap mid-landing and the per-station
# rows became one glob loop in box-sync-pairs-retronet.sh, which is exactly the
# kind of refactor that can silently stop covering a station.
#
# This runs the real loader with LAB=local against an EMPTY box root, so every
# box-side `find` returns nothing and the resulting table is purely what the
# repo declares. No ssh, no labhost, no /data — safe in CI and in a public
# clone. `stations-registry.py validate` runs it automatically when a
# box-sync-pairs*.sh file has uncommitted changes.
#
# Not quite read-only: box_sync_load_pairs renders the registry into the
# gitignored build/registry/ (its box-authored rows compare against those
# bytes). Nothing else in the tree is touched, and nothing on labhost is.
#
#   usage: scripts/dev/box-sync-pairs-selfcheck.sh [--verbose]
#   exit:  0 clean · 1 a breach (each one printed with what to add)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_BOX="$WORK/box"
mkdir -p "$FAKE_BOX/build/streamhost/src" "$FAKE_BOX/build/registry" \
  "$FAKE_BOX/stations" "$FAKE_BOX/serve/darklaunch.d" "$WORK/tmp"

# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/box-sync-pairs.sh"
box_sync_load_pairs "$REPO_ROOT" "$FAKE_BOX" local "$WORK/tmp" >"$WORK/load.log" 2>&1 || {
  echo "box-sync-pairs-selfcheck: box_sync_load_pairs FAILED"
  sed 's/^/    /' "$WORK/load.log"
  exit 1
}

n=${#BOX_SYNC_LABELS[@]}
fails=0
note() {
  echo "box-sync-pairs-selfcheck: FAIL: $*"
  fails=$((fails + 1))
}

[ "$n" -gt 0 ] || {
  note "the table is EMPTY — box_sync_load_pairs declared no pairs at all"
  exit 1
}

# 1. one label per row, and one box-side destination per row. A duplicate label
#    makes `box-deploy.sh LABEL --apply` ambiguous; a duplicate destination
#    means two repo files overwrite each other on every deploy, last one wins.
for field in LABELS BOX_FILES; do
  declare -n arr="BOX_SYNC_$field"
  while IFS= read -r dup; do
    [ -n "$dup" ] || continue
    note "duplicate ${field%S}: $dup"
  done < <(printf '%s\n' "${arr[@]}" | sort | uniq -d)
  unset -n arr
done

# 2. a repo-authoritative row must have something to push. (Box-authoritative
#    rows legitimately have no repo file yet — that is what MISSING reports.)
for i in $(seq 0 $((n - 1))); do
  [ "${BOX_SYNC_AUTHORITY[$i]}" = repo ] || continue
  [ -e "$REPO_ROOT/${BOX_SYNC_REPO_FILES[$i]}" ] ||
    note "${BOX_SYNC_LABELS[$i]}: repo-authoritative row names ${BOX_SYNC_REPO_FILES[$i]}, which is not in the tree"
done

# 3. COVERAGE — the trap this file exists for. A network-link helper the
#    LAUNCHER calls is not automatically shipped: unless the registry declares
#    it as an emit aux file (or an x11 runtime file), the only thing that puts
#    it in the station dir is a pair row, and without it the launcher dies on
#    start at `bash "$B/rn-tapnet.sh" up`. beos, w2kalpha and rhapsody each lost
#    a boot cycle to exactly that.
declare -A COVERED=()
for i in $(seq 0 $((n - 1))); do COVERED["${BOX_SYNC_REPO_FILES[$i]}"]=1; done
while IFS= read -r emitted; do
  [ -n "$emitted" ] && COVERED["$emitted"]=1
done < <(
  python3 - "$REPO_ROOT" <<'PY'
import glob, json, sys
for path in sorted(glob.glob(f"{sys.argv[1]}/registry/stations/*.json")):
    runtime = json.load(open(path)).get("runtime", {})
    for block in (runtime.get("qemu", {}), runtime.get("x11", {})):
        for ref in block.get("auxFiles", []):
            print(ref)
        if block.get("launcher"):
            print(block["launcher"])
PY
)
while IFS= read -r helper; do
  [ -n "$helper" ] || continue
  [ -n "${COVERED[$helper]:-}" ] ||
    note "$helper reaches no station dir: no box_sync_add_pair row and no registry auxFiles/launcher entry — add one (see box-sync-pairs-retronet.sh)"
done < <(
  cd "$REPO_ROOT" &&
    git ls-files \
      'streamhost/stations/*/rn-tapnet.sh' \
      'streamhost/stations/*/wi-tapnet.sh' \
      'streamhost/stations/*/rn-netns.sh' | sort
)

if [ "$VERBOSE" = 1 ]; then
  for i in $(seq 0 $((n - 1))); do
    printf '  %-40s %-8s %-5s %s\n' "${BOX_SYNC_LABELS[$i]}" "${BOX_SYNC_MODES[$i]}" \
      "${BOX_SYNC_AUTHORITY[$i]}" "${BOX_SYNC_REPO_FILES[$i]}"
  done
fi

if [ "$fails" -gt 0 ]; then
  echo "box-sync-pairs-selfcheck: $fails breach(es) in $n pairs"
  exit 1
fi
echo "box-sync-pairs-selfcheck: OK — $n pairs, no duplicate label or destination, every repo row present, every launcher helper paired"

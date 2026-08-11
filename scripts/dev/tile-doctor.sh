#!/usr/bin/env bash
# =============================================================================
# tile-doctor.sh — is <tile> actually a finished exhibit?
#
# Adding a station to the registry is the easy half. The other half is a scatter of
# places the generator does not write, and every one of them has been forgotten
# at least once: the UI scene bindings, the poster prose, the hero image, the
# keyboard map, the pacing knobs, the checkpoint, the operator CLI matrix.
# The MPF-II shipped to `lifecycle: production` missing several, and each was
# found by looking at the exhibit and noticing it was wrong.
#
# This runs every one of those checks for a single station and says which failed.
# It is the "am I done?" command, and it is meant to be run BEFORE claiming so.
#
# Usage:  scripts/dev/tile-doctor.sh <tile-id> [--live]
#           --live   also check labhost: service state, tile.env, checkpoint, labctl
#
# Exit 0 = every check passed. Non-zero = the count of failures.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TILE="${1:-}"
LIVE=0
[ "${2:-}" = "--live" ] && LIVE=1

if [ -z "$TILE" ]; then
  sed -n '2,20p' "$0"
  exit 2
fi

PASS=0
FAIL=0
ok() {
  printf '  \033[32mPASS\033[0m  %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m  %s\n' "$1"
  [ -n "${2:-}" ] && printf '        %s\n' "$2"
  FAIL=$((FAIL + 1))
}
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

echo "tile-doctor: $TILE"
echo
echo "REGISTRY"

ENTRY="$REPO/registry/tiles/$TILE.json"
if [ -f "$ENTRY" ]; then
  ok "registry entry exists ($(realpath --relative-to="$REPO" "$ENTRY"))"
else
  bad "no registry entry" "expected registry/tiles/$TILE.json"
  echo
  echo "Nothing else can be checked without one."
  exit 1
fi

if out=$(cd "$REPO" && python3 scripts/stations-registry.py validate 2>&1); then
  ok "registry validates"
else
  bad "registry validation fails" "$(printf '%s' "$out" | grep -F "$TILE" | head -3)"
fi

if out=$(cd "$REPO" && make station-registry-check 2>&1); then
  ok "generated files are in sync"
else
  bad "generated-file drift" "run: make station-registry-generate"
fi

LIFECYCLE=$(python3 -c "import json;print(json.load(open('$ENTRY')).get('lifecycle','?'))")
echo "        lifecycle: $LIFECYCLE"

echo
echo "EXHIBIT (what a visitor sees)"

[ -f "$REPO/registry/posters/$TILE.md" ] &&
  ok "poster prose" || bad "no poster prose" "registry/posters/$TILE.md"
[ -f "$REPO/spa/public/posters/$TILE/desktop.webp" ] &&
  ok "hero image" || bad "no hero image" "spa/public/posters/$TILE/desktop.webp"

# Visitor-facing copy must describe the real machine, never the rig.
read_checks() {
  while IFS='|' read -r verdict msg hint; do
    [ -z "$verdict" ] && continue
    if [ "$verdict" = ok ]; then ok "$msg"; else bad "$msg" "$hint"; fi
  done
}

read_checks < <(
  python3 - "$ENTRY" <<'PYEOF'
import json, re, sys
m = json.load(open(sys.argv[1])).get("museum", {})
rig = re.compile(r"\b(MAME|QEMU|streamhost|qcow2|kiosk|VICE|hatari|cap32|fs-uae|LinApple|snapshot|framebuffer|emulat\w*)\b", re.I)
leaks = [f for f in ("lineage", "blurb", "arch") if rig.search(str(m.get(f, "")))]
print("ok|no rig detail in visitor-facing copy" if not leaks else
      "bad|rig detail leaks to visitors|field(s) %s — that belongs in `notes`" % ",".join(leaks))
lin = str(m.get("lineage", ""))
print("ok|lineage is a heritage (%d chars)" % len(lin) if len(lin) <= 120 else
      "bad|lineage reads as a paragraph (%d chars)|make it a heritage e.g. 'Windows NT 3.x'; the long form belongs in the poster" % len(lin))
print("ok|blurb present" if str(m.get("blurb", "")).strip() else
      "bad|no blurb|catalog.ts falls back to `notes`, which would show rig detail to visitors")
print("bad|memory renders as '0 MB'|a sub-megabyte machine must declare ramKB"
      if m.get("ramMB") == 0 and not m.get("ramKB") else
      "ok|memory stated in a unit it can express")
PYEOF
)

echo
echo "SPA WIRING (hand-maintained — the generator does not write these)"
for pair in \
  "spa/src/ui/keyboard/keyboardProfiles.ts:keyboard profile (OS_FAMILY)" \
  "spa/src/scene/machines.ts:machine assembly" \
  "spa/src/scene/machineIdentity.ts:exhibit identity (build-only type check!)"; do
  f="${pair%%:*}"
  what="${pair#*:}"
  if grep -qE "^\s+$TILE:" "$REPO/$f"; then ok "$what"; else bad "$what" "add '$TILE' to $f"; fi
done

echo
echo "INPUT"
read_checks < <(
  python3 - "$ENTRY" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
env = d.get("runtime", {}).get("stationEnv", {})
kb = d.get("keyboard") or {}
gap = env.get("SH_KEY_MIN_GAP_MS")
blob = json.dumps(d).lower()
emulator = bool(d.get("runtime", {}).get("x11")) or "bridge" in blob
if gap:
    print("ok|key pacing declared (hold %s / gap %s ms)" % (env.get("SH_KEY_MIN_HOLD_MS", "0"), gap))
elif emulator:
    print("bad|no SH_KEY_MIN_GAP_MS on an emulator tile|typing will silently drop characters; use two frame periods (50 Hz -> 40, 60 Hz -> 32)")
else:
    print("ok|no key pacing needed (not an emulator tile)")
if kb.get("charMap"):
    print("ok|keyboard charMap declared (%d characters)" % len(kb["charMap"]))
else:
    print("ok|no keyboard translation declared — confirm with scripts/dev/mame-keymap.py that the guest matches a PC")
PYEOF
)

if [ "$LIVE" = 1 ]; then
  echo
  echo "LIVE (box)"
  # shellcheck disable=SC2029  # $TILE/$k are ours; expanding client-side is intended
  if ssh -o ConnectTimeout=8 lab true 2>/dev/null; then
    state=$(ssh lab "systemctl is-active streamhost@$TILE" 2>/dev/null || echo unknown)
    [ "$state" = active ] && ok "streamhost@$TILE active" || bad "service $state"
    if ssh lab "labctl ls 2>/dev/null | grep -q '^$TILE '"; then
      ok "labctl knows the tile"
    else
      bad "labctl does not know the tile" "run 'labctl gen' on the box"
    fi
    snap=$(ssh lab "qemu-img snapshot -l /data/vms/streamhost/tiles/$TILE/overlay.qcow2 2>/dev/null | awk 'NR>2{print \$2}'" 2>/dev/null)
    case "$snap" in
      *golden*) ok "golden snapshot present" ;;
      "") skip "no overlay/snapshot (not a bridge tile?)" ;;
      *) bad "no 'golden' snapshot" "found: $snap" ;;
    esac
    # The knobs the registry declares must actually be in the running process.
    for k in SH_KEY_MIN_GAP_MS SH_KEY_MAP; do
      want=$(python3 -c "import json;print(json.load(open('$ENTRY')).get('runtime',{}).get('stationEnv',{}).get('$k',''))")
      [ -z "$want" ] && continue
      got=$(ssh lab "P=\$(systemctl show -p MainPID --value streamhost@$TILE); tr '\0' '\n' </proc/\$P/environ 2>/dev/null | sed -n 's/^$k=//p'" 2>/dev/null)
      if [ "$got" = "$want" ]; then
        ok "$k live matches registry"
      else
        bad "$k not live" "registry '$want' vs process '${got:-unset}' — tile not restarted, or running an older binary"
      fi
    done
  else
    skip "cannot reach the box (ssh lab)"
  fi
fi

echo
printf 'tile-doctor: %d passed, %d failed\n' "$PASS" "$FAIL"
exit "$FAIL"

#!/usr/bin/env bash
# =============================================================================
# scripts/dev/box-ccache-conf.sh — make labhost's DEFAULT ccache the shared one.
#
# WHY (measured 2026-09-10). Every MAME builder in scripts/build-guests goes
# through mame-ccache.sh, which points ccache at ONE shared cache
# (/data/vms/sandbox/trixie-chroot/ccache: hash_dir=false, base_dir set,
# compiler_check=content) — lifetime 25,415 cacheable calls, 91.7 % hits, one
# cold MAME core ever. But an agent that runs `make … OVERRIDE_CC="ccache gcc"`
# BY HAND in a build tree does not source that environment, so ccache falls
# back to root's default cache (/root/.cache/ccache, hash_dir=true, no
# base_dir): identical core objects hash differently per tree and miss. The
# domainos wave paid three cold MAME compiles that way (2,589 calls, 34 % hits)
# and tripped the box load rule each time.
#
# THE FIX is to make the default the shared cache, so a hand-run make can no
# longer go cold by accident: install a PRIMARY ccache config for root on
# labhost. Precedence is env > primary (~/.config/ccache/ccache.conf) >
# secondary (<cache_dir>/ccache.conf) > /etc/ccache.conf, so the builders'
# exported CCACHE_DIR/CCACHE_BASEDIR still win when they are set, the shared
# cache's own ccache.conf still supplies sloppiness/max_size, and this file
# only supplies what the default was missing: the cache_dir, hash_dir=false
# and a host-side base_dir.
#
# Operator rule this implements: a compile cache (ccache, a shared cargo
# target dir, …) is ALWAYS set up and used for a build; a cold rebuild is a
# bug, not a cost of doing business.
#
# usage:
#   scripts/dev/box-ccache-conf.sh            # install (idempotent) + prove
#   scripts/dev/box-ccache-conf.sh --check    # print the effective config + stats
# Runs from CT950 through the one door (`ssh lab`), rule 2.
# =============================================================================
set -euo pipefail

CACHE=/data/vms/sandbox/trixie-chroot/ccache
CONF=/root/.config/ccache/ccache.conf
BASE=/data/vms/sandbox

check() {
  ssh -n lab "echo '== effective ccache config (root, no env)'; ccache -p | grep -E '\) (cache_dir|base_dir|hash_dir|compiler_check|max_size|sloppiness) '; echo; ccache -s | grep -E 'Cacheable|Hits:|Misses:|Cache size' | head -4"
}

case "${1:-install}" in
  --check) check; exit 0 ;;
  install) ;;
  *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

[ -d "$(dirname "$0")/../build-guests/emulators" ] || { echo "run from the repo" >&2; exit 1; }

ssh -n lab "set -e
umask 022
test -d '$CACHE' || { echo 'shared cache $CACHE missing — run a MAME builder once (mame-ccache.sh creates it)' >&2; exit 1; }
mkdir -p '$(dirname "$CONF")'
cat > '$CONF' <<EOF
# installed by scripts/dev/box-ccache-conf.sh — do not edit; re-run it instead.
# Primary ccache config for root on labhost: the DEFAULT cache is the shared
# one, so a hand-run make cannot silently go cold (see the script header).
cache_dir = $CACHE
base_dir = $BASE
hash_dir = false
compiler_check = content
# the shared cache's own ccache.conf is NOT read as a secondary config when
# cache_dir comes from here (measured: max_size fell to the 5 GiB default), so
# its two remaining settings are repeated:
max_size = 32G
sloppiness = pch_defines,time_macros
EOF
echo 'installed $CONF:'; sed 's/^/  /' '$CONF'"

# Proof: the same source compiled from two differently named directories must
# be one miss then one hit, with NO env set — that is exactly the case the
# hand-run makes fell into.
ssh -n lab 'set -e; umask 022
t=$(mktemp -d /data/vms/sandbox/.ccache-proof.XXXXXX); mkdir -p "$t/a" "$t/b"
printf "int f(int x){return x*2;}\n" >"$t/a/x.c"; cp "$t/a/x.c" "$t/b/x.c"
before=$(ccache -s | awk "/^  Hits:/{print \$2; exit}")
( cd "$t/a" && ccache gcc -O2 -c x.c -o x.o )
( cd "$t/b" && ccache gcc -O2 -c x.c -o x.o )
after=$(ccache -s | awk "/^  Hits:/{print \$2; exit}")
rm -rf "$t"
d=$((after-before))
if [ "$d" -ge 1 ]; then echo "PROOF ok: second compile from a different dir was a cache hit (+$d)"; else echo "PROOF FAILED: no hit across dirs" >&2; exit 1; fi'
check

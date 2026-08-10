#!/bin/bash
# =============================================================================
# build-guests/emulators/mame-ccache.sh — shared ccache wiring for every
# chroot MAME build (build-mame-{bbcb,mpf2,zx81,dragon32,kc854,oricatmos}.sh).
#
# WHY. Six binaries are built for seven tiles, each from its OWN source tree,
# and three of the six builders name their tree with `$$` so every run is a
# brand-new directory. Without a cache that means six cold MAME compiles per
# migration wave, ~1 h each, recompiling the identical emu/osd/3rdparty core
# six times over. The trees stay separate on purpose (per-tile patch
# experimentation is worth more than the disk), so the cache has to be the
# thing that is shared.
#
# WHY IT HITS ACROSS DIFFERENTLY-NAMED TREES — the part that decides whether
# this works at all. ccache keys on the preprocessed source plus the compiler
# arguments, so an absolute path leaking into either one would give the same
# core file a different hash in every tree. On MAME it does not, and that is
# checked rather than assumed:
#   * GENie emits every -I and every source path RELATIVE to the generated
#     project dir (`-I"../../../../../src/emu"`), so the command lines are
#     byte-identical no matter what the tree is called;
#   * MAME's default build carries no `-g`, so no absolute path is recorded in
#     debug info and the compile's cwd never reaches the hash;
#   * `hash_dir = false` and `base_dir = /build` are set below anyway, as
#     insurance for the day someone builds with SYMBOLS=1 or moves a tree.
# The one file that legitimately differs per tree is the generated driver list
# (`build/generated/mame/drivers/<subtarget>.cpp`), and per-subtarget device
# filtering means each SUBTARGET compiles its own device subset. Expect a high
# cross-tree hit rate, not 100%.
#
# WHY OVERRIDE_CC AND NOT JUST PATH. GENie bakes `CC = gcc` / `CXX = g++` into
# the generated makefiles, so /usr/lib/ccache on PATH would in fact work — but
# only for as long as nothing in the chroot resets PATH, and the failure mode
# is silent (a full cold build that merely looks slow). MAME plumbs
# OVERRIDE_CC/OVERRIDE_CXX through to genie's --CC/--CXX (makefile lines
# ~540), so the generated makefile says `CC = ccache gcc` in writing. That is
# the explicit form and it is what the builders pass. It needs REGENIE=1 once
# after the flags change, which every builder already passes.
#
# LAYOUT. The cache lives at <chroot>/ccache — i.e. /ccache inside the chroot.
# Outside every build tree, so `rm -rf` of a tree never touches it, and one per
# chroot, which is correct: ccache keys on the compiler, so a bookworm gcc-12
# cache and a trixie gcc-14 cache could never share an entry anyway.
#
# USAGE (host side, after the chroot is resolved and validated):
#     . "$HERE/mame-ccache.sh"
#     mame_ccache_prepare "$CHROOT"
# then, inside the build heredoc, before make:
#     MAME_MAKE_CC_ARGS=(OVERRIDE_CC=gcc OVERRIDE_CXX=g++)
#     if [ -r /ccache/env.sh ]; then . /ccache/env.sh; fi
#     make ... "${MAME_MAKE_CC_ARGS[@]}"
# The fallback array is the genie default, so a chroot that was never prepared
# builds exactly as it did before.
#
# CLI:
#     mame-ccache.sh install <chroot>   # apt-get install ccache, chroot-guarded
#     mame-ccache.sh stats   <chroot>   # ccache -s for that chroot's cache
#     mame-ccache.sh zero    <chroot>   # reset the stats counters only
#
# Env:
#     MAME_CCACHE=0        disable entirely (builds with plain gcc/g++)
#     MAME_CCACHE_SIZE     max cache size (default 32G; /data has ~450 G free)
# =============================================================================

MAME_CCACHE_SIZE="${MAME_CCACHE_SIZE:-32G}"

_mcc_say() { printf 'mame-ccache: %s\n' "$*" >&2; }

# mame_ccache_prepare <chroot> — create the shared cache dir, write its config
# and the env file the build heredoc sources. Never fatal: a chroot without
# ccache installed gets an env file that selects plain gcc/g++, so the build
# still runs (slowly) and says why.
mame_ccache_prepare() {
  local root="${1:?mame_ccache_prepare: chroot root required}" dir
  dir="$root/ccache"
  mkdir -p "$dir"
  if [ "${MAME_CCACHE:-1}" = 0 ]; then
    _mcc_say "MAME_CCACHE=0 — building with plain gcc/g++"
    _mcc_write_env "$dir" 0
    return 0
  fi
  if [ ! -x "$root/usr/bin/ccache" ]; then
    _mcc_say "ccache is NOT installed in $root — this build will be a full cold compile."
    _mcc_say "  install it once with: scripts/build-guests/emulators/mame-ccache.sh install $root"
    _mcc_write_env "$dir" 0
    return 0
  fi
  # base_dir rewrites absolute paths below it to relative before hashing;
  # hash_dir stops the cwd being hashed at all. Together they make a tree's
  # NAME irrelevant to the cache key, which is the whole point.
  # sloppiness: MAME's `emu` project compiles behind a PRECOMPILED HEADER
  # (`-include <objdir>/emu.h`, genie's precompiledheaders()). Without these two
  # flags ccache refuses every one of those translation units outright —
  # measured on a cold oricatmos build: 337 of 1204 compiles (28%) came back
  # "Could not use precompiled header", i.e. permanently uncached. They are the
  # two flags ccache's own PCH documentation requires, and MAME includes the
  # header with -include rather than #include, which is the supported form.
  # No MAME source uses __DATE__/__TIME__ (grepped), so time_macros costs
  # nothing in correctness here.
  cat >"$dir/ccache.conf" <<EOF
max_size = $MAME_CCACHE_SIZE
base_dir = /build
hash_dir = false
compiler_check = content
sloppiness = pch_defines,time_macros
EOF
  _mcc_write_env "$dir" 1
  _mcc_say "cache at $dir (max $MAME_CCACHE_SIZE), OVERRIDE_CC/CXX = ccache gcc/g++"
}

# _mcc_write_env <dir> <enabled>
_mcc_write_env() {
  local dir="$1" on="$2"
  if [ "$on" = 1 ]; then
    cat >"$dir/env.sh" <<'EOF'
# generated by scripts/build-guests/emulators/mame-ccache.sh — do not edit
export CCACHE_DIR=/ccache
export CCACHE_BASEDIR=/build
MAME_MAKE_CC_ARGS=(OVERRIDE_CC="ccache gcc" OVERRIDE_CXX="ccache g++")
EOF
  else
    cat >"$dir/env.sh" <<'EOF'
# generated by scripts/build-guests/emulators/mame-ccache.sh — ccache DISABLED
MAME_MAKE_CC_ARGS=(OVERRIDE_CC=gcc OVERRIDE_CXX=g++)
EOF
  fi
}

# mame_ccache_install <chroot> — one-off apt install inside the chroot. Goes
# through chroot-guard: API mounts are made recursively private the instant
# they exist and the teardown can only ever name paths under the chroot root
# (the 2026-08-10 /dev/pts incident).
mame_ccache_install() {
  local root="${1:?mame_ccache_install: chroot root required}" rc=0
  # shellcheck disable=SC1090,SC1091
  . /usr/local/bin/chroot-guard 2>/dev/null ||
    . "$(dirname "${BASH_SOURCE[0]}")/../../lib/chroot-guard.sh"
  chroot_guard_mount_api "$root" || return $?
  cp /etc/resolv.conf "$root/etc/resolv.conf"
  chroot "$root" /bin/bash -c \
    'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ccache' || rc=$?
  chroot_guard_umount_all "$root" || rc=$?
  return "$rc"
}

# mame_ccache_stats <chroot> [zero]
mame_ccache_stats() {
  local root="${1:?mame_ccache_stats: chroot root required}" verb="${2:-show}"
  [ -x "$root/usr/bin/ccache" ] || {
    _mcc_say "no ccache in $root"
    return 1
  }
  case "$verb" in
    zero) chroot "$root" /usr/bin/env CCACHE_DIR=/ccache ccache --zero-stats ;;
    *) chroot "$root" /usr/bin/env CCACHE_DIR=/ccache ccache -s ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    install) mame_ccache_install "${2:?usage: mame-ccache.sh install <chroot>}" ;;
    stats) mame_ccache_stats "${2:?usage: mame-ccache.sh stats <chroot>}" ;;
    zero) mame_ccache_stats "${2:?usage: mame-ccache.sh zero <chroot>}" zero ;;
    prepare) mame_ccache_prepare "${2:?usage: mame-ccache.sh prepare <chroot>}" ;;
    *)
      sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 2
      ;;
  esac
  exit $?
fi

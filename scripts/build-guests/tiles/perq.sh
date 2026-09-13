#!/bin/bash
# =============================================================================
# tiles/perq.sh — stage the host-native `perq` station: PERQemu 0.9.5 (Mono +
# SDL2, GPLv3 — github.com/skeezicsb/PERQemu), showing Three Rivers PERQ 1A
# POS G.7 (and, from the same release tree, Accent S6/Spice Lisp for the
# `accent` station). PERQemu is a stock host application, so it runs inside a
# systemd-nspawn container on the lisa/medley shape
# (streamhost/stations/perq/x11-runtime.sh); this builder produces the two
# things that launcher needs, ONE combination:
#
#   $OUT/perqemu/    the upstream release tree, verified byte-for-byte
#                     (PERQemu.exe + DLLs, PROM/, Conf/, Resources/, Disks/)
#   $OUT/rootfs/     a debootstrap trixie container root with Mono + SDL2 +
#                     Xvfb + the audit tools, uid-shifted ONCE to $UIDBASE
#
# Three walls the first lead paid for (full account: docs/lab/PERQ-WAVE.md):
#   1. Do NOT source-build SDL2-CS. The upstream 0.9.5 RELEASE ZIP already
#      ships an SDL2-CS.dll built against a current libSDL2 (the NuGet
#      package PERQemu.csproj references is a stale 2.0.0 that lacks the
#      audio-queue/display APIs UI/SDL/*.cs calls — that path is a dead end).
#   2. PERQemu opens its ROMs with FileMode.Open (default access ReadWrite)
#      and resolves its BaseDir through Mono's CodeBase, which canonicalises
#      through a symlink — so the release tree must be BOUND, and the working
#      copy perq-inner.sh runs from must be a real COPY, never a symlink.
#   3. PERQemu needs a real TTY as its clock (perq-inner.sh's header has the
#      mechanism); that is the launcher's concern, not this builder's.
#
# Usage:
#   scripts/build-guests/tiles/perq.sh --fetch          # stage the release
#   scripts/build-guests/tiles/perq.sh --rootfs         # build the container root
#   scripts/build-guests/tiles/perq.sh --fetch --rootfs # both
#   scripts/build-guests/tiles/perq.sh --fetch --rootfs --prove   # + boot proof
#
# Env overrides: ASSETS (local fetch cache), OUT (station asset tree),
# UIDBASE (container uid base, default 2359296 = 36*65536 for `perq`;
# `accent` uses 2424832 and its own $OUT — see docs/lab/PERQ-WAVE.md §accent),
# PROVE_DISPLAY (spare X display for --prove, default :198),
# PROVE_DISK (disk to boot for --prove, default g7.prqm).
#
# Licence: PERQemu itself is GPLv3 (PERQemu/COPYING.txt in the upstream repo,
# not the BSD/MIT the original brief guessed — see docs/lab/PERQ-WAVE.md). This
# script only fetches and stages the upstream binary release; it vendors none
# of PERQemu's source.
# =============================================================================
set -euo pipefail

OS_ID=perq
REL_TAG="v0.9.5"
REL_ZIP="perqemu0.95.zip"
REL_URL="https://github.com/skeezicsb/PERQemu/releases/download/${REL_TAG}/${REL_ZIP}"
REL_SHA="0df4f0c481712741a15ddde48fa3e5fa2eab134d78771bc17969b70c082460de"
REL_SIZE=44605339

ASSETS="${ASSETS:-/data/vms/sandbox/perq/media}"
OUT="${OUT:-/data/vms/streamhost/assets/perq}"
UIDBASE="${UIDBASE:-2359296}"
PROVE_DISPLAY="${PROVE_DISPLAY:-:198}"
PROVE_DISK="${PROVE_DISK:-g7.prqm}"

FETCH=0
DO_ROOTFS=0
PROVE=0
for a in "$@"; do
  case "$a" in
    --fetch) FETCH=1 ;;
    --rootfs) DO_ROOTFS=1 ;;
    --prove) PROVE=1 ;;
    *)
      echo "perq.sh: unknown argument $a" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# stage: fetch + verify the upstream release, unpack into $OUT/perqemu
# ---------------------------------------------------------------------------
stage() {
  mkdir -p "$ASSETS"
  if [ ! -f "$ASSETS/$REL_ZIP" ] || [ "$(stat -c %s "$ASSETS/$REL_ZIP")" != "$REL_SIZE" ]; then
    [ "$FETCH" = 1 ] || die "missing $ASSETS/$REL_ZIP ($REL_SIZE B) — re-run with --fetch"
    log "fetching $REL_URL"
    curl -fsSL --retry 5 --retry-delay 5 -m 900 -o "$ASSETS/$REL_ZIP.part" "$REL_URL"
    mv "$ASSETS/$REL_ZIP.part" "$ASSETS/$REL_ZIP"
  fi
  local got
  got="$(sha256sum "$ASSETS/$REL_ZIP" | cut -d' ' -f1)"
  [ "$got" = "$REL_SHA" ] || die "sha256 mismatch for $REL_ZIP: got $got want $REL_SHA"
  [ "$(stat -c %s "$ASSETS/$REL_ZIP")" = "$REL_SIZE" ] || die "size mismatch for $REL_ZIP"
  log "verified $REL_ZIP ($REL_SIZE B, sha256 $REL_SHA)"

  local stg="$ASSETS/unpack.$$"
  rm -rf "$stg"
  mkdir -p "$stg"
  unzip -oq "$ASSETS/$REL_ZIP" -d "$stg"
  local tree="$stg/perqemu0.95"
  [ -f "$tree/PERQemu.exe" ] || die "no PERQemu.exe in the unpacked release"
  [ -f "$tree/SDL2-CS.dll" ] || die "no SDL2-CS.dll in the unpacked release (wall 1)"
  [ -f "$tree/Disks/g7.prqm" ] || die "no Disks/g7.prqm in the unpacked release"
  [ -f "$tree/Disks/s6lisp.prqm" ] || die "no Disks/s6lisp.prqm in the unpacked release"

  mkdir -p "$OUT"
  rm -rf "$OUT/perqemu"
  mv "$tree" "$OUT/perqemu"
  rm -rf "$stg"
  chmod -R a+rX "$OUT/perqemu"
  (cd "$ASSETS" && sha256sum "$REL_ZIP" >MANIFEST.sha256)
  log "staged $OUT/perqemu (PERQemu.exe + PROM/ Conf/ Resources/ Disks/)"
}

# ---------------------------------------------------------------------------
# --rootfs: debootstrap a trixie container root, shift it ONCE to $UIDBASE.
# Idempotent: an existing tree already owned by $UIDBASE with mono in it is
# kept, same shape as tiles/medley.sh.
# ---------------------------------------------------------------------------
build_rootfs() {
  local r="$OUT/rootfs"
  if [ -x "$r/usr/bin/mono-sgen" ] && [ "$(stat -c %u "$r")" = "$UIDBASE" ]; then
    log "container rootfs present at $r (uid $(stat -c %u "$r"))"
    return 0
  fi
  command -v debootstrap >/dev/null || die "debootstrap not found — run this step on labhost/CT950"
  local stg="$r.staging"
  rm -rf "$stg"
  mkdir -p "$stg"
  # mono-runtime-sgen pulls the Mono CLR; libsdl2-2.0-0/libsdl2-image-2.0-0
  # are what the release's SDL2-CS.dll.config maps onto (wall 1); xvfb is the
  # captured root; xdotool/x11-utils/procps/iproute2/util-linux/xauth are the
  # input/audit tools the operator's sandbox proof runs (§Sandbox). `script`
  # (perq-inner.sh's TTY fix, wall 3) ships in bsdutils, which debootstrap's
  # minbase variant already pulls in as Priority:required — not listed below.
  debootstrap --variant=minbase \
    --include=mono-runtime-sgen,libsdl2-2.0-0,libsdl2-image-2.0-0,xvfb,xdotool,x11-utils,xauth,procps,iproute2,util-linux \
    trixie "$stg" http://deb.debian.org/debian >"$stg.log" 2>&1 ||
    {
      tail -40 "$stg.log" >&2
      die "debootstrap failed — see $stg.log"
    }
  [ -x "$stg/usr/bin/mono-sgen" ] || die "no mono-sgen in the built rootfs"
  # mono-runtime-sgen alone does not register the `mono` alternative — the
  # launcher's perq-inner.sh execs plain `mono` (measured: "exec: mono: not
  # found" on a minbase --include=mono-runtime-sgen rootfs). Make it explicit.
  [ -e "$stg/usr/bin/mono" ] || ln -s mono-sgen "$stg/usr/bin/mono"
  [ -x "$stg/usr/bin/Xvfb" ] || die "no Xvfb in the built rootfs"
  [ -x "$stg/usr/bin/script" ] || die "no script(1) in the built rootfs (bsdutils)"
  # Empty mount points for the launcher's --read-only root: nspawn cannot
  # create them on a read-only filesystem at launch time (measured — "Failed
  # to create mount point /opt/perqemu: Read-only file system").
  mkdir -p "$stg/opt/perqemu" "$stg/work" "$stg/tmp/.X11-unix"
  chmod 1777 "$stg/tmp/.X11-unix"
  # One-shot uid shift: --private-users-ownership=chown walks the whole tree
  # ONCE here; the launcher then runs with ownership=off (fast start, no
  # per-launch chown of a 400+ MB tree — the medley precedent).
  systemd-nspawn --quiet --register=no -D "$stg" \
    --private-users="$UIDBASE:65536" --private-users-ownership=chown /bin/true
  rm -rf "$r"
  mv "$stg" "$r"
  rm -f "$stg.log"
  log "container rootfs built at $r ($(du -sh "$r" | cut -f1), uid $UIDBASE)"
}

# ---------------------------------------------------------------------------
# --prove: the reproducibility proof the wave brief asked for. Launch what
# this builder just staged, under a THROWAWAY out dir if $OUT/$ASSETS were
# overridden for the run, on a spare display, and capture the POS login
# frame the same way perq-inner.sh does (script(1) TTY, FIFO stdin, XTEST
# Return + `guest` + Return through the date/name prompts). Self-contained:
# does not touch the production station dir or display.
# ---------------------------------------------------------------------------
prove() {
  # Reproduce what runs: invoke the ACTUAL launcher (streamhost/stations/perq/
  # x11-runtime.sh + perq-inner.sh, unmodified) against the assets this run
  # just staged, on a throwaway station dir and a spare display. This is not
  # a re-implementation — it is the same code path production uses, so it
  # proves the builder's OUTPUT boots, not just that a hand-rolled mono
  # invocation does.
  local disp="$PROVE_DISPLAY" num="${PROVE_DISPLAY#:}"
  local pwork
  pwork="$(mktemp -d /tmp/perq-prove.XXXXXX)"
  local sockdir="$pwork/x11"
  mkdir -p "$sockdir"
  local here
  here="$(cd "$(dirname "$0")" && pwd)"
  local launcher="$here/../../../streamhost/stations/perq/x11-runtime.sh"
  [ -f "$launcher" ] || die "no launcher at $launcher"

  rm -f "/tmp/.X11-unix/X${num}"
  SH_STATION=perq-prove PERQ_BASE="$pwork/station" PERQ_ASSETS="$OUT" \
    PERQ_ROOTFS="$OUT/rootfs" PERQ_DISK="$PROVE_DISK" PERQ_UID_BASE="$UIDBASE" \
    PERQ_X11_SOCKDIR="$sockdir" PERQ_GEOM=768x1048 SH_X11_DISPLAY="$disp" \
    bash "$launcher" || die "launcher failed — see $pwork/station/perqemu.log"

  sleep 3 # let the date prompt render
  DISPLAY="$disp" xwd -root -silent >"$pwork/login.xwd"
  convert "$pwork/login.xwd" "$pwork/login.png"
  DISPLAY="$disp" xdotool key Return
  sleep 1
  DISPLAY="$disp" xdotool type --delay 80 guest
  DISPLAY="$disp" xdotool key Return
  sleep 1
  DISPLAY="$disp" xdotool key Return
  sleep 2
  DISPLAY="$disp" xwd -root -silent >"$pwork/shell.xwd"
  convert "$pwork/shell.xwd" "$pwork/shell.png"

  # Teardown: kill by the pidfiles the launcher just wrote (this is a
  # throwaway proof rig, not a supervised station — direct kill is fine).
  # MEASURED: sending SIGTERM to the nspawn SUPERVISOR pid and then SIGKILL
  # after only 1 s does NOT reliably tear down the container — nspawn's own
  # cgroup-kill of everything inside is part of its graceful shutdown, and a
  # supervisor killed too fast (or the mono child killed directly, which
  # `script -qfec` does not treat as its own EOF because perq-inner.sh holds
  # stdin open on a FIFO) leaves `script` and Xvfb running as orphans in the
  # namespace, and the mount point `kh-<tile>` in
  # /run/systemd/nspawn/unix-export/ still "exists" for the NEXT launch to
  # trip over. Send TERM, give it up to 5 s to actually exit, then sweep
  # every pid still in the container's process group before declaring done.
  local mpid npid i
  mpid="$(cat "$pwork/station/mame.pid" 2>/dev/null || true)"
  npid="$(cat "$pwork/station/nspawn.pid" 2>/dev/null || true)"
  [ -n "$npid" ] && kill -TERM "$npid" 2>/dev/null
  [ -n "$mpid" ] && kill -TERM "$mpid" 2>/dev/null
  for i in $(seq 1 10); do
    kill -0 "$npid" 2>/dev/null || kill -0 "$mpid" 2>/dev/null || break
    sleep 0.5
  done
  [ -n "$mpid" ] && kill -9 "$mpid" 2>/dev/null
  [ -n "$npid" ] && kill -9 "$npid" 2>/dev/null
  # `script`'s pty wrapper does not exit on its child's death (perq-inner.sh
  # holds stdin open on a FIFO precisely so it never sees EOF — see its own
  # header): it and Xvfb can outlive mpid/npid as orphans in the namespace.
  # Find them by /proc/<pid>/exe (rule 5: never a cmdline grep) among the
  # DIRECT CHILDREN of the nspawn stub this run started.
  local stub gen1
  stub="$(ps -o pid= --ppid "$npid" 2>/dev/null | tr -d ' ')"
  if [ -n "$stub" ]; then
    gen1="$(ps -o pid= --ppid "$stub" 2>/dev/null)"
    for p in $gen1 $(ps -o pid= --ppid "${gen1:-0}" 2>/dev/null); do
      case "$(readlink "/proc/$p/exe" 2>/dev/null)" in
        */script | */Xvfb | */mono-sgen) kill -9 "$p" 2>/dev/null ;;
      esac
    done
  fi

  log "proof frames: $pwork/login.png $pwork/shell.png"
  echo "$pwork"
}

if [ "$FETCH" = 0 ] && [ "$DO_ROOTFS" = 0 ] && [ "$PROVE" = 0 ]; then
  log "nothing to do — pass --fetch, --rootfs and/or --prove"
  exit 2
fi
if [ "$FETCH" = 1 ]; then
  stage
fi
if [ "$DO_ROOTFS" = 1 ]; then
  build_rootfs
fi
if [ "$PROVE" = 1 ]; then
  [ -f "$OUT/perqemu/PERQemu.exe" ] || die "no $OUT/perqemu/PERQemu.exe — run with --fetch first"
  [ -x "$OUT/rootfs/usr/bin/mono-sgen" ] || die "no $OUT/rootfs/usr/bin/mono-sgen — run with --rootfs first"
  prove
fi

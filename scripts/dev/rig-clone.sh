#!/usr/bin/env bash
# rig-clone.sh — clone a smoke rig N times so cheap agents can RACE theories
# against a bring-up wall, then keep the winner and kill the rest.
#
# WHY. netbsd14 golden stream (2026-09-03): the installed GENERIC kernel hung in
# the ISA probe after `lpt0`. One (Fable) agent then bisected it SERIALLY: reboot,
# wait ~40 s, look, `boot -c`, disable one device, reboot ... Each theory cost a
# full boot + a guessed wait, one after the other. The operator's rule from that
# retro (docs/lab/BREAKTHROUGH-RACE.md): a wall with several plausible causes is
# raced — one cheap agent per theory, each on its OWN clone of the rig, first
# framebuffer proof wins, the rest are killed. This is the clone/kill half of
# that; fb-wait.py is the waiting half.
#
# usage (from CT950 or on labhost; it hops to labhost by itself):
#   rig-clone.sh new  <id> <theory> [--rig DIR] [--boot a|c] [--force] [-- <extra qemu args>]
#   rig-clone.sh ls   <id>
#   rig-clone.sh keep <id> <theory>          # kill every OTHER clone of <id>
#   rig-clone.sh down <id> <theory>|--all [--rm]
#
# `new` refuses to start a guest when labhost's 1-min load average exceeds
# KH_LOAD_CAP (default 50) — the box is already saturated, and a wall is
# raced with cheap clones, not by adding to the pile (rule 14). --force
# overrides for a caller that has already weighed the cost. Probe command
# and cap are both overridable (KH_LOADAVG_CMD, KH_LOAD_CAP) — see
# scripts/lib/load-guard.sh.
#
# A clone is /data/vms/sandbox/<id>/race/<theory>/ : a sparse COPY of the rig's
# disk image(s) (a qcow2 overlay would share a backing file the running rig is
# still writing), symlinks to read-only media, and launch.sh = the rig's
# launch-smoke.sh rewritten for the clone: its own dir, `-name race-<id>-<theory>`,
# every `hostfwd=` clause dropped (host ports would collide), and `${RIG_EXTRA}`
# — the theory's extra QEMU arguments — spliced in before `-qmp`. Extra args can
# only ADD flags; a theory that must REMOVE one (KVM -> TCG) edits launch.sh by
# hand after `new` and relaunches it. Every kill goes through clone-guard by
# pidfile (rule 5); nothing here can touch /data/vms/streamhost/stations.
#
# Clones need no kh-claim: no UDP port, no VMID, no display of their own. They
# are NOT published — the agent reads the framebuffer with fb-wait.py --out and
# qmp-type.py --shot. Rig convention this relies on: <rig>/launch-smoke.sh runs
# QEMU with `-qmp unix:qmp.sock,server=on,wait=off -pidfile qemu.pid` from a
# `cd <rig>` at the top, media by relative name, `-boot ${1:-a}`.
set -euo pipefail

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

# ---- hop to labhost: the clone root and clone-guard live there -------------
if [ -z "${RIG_CLONE_ON_BOX:-}" ]; then
  self="$(readlink -f "$0")"
  case "$self" in
    /data/*) box_self="$self" ;;
    *) box_self="/data/kernel-hive/scripts/dev/rig-clone.sh" ;; # shared clone -> box checkout
  esac
  q=""
  for a in "$@"; do q+=" $(printf '%q' "$a")"; done
  exec ssh -n lab "RIG_CLONE_ON_BOX=1 KH_SESSION=$(printf '%q' "${KH_SESSION:-}") bash $box_self$q"
fi

ROOT=/data/vms/sandbox
GUARD=/usr/local/bin/clone-guard
[ -x "$GUARD" ] || {
  echo "rig-clone: $GUARD missing on this host" >&2
  exit 1
}

LIB_DIR="$(cd "$(dirname "$(readlink -f "$0")")/../lib" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/load-guard.sh"

cmd="${1:-}"
[ -n "$cmd" ] || usage 1
id="${2:-}"
[ -n "$id" ] || usage 1
race="$ROOT/$id/race"

alive() { # alive <clonedir> -> prints pid if its pidfile names a live qemu
  local pf="$1/qemu.pid" pid exe
  [ -f "$pf" ] || return 1
  pid="$(cat "$pf" 2>/dev/null)" || return 1
  exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
  case "$exe" in *qemu-system*) echo "$pid" ;; *) return 1 ;; esac
}

case "$cmd" in
  new)
    theory="${3:-}"
    [ -n "$theory" ] || usage 1
    case "$theory" in *[!A-Za-z0-9_.-]*)
      echo "rig-clone: theory name must be [A-Za-z0-9_.-]" >&2
      exit 1
      ;;
    esac
    shift 3
    rig="$ROOT/$id/smoke"
    boot=""
    force=0
    extra=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --rig)
          rig="$2"
          shift 2
          ;;
        --boot)
          boot="$2"
          shift 2
          ;;
        --force)
          force=1
          shift
          ;;
        --)
          shift
          extra=("$@")
          break
          ;;
        *)
          echo "rig-clone: unknown option $1" >&2
          usage 1
          ;;
      esac
    done
    load_guard_check "clone $id/$theory" "$force" || exit 1
    "$GUARD" assert-path "$rig" >/dev/null
    [ -f "$rig/launch-smoke.sh" ] || {
      echo "rig-clone: $rig/launch-smoke.sh missing (see the rig convention in the header)" >&2
      exit 1
    }
    dir="$race/$theory"
    if [ -e "$dir" ]; then
      if alive "$dir" >/dev/null; then
        echo "rig-clone: $dir is already running (down it first)" >&2
        exit 1
      fi
      rm -rf "$dir"
    fi
    mkdir -p "$dir"
    if alive "$rig" >/dev/null; then
      echo "rig-clone: NOTE the rig guest is running; the disk copy is crash-consistent at best (fine for a race, not for a golden)" >&2
    fi
    t0=$(date +%s.%N)
    for f in "$rig"/*; do
      b="$(basename "$f")"
      case "$b" in
        *.qcow2 | *.raw | *.img | *.fs | *.hdf) cp --sparse=always "$f" "$dir/$b" ;; # writable guest media: copy
        *.iso | *.rom | *.bin) ln -s "$f" "$dir/$b" ;;                               # read-only media: link
        *) : ;;
      esac
    done
    # launch.sh: the rig launcher, re-homed. Order matters: rewrite the rig path
    # BEFORE checking the result with clone-guard.
    # shellcheck disable=SC2016  # ${RIG_EXTRA} is meant for the clone's shell, not this one
    sed -e "s#$rig#$dir#g" \
      -e "s/-name [^ ]*/-name race-$id-$theory/" \
      -e 's/,hostfwd=[^ ,]*//g' \
      -e 's/^\([[:space:]]*\)-qmp /\1${RIG_EXTRA:-} -qmp /' \
      "$rig/launch-smoke.sh" >"$dir/launch.sh"
    chmod +x "$dir/launch.sh"
    "$GUARD" check-launcher "$dir/launch.sh" >/dev/null
    printf '%s\n' "${extra[@]}" >"$dir/theory.args" 2>/dev/null || : >"$dir/theory.args"
    RIG_EXTRA="${extra[*]:-}" "$dir/launch.sh" ${boot:+"$boot"} >"$dir/launch.log" 2>&1 || {
      echo "rig-clone: launch failed:"
      cat "$dir/launch.log"
      exit 1
    } >&2
    pid="$(alive "$dir" || true)"
    [ -n "$pid" ] || {
      echo "rig-clone: QEMU did not come up; $dir/qemu.log:" >&2
      tail -20 "$dir/qemu.log" >&2
      exit 1
    }
    printf 'clone %s/%s up: pid=%s qmp=%s/qmp.sock extra=[%s] in %.1fs\n' \
      "$id" "$theory" "$pid" "$dir" "${extra[*]:-}" "$(awk -v a="$(date +%s.%N)" -v b="$t0" "BEGIN{print a-b}")"
    echo "  wait:  python3 <repo>/scripts/dev/fb-wait.py --qmp $dir/qmp.sock --settle 8 --timeout 120 --out $dir/fb.png"
    echo "  type:  python3 <repo>/scripts/dev/qmp-type.py --qmp $dir/qmp.sock --keys ... --out $dir/fb.png"
    ;;
  ls)
    [ -d "$race" ] || {
      echo "no clones under $race"
      exit 0
    }
    for d in "$race"/*/; do
      d="${d%/}"
      t="$(basename "$d")"
      if pid="$(alive "$d")"; then
        up="$(ps -o etimes= -p "$pid" | tr -d ' ')"
        printf '%-24s alive pid=%-8s up=%ss  extra=[%s]\n' "$t" "$pid" "$up" "$(tr '\n' ' ' <"$d/theory.args" 2>/dev/null)"
      else
        printf '%-24s dead                    extra=[%s]\n' "$t" "$(tr '\n' ' ' <"$d/theory.args" 2>/dev/null)"
      fi
    done
    ;;
  keep | down)
    target="${3:-}"
    [ -n "$target" ] || usage 1
    rm_after=0
    [ "${4:-}" = "--rm" ] && rm_after=1
    [ -d "$race" ] || {
      echo "no clones under $race"
      exit 0
    }
    for d in "$race"/*/; do
      d="${d%/}"
      t="$(basename "$d")"
      if [ "$cmd" = keep ]; then
        [ "$t" = "$target" ] && continue
      else [ "$target" != --all ] && [ "$t" != "$target" ] && continue; fi
      if alive "$d" >/dev/null; then
        "$GUARD" kill-pidfile "$d/qemu.pid" && echo "killed $id/$t"
      else
        echo "already dead $id/$t"
      fi
      [ "$rm_after" = 1 ] && rm -rf "$d" && echo "removed $d"
    done
    if [ "$cmd" = keep ]; then echo "kept $id/$target (winner): $race/$target"; fi
    ;;
  *) usage 1 ;;
esac

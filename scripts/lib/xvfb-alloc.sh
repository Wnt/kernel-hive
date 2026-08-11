#!/bin/bash
# xvfb-alloc.sh — the ONE way lab rigs get an Xvfb display: atomic claim,
# loud failure, self-cleaning.
#
# WHY THIS EXISTS (the incident it prevents)
#   Rig scripts each picked a display number by hand (`:41`, `:77`, `:151`) and
#   then "verified" the server with
#       Xvfb "$DISP" … &
#       [ -S /tmp/.X11-unix/X${DISP#:} ] || die
#   That test is satisfied by SOMEONE ELSE'S server. During a multi-agent
#   campaign two rigs both chose `:77`: the second Xvfb died on the spot ("server
#   already running"), the socket test passed anyway because the FIRST agent's
#   socket was sitting there, and the loser silently drove — and screenshotted —
#   its sibling's display for ~12 minutes. Nobody noticed until synthesis. Some
#   rigs made it worse by `rm -f`-ing the socket first, i.e. kicking the rightful
#   owner off its own display.
#
# WHAT THIS GUARANTEES
#   * ATOMIC claim. The claim is the X server's OWN exclusion — under
#     `-displayfd` it writes no /tmp/.X<n>-lock and instead binds the abstract
#     socket @/tmp/.X11-unix/X<n>, which the kernel grants to exactly one
#     process. We never check-then-create. The display number is reported back BY
#     that server on the fd, so it is the number it really owns.
#   * NEVER a silent fallback. Success requires OUR child to be alive, to have
#     reported a display in the range we asked for, and to BE the process
#     listening on that display's socket. Anything else is a non-zero exit with a
#     loud message. There is no code path in which a caller ends up on a display
#     it did not start.
#   * Orphan-safe. A crashed owner's stale lock/socket is reclaimed by the next X
#     server that binds there, so a dead sibling never deadlocks the pool. `reap`
#     clears the leftover files, and only ever files whose owning process is
#     provably gone.
#   * Released on exit, including on signal (EXIT/INT/TERM/HUP traps, chained
#     onto any handler the caller already installed).
#
# DUAL USE
#   * source it:  source /usr/local/bin/xvfb-alloc
#                 xvfb_alloc --screen 1280x1024x24 --pidfile "$D/xvfb.pid"
#                 …            # $XVFB_DISPLAY is yours, e.g. ":66"
#                 xvfb_release # (also runs automatically from the exit trap)
#   * run it CLI: xvfb-alloc alloc  [--screen WxHxD] [--min N] [--max N]
#                                   [--display N] [--pidfile F] [--log F]
#                     → prints eval-able XVFB_DISPLAY=… / XVFB_PID=… on stdout
#                       and leaves the server running (no exit trap)
#                 xvfb-alloc release <pidfile|:N|pid>
#                 xvfb-alloc list            # every display + owner + state
#                 xvfb-alloc reap [--force]  # remove ORPHAN lock/socket files only
#
# `--display N` pins one number (min=max=N) for the cases that genuinely need a
# fixed display — e.g. the IRIX station, whose streamhost service is configured with
# SH_X11_DISPLAY. Pinned or pooled, the claim and the failure mode are identical:
# if N is not free you get a non-zero exit, never someone else's server.
#
# SOURCE OF TRUTH: scripts/lib/xvfb-alloc.sh in the osgallery repo, kept
# byte-identical to the box copy /usr/local/bin/xvfb-alloc (box-sync pair, see
# scripts/README.md). Re-sync after any edit.

# ---- configuration ---------------------------------------------------------
# The pool. :0/:1 are real desktops (:1 is the shared CT950 dev desktop) and the
# low numbers are hand-assigned by older tooling, so the pool starts well above
# them. FLOOR is a hard refusal, not a default: no caller may pin below it.
XVFB_ALLOC_MIN="${XVFB_ALLOC_MIN:-64}"
XVFB_ALLOC_MAX="${XVFB_ALLOC_MAX:-191}"
XVFB_ALLOC_FLOOR="${XVFB_ALLOC_FLOOR:-10}"
XVFB_ALLOC_TIMEOUT="${XVFB_ALLOC_TIMEOUT:-20}" # seconds to wait for one server
XVFB_ALLOC_XSOCKDIR="${XVFB_ALLOC_XSOCKDIR:-/tmp/.X11-unix}"
XVFB_ALLOC_LOCKDIR="${XVFB_ALLOC_LOCKDIR:-/tmp}"
# Advisory ledger of who claimed what (a NOTE, never the claim itself — the
# claim is the socket bind). Lets one agent see another's displays by name.
XVFB_ALLOC_STATEDIR="${XVFB_ALLOC_STATEDIR:-/tmp/.xvfb-alloc}"

_xa_err() { printf 'xvfb-alloc: FATAL: %s\n' "$*" >&2; }
_xa_warn() { printf 'xvfb-alloc: WARN: %s\n' "$*" >&2; }

_xa_lockfile() { printf '%s/.X%s-lock' "$XVFB_ALLOC_LOCKDIR" "$1"; }
_xa_sockfile() { printf '%s/X%s' "$XVFB_ALLOC_XSOCKDIR" "$1"; }

# _xa_lockpid <dispnum> — pid recorded in the X lock file (blank if none). Only
# servers started WITHOUT -displayfd write one; see _xa_ownerpid.
_xa_lockpid() {
  local f p
  f="$(_xa_lockfile "$1")"
  [ -f "$f" ] || return 0
  p="$(tr -d ' \t\n' <"$f" 2>/dev/null)"
  case "$p" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s' "$p"
}

# _xa_ownerpid <dispnum> — the pid that ACTUALLY holds display :N, or blank if
# nothing does (i.e. the display is free, or its files are orphaned).
#
# The authority is the listening socket, not a file: with `-displayfd` the X
# server does not write /tmp/.X<n>-lock at all, and it excludes rivals by binding
# the abstract socket @/tmp/.X11-unix/X<n> — a kernel-atomic operation, which is
# exactly the property this helper is built on. A lock file, when one exists
# (servers started the old way), is the fallback answer.
_xa_ownerpid() {
  local n="$1" p=""
  if command -v ss >/dev/null 2>&1; then
    p="$(ss -lxpH 2>/dev/null |
      sed -n "s#.*[@ ]$XVFB_ALLOC_XSOCKDIR/X$n .*pid=\([0-9]\+\).*#\1#p" | head -1)"
  fi
  if [ -z "$p" ]; then
    p="$(_xa_lockpid "$n")"
    [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && p=""
  fi
  printf '%s' "$p"
}

# ---- ownership registry ----------------------------------------------------
# Every display THIS shell claimed, as "pid disp pidfile". Nothing else is ever
# touched by release/reap.
_XA_OWNED=()

# _xa_chain_trap <signal> — install the release handler without clobbering a
# handler the caller already set (the previous one runs first).
_xa_chain_trap() {
  local sig="$1" prev var
  prev="$(trap -p "$sig")"
  prev="${prev#trap -- }"
  prev="${prev% "$sig"}"
  var="_XA_PREV_$sig"
  # `prev` is shell-quoted as printed by `trap -p`; the inner eval unquotes it.
  printf -v "$var" '%s' "$prev"
  # shellcheck disable=SC2064  # $sig must expand NOW — it names this trap.
  trap "_xa_on_signal $sig" "$sig"
}

_xa_on_signal() {
  local sig="$1" var="_XA_PREV_$1" prev
  prev="${!var-}"
  [ -n "$prev" ] && [ "$prev" != "''" ] && eval "eval $prev"
  xvfb_release_all
  case "$sig" in
    EXIT) ;;
    *)
      trap - "$sig"
      kill -"$sig" $$
      ;;
  esac
}

_xa_install_traps() {
  [ -n "${_XA_TRAPS_INSTALLED:-}" ] && return 0
  _XA_TRAPS_INSTALLED=1
  local s
  for s in EXIT INT TERM HUP; do _xa_chain_trap "$s"; done
}

# ---- allocation ------------------------------------------------------------
# xvfb_alloc [--screen WxHxD] [--min N] [--max N] [--display N] [--pidfile F]
#            [--log F] [--no-trap] [-- <extra Xvfb args>…]
# On success: exports XVFB_DISPLAY (":66"), XVFB_DISPLAY_NUM, XVFB_PID,
# XVFB_SOCKET, XVFB_LOG, XVFB_PIDFILE and returns 0.
# On failure: prints why and returns non-zero. It never returns a display that
# some other process owns.
xvfb_alloc() {
  local screen="1280x1024x24" min="$XVFB_ALLOC_MIN" max="$XVFB_ALLOC_MAX"
  local log="" pidfile="" tag="${0##*/}" traps=1
  local extra=() d pid got fdfile ownerpid deadline now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --screen)
        screen="$2"
        shift 2
        ;;
      --min)
        min="$2"
        shift 2
        ;;
      --max)
        max="$2"
        shift 2
        ;;
      --display)
        min="${2#:}"
        max="${2#:}"
        shift 2
        ;;
      --log)
        log="$2"
        shift 2
        ;;
      --pidfile)
        pidfile="$2"
        shift 2
        ;;
      --tag)
        tag="$2"
        shift 2
        ;;
      --no-trap)
        traps=0
        shift
        ;;
      --)
        shift
        extra=("$@")
        break
        ;;
      *)
        _xa_err "unknown option: $1"
        return 2
        ;;
    esac
  done
  case "$min$max" in *[!0-9]*)
    _xa_err "display range must be numeric (min=$min max=$max)"
    return 2
    ;;
  esac
  if [ "$min" -lt "$XVFB_ALLOC_FLOOR" ]; then
    _xa_err "refusing display range below :$XVFB_ALLOC_FLOOR (min=:$min) — :0/:1 are real desktops"
    return 2
  fi
  [ "$max" -ge "$min" ] || {
    _xa_err "empty display range :$min..:$max"
    return 2
  }
  command -v Xvfb >/dev/null 2>&1 || {
    _xa_err "Xvfb is not installed"
    return 2
  }
  log="${log:-${TMPDIR:-/tmp}/xvfb-alloc.$$.log}"
  fdfile="$(mktemp "${TMPDIR:-/tmp}/xvfb-displayfd.XXXXXX")" || return 2

  for ((d = min; d <= max; d++)); do
    : >"$fdfile"
    # -displayfd makes the SERVER report which display it took: the answer comes
    # from the process that holds the lock, not from a guess we made.
    Xvfb ":$d" -displayfd 3 -screen 0 "$screen" -nolisten tcp "${extra[@]}" \
      3>"$fdfile" >"$log" 2>&1 &
    pid=$!
    got=""
    deadline=$(($(date +%s) + XVFB_ALLOC_TIMEOUT))
    while :; do
      # `read` succeeds only on a COMPLETE newline-terminated line, so a partial
      # write can never be mistaken for a display number.
      if IFS= read -r got <"$fdfile" 2>/dev/null; then
        got="${got//[[:space:]]/}"
        break
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        got=""
        break # :$d was taken (or the server failed) — try the next one
      fi
      now="$(date +%s)"
      if [ "$now" -ge "$deadline" ]; then
        kill -TERM "$pid" 2>/dev/null || true
        _xa_err "Xvfb :$d did not report a display within ${XVFB_ALLOC_TIMEOUT}s (log: $log)"
        rm -f -- "$fdfile"
        return 1
      fi
      sleep 0.1
    done
    [ -n "$got" ] || {
      wait "$pid" 2>/dev/null || true
      continue
    }

    # Proof of OWNERSHIP before we hand the display over: our own child is alive,
    # it reported this number itself, the number is in the range we asked for,
    # the socket exists, and the process listening on that socket is that child.
    # Attaching to a server we did not start is the bug this helper exists for,
    # so every one of these is a hard failure, never a fallback.
    case "$got" in '' | *[!0-9]*) got=-1 ;; esac
    ownerpid="$(_xa_ownerpid "$got")"
    if [ "$got" -lt "$min" ] || [ "$got" -gt "$max" ] || [ ! -S "$(_xa_sockfile "$got")" ] ||
      { [ -n "$ownerpid" ] && [ "$ownerpid" != "$pid" ]; }; then
      kill -TERM "$pid" 2>/dev/null || true
      _xa_err "server on :$got is not ours (range :$min..:$max, socket owner '$ownerpid', our pid $pid) — refusing to attach"
      rm -f -- "$fdfile"
      return 1
    fi

    rm -f -- "$fdfile"
    XVFB_DISPLAY_NUM="$got"
    XVFB_DISPLAY=":$got"
    XVFB_PID="$pid"
    XVFB_SOCKET="$(_xa_sockfile "$got")"
    XVFB_LOG="$log"
    XVFB_PIDFILE="$pidfile"
    export XVFB_DISPLAY XVFB_DISPLAY_NUM XVFB_PID XVFB_SOCKET XVFB_LOG
    [ -n "$pidfile" ] && printf '%s\n' "$pid" >"$pidfile"
    # Cross-agent visibility: `xvfb-alloc list` can then say WHO owns :66.
    mkdir -p "$XVFB_ALLOC_STATEDIR" 2>/dev/null &&
      printf '%s %s %s\n' "$pid" "$tag" "$(date '+%F %T')" >"$XVFB_ALLOC_STATEDIR/$got" 2>/dev/null
    _XA_OWNED+=("$pid $got $pidfile")
    [ "$traps" = 1 ] && _xa_install_traps
    return 0
  done

  rm -f -- "$fdfile"
  _xa_err "no free display in :$min..:$max (all $((max - min + 1)) are in use) — NOT falling back to an existing display"
  return 1
}

# ---- release ---------------------------------------------------------------
# _xa_kill <pid> <dispnum> — stop a server we own and clear its files. Refuses
# to signal a pid that does not hold that display's lock.
_xa_kill() {
  local pid="$1" disp="$2" ownerpid i
  ownerpid="$(_xa_ownerpid "$disp")"
  if [ -n "$ownerpid" ] && [ "$ownerpid" != "$pid" ]; then
    _xa_warn "not releasing :$disp — it is held by pid $ownerpid, not $pid"
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  # A -KILL leaves the lock/socket/ledger files behind; they are ours, so clear
  # them — but only once nothing is listening on that display any more.
  if ! kill -0 "$pid" 2>/dev/null && [ -z "$(_xa_ownerpid "$disp")" ]; then
    rm -f -- "$(_xa_lockfile "$disp")" "$(_xa_sockfile "$disp")" \
      "$XVFB_ALLOC_STATEDIR/$disp"
  fi
  return 0
}

# xvfb_release [pidfile|:N|pid] — release one display; no argument = the one
# this shell allocated last.
xvfb_release() {
  local target="${1:-}" pid="" disp="" pidfile="" entry p d pf rest=() found=0
  if [ -z "$target" ] && [ "${#_XA_OWNED[@]}" -gt 0 ]; then
    read -r p d pf <<<"${_XA_OWNED[-1]}"
    target=":$d"
  fi
  [ -n "$target" ] || return 0
  case "$target" in
    :*) disp="${target#:}" ;;
    *[!0-9]*) # a pidfile
      pidfile="$target"
      [ -f "$pidfile" ] || {
        _xa_warn "no such pidfile: $pidfile"
        return 0
      }
      pid="$(tr -d ' \n' <"$pidfile")"
      ;;
    *) pid="$target" ;;
  esac
  for entry in ${_XA_OWNED[@]+"${_XA_OWNED[@]}"}; do
    read -r p d pf <<<"$entry"
    if [ "$disp" = "$d" ] || [ "$pid" = "$p" ]; then
      found=1
      # A registry entry whose server died and whose display has since been
      # claimed by someone else is STALE: forget it, never signal the new owner.
      if kill -0 "$p" 2>/dev/null || [ -z "$(_xa_ownerpid "$d")" ]; then
        _xa_kill "$p" "$d" || true
        [ -n "$pf" ] && rm -f -- "$pf"
      fi
    else
      rest+=("$entry")
    fi
  done
  _XA_OWNED=(${rest[@]+"${rest[@]}"})
  if [ "$found" = 0 ]; then
    # Not in our registry: act only on the pid that PROVABLY holds the display.
    if [ -n "$pid" ] && [ -z "$disp" ]; then
      for d in $(_xa_owned_displays_of "$pid"); do _xa_kill "$pid" "$d" || true; done
    elif [ -n "$disp" ]; then
      pid="$(_xa_lockpid "$disp")"
      [ -n "$pid" ] && _xa_kill "$pid" "$disp"
    fi
    [ -n "$pidfile" ] && rm -f -- "$pidfile"
  fi
  return 0
}

# _xa_display_numbers — every display number with a lock, socket or ledger entry.
_xa_display_numbers() {
  local f n seen=""
  for f in "$XVFB_ALLOC_LOCKDIR"/.X*-lock "$XVFB_ALLOC_XSOCKDIR"/X* \
    "$XVFB_ALLOC_STATEDIR"/*; do
    [ -e "$f" ] || continue
    n="${f##*/}"
    n="${n#.X}"
    n="${n#X}"
    n="${n%-lock}"
    case "$n" in '' | *[!0-9]*) continue ;; esac
    case " $seen " in *" $n "*) continue ;; esac
    seen="$seen $n"
    printf '%s\n' "$n"
  done
}

_xa_owned_displays_of() { # $1 = pid → display numbers that pid holds
  local n
  for n in $(_xa_display_numbers); do
    [ "$(_xa_ownerpid "$n")" = "$1" ] && printf '%s\n' "$n"
  done
}

xvfb_release_all() {
  local entry p d pf
  for entry in ${_XA_OWNED[@]+"${_XA_OWNED[@]}"}; do
    read -r p d pf <<<"$entry"
    _xa_kill "$p" "$d" || true
    [ -n "$pf" ] && rm -f -- "$pf"
  done
  _XA_OWNED=()
}

# ---- inventory -------------------------------------------------------------
# xvfb_list — every display on this host with its owner and state. ORPHAN means
# the lock/socket outlived its server; LIVE means a real process holds it.
xvfb_list() {
  local n pid state cmd owner
  printf '%-8s %-7s %-8s %-22s %s\n' DISPLAY STATE PID OWNER COMMAND
  for n in $(_xa_display_numbers); do
    pid="$(_xa_ownerpid "$n")"
    owner="$(cut -d' ' -f2 "$XVFB_ALLOC_STATEDIR/$n" 2>/dev/null)"
    if [ -n "$pid" ]; then
      state=LIVE
      cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | cut -c1-60)"
    else
      state=ORPHAN
      cmd="(no listener; lock/socket/ledger left behind)"
    fi
    printf '%-8s %-7s %-8s %-22s %s\n' ":$n" "$state" "${pid:--}" "${owner:--}" "$cmd"
  done
}

# xvfb_reap [--force] [--min N] [--max N] — remove the lock/socket/ledger files
# of displays whose owning process is GONE. Never signals anything; never touches
# a LIVE display. Without --min/--max it reports (or clears) every orphan on the
# host, so a rig cleaning up after itself should bound it to its own range.
xvfb_reap() {
  local force=0 lo=0 hi=99999 n was acted=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)
        force=1
        shift
        ;;
      --min)
        lo="$2"
        shift 2
        ;;
      --max)
        hi="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  for n in $(_xa_display_numbers); do
    { [ "$n" -lt "$lo" ] || [ "$n" -gt "$hi" ]; } && continue
    [ -n "$(_xa_ownerpid "$n")" ] && continue # LIVE — hands off, always
    acted=1
    was="$(_xa_lockpid "$n")"
    [ -n "$was" ] || was="$(cut -d' ' -f1 "$XVFB_ALLOC_STATEDIR/$n" 2>/dev/null)"
    if [ "$force" = 1 ]; then
      rm -f -- "$(_xa_lockfile "$n")" "$(_xa_sockfile "$n")" "$XVFB_ALLOC_STATEDIR/$n"
      printf 'reaped :%s (owner pid %s is gone)\n' "$n" "${was:-unknown}"
    else
      printf 'orphan :%s (owner pid %s is gone) — rerun with --force to remove\n' "$n" "${was:-unknown}"
    fi
  done
  [ "$acted" = 0 ] && printf 'no orphaned displays\n'
  return 0
}

# ---- CLI -------------------------------------------------------------------
_xa_cli() {
  local verb="${1:-}"
  shift || true
  case "$verb" in
    alloc)
      # CLI allocations OUTLIVE this process on purpose (the caller is a rig that
      # goes on to run something else), so no exit trap here.
      xvfb_alloc --no-trap "$@" || exit 1
      printf 'XVFB_DISPLAY=%s\nXVFB_DISPLAY_NUM=%s\nXVFB_PID=%s\nXVFB_LOG=%s\n' \
        "$XVFB_DISPLAY" "$XVFB_DISPLAY_NUM" "$XVFB_PID" "$XVFB_LOG"
      ;;
    release)
      [ "$#" -ge 1 ] || {
        _xa_err "usage: xvfb-alloc release <pidfile|:N|pid>"
        exit 2
      }
      xvfb_release "$1"
      ;;
    list) xvfb_list ;;
    reap) xvfb_reap "$@" ;;
    *)
      sed -n '2,50p' "$0" >&2
      exit 2
      ;;
  esac
}

# Sourced or executed? (BASH_SOURCE[0] != $0 ⇒ sourced.)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _xa_cli "$@"
fi

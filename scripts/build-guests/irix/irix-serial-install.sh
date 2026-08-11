#!/usr/bin/env bash
# irix-serial-install.sh — install the serial exec agent into a BOOTED IRIX
# clone, over the guest's own console getty, and prove it answers.
#
#   irix-serial-rig.sh boot bake1 --console          # ~5 min cold boot
#   irix-serial-install.sh bake1                     # ~3 min
#   irix-serial-rig.sh exec bake1 "uname -a"         # REAL captured stdout
#   irix-serial-rig.sh halt bake1                    # clean shutdown
#   # -> /data/vms/soltest/irix-serial/bake1/disk.chd is the new golden
#
# WHY THE CONSOLE AND NOT AN ISO.  /etc/inittab ships `t1:23:respawn:...getty
# ttyd1 console`, so an IRIX login prompt is sitting on serial port 1 from the
# moment the station boots, with an empty root password. That is the whole
# bootstrap: no CD image, no key matrix (whose natkeyboard path silently drops
# every shifted character), no pointer work. Host->guest is byte-clean once the
# getty's echo is off; guest->host is not, which is why nothing here reads the
# console back — verification goes through the agent, on the OTHER port.
#
# Runs ON the box. Touches only /data/vms/soltest/irix-serial/<name>.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="${IRIX_SERIAL_RIG:-$HERE/irix-serial-rig.sh}"
SRC="${IRIX_AGENT_SRC:-$HERE/../../../streamhost/guest-agents/irix}"
ROOT="${IRIX_SERIAL_ROOT:-/data/vms/soltest/irix-serial}"
# Seconds between console lines. The guest's ttyd1 runs at 9600 baud in
# canonical mode, so a ~70-character line needs ~75 ms on the wire plus the
# shell's own read; 0.18 s has a comfortable margin and pushes the 11 KB agent
# across in about a minute. Every byte is checksum-verified afterwards.
LINE_DELAY="${IRIX_INSTALL_LINE_DELAY:-0.18}"

NAME="${1:-}"
[ -n "$NAME" ] || {
  echo "usage: irix-serial-install.sh <clone-name>" >&2
  exit 2
}
D="$ROOT/$NAME"
[ -d "$D" ] || {
  echo "no such clone: $D" >&2
  exit 2
}

log() { echo "$(date '+%F %T') $*"; }
die() {
  echo "irix-serial-install: $*" >&2
  exit 1
}

PTS_CONSOLE="$("$RIG" pts "$NAME" | sed -n 2p)"
[ -n "$PTS_CONSOLE" ] || die "no console pty — boot the clone with --console"
log "console line: $PTS_CONSOLE"

say() {
  printf '%s\r' "$1" >"$PTS_CONSOLE"
  sleep "$LINE_DELAY"
}
# Push a host file into the guest through a quoted here-document. The delimiter
# is quoted, so the guest shell does no expansion and the bytes land verbatim.
push() {
  local src="$1" dst="$2" line
  say "cat > $dst <<'IRIXAGENT_EOF'"
  while IFS= read -r line; do say "$line"; done <"$src"
  say "IRIXAGENT_EOF"
}

# ---- 1. log in and get a quiet, non-echoing Bourne shell --------------------
# Order here is all load-bearing, and every step of it was paid for once:
#   * the stray delimiter first, so a here-document left open by an aborted run
#     is closed before anything else is typed (at a prompt it is merely a
#     command that does not exist);
#   * `root` logs in with an empty password, but /etc/profile then asks
#     `TERM = (vt100)` and EATS THE NEXT LINE — the blank answer takes the
#     default. Losing `stty` to that prompt is what wedged the first attempt;
#   * `exec /bin/sh` before the stty, because root's login shell is csh and csh
#     performs history expansion on `!`, which this agent's source is full of;
#   * echo off LAST but before any bulk transfer: while the guest is echoing it
#     is transmitting constantly, and MAME's SCC drops RECEIVED bytes while it
#     does — a here-document typed into an echoing shell arrives corrupted.
#   * NOTHING may be typed before `root`. login(1) flushes typeahead before it
#     reads a password, and it asks for one after ANY failed attempt — so a
#     stray line ahead of the username costs you the whole sequence. (This
#     script therefore assumes a FRESH boot sitting at `login:`; if a previous
#     attempt left a shell logged in, stop the clone and boot it again.)
# IRIX_INSTALL_SKIP_LOGIN=1 re-pushes into a console that is ALREADY at a
# quiet shell — the iteration path while developing the agent. The full login
# only works from a virgin `login:` prompt (see above).
if [ "${IRIX_INSTALL_SKIP_LOGIN:-0}" = 1 ]; then
  log "skipping login (IRIX_INSTALL_SKIP_LOGIN=1)"
  say "IRIXAGENT_EOF"
  say "stty -echo -ixon -ixoff -istrip"
  sleep 1
else
  log "logging in on the console"
  say ""
  sleep 2
  say "root" # empty password, so login(1) never prompts for one
  sleep 5
  say ""
  sleep 2
  say "exec /bin/sh"
  sleep 2
  say "stty -echo -ixon -ixoff -istrip"
  sleep 2
  say "IRIXAGENT_EOF" # closes a here-document left open by an aborted run
fi

# ---- 2. stop any agent that is already running ------------------------------
# ORDER IS THE WHOLE POINT. Remove the inittab entry and `telinit q` FIRST, then
# kill: a kill that gets the wrapper but not the perl while the respawn entry is
# still there leaves init starting a SECOND agent, and two agents on one serial
# line interleave their writes into unreadable garbage that looks exactly like
# wire corruption. (`/sbin/killall` is worse still: on SysV it is the shutdown
# helper and signals every process on the machine — it took a clone down.)
# On a first install there is no entry and both steps are no-ops.
log "stopping any previously installed agent (via init)"
say "grep -v '^ia:' /etc/inittab > /tmp/inittab.new"
say "cp /tmp/inittab.new /etc/inittab"
say "/etc/telinit q"
sleep 8
# telinit q alone does NOT always reap the old agent (it ignores SIGHUP so the
# tty cannot take it down, and it has been seen surviving as an orphan of init).
# Killing it by hand is only safe HERE, after the respawn entry is gone — do it
# in any other order and init immediately starts a second one. The guest shell
# evaluates the backticks, so no host-side command substitution is involved.
say "kill -9 \`ps -ef | grep 'irixagen[t]' | awk '{ print \$2 }'\` 2>/dev/null"
sleep 3

# ---- 3. the files -----------------------------------------------------------
log "pushing irixagent.pl ($(wc -l <"$SRC/irixagent.pl") lines)"
say "mkdir -p /usr/local/bin"
push "$SRC/irixagent.pl" /usr/local/bin/irixagent.pl
log "pushing irixagent.sh"
push "$SRC/irixagent.sh" /usr/local/bin/irixagent.sh
say "chmod 755 /usr/local/bin/irixagent.pl /usr/local/bin/irixagent.sh"
# The log, but NEVER the lock. Unlinking a lock FILE does not release the flock
# the running agent holds on that INODE — it just guarantees the next agent
# flocks a brand-new file and starts anyway, which is precisely the two-agents
# state this all exists to prevent. (Observed: a re-install left the old agent
# and the new one both alive on one line.)
say "rm -f /var/tmp/irixagent.log"

# ---- 3b. boot integration ---------------------------------------------------
# An /etc/inittab respawn entry, not an /etc/rc2.d script: init supervises and
# restarts it, `telinit q` applies it in a second instead of a 4.5-minute
# reboot, and it sidesteps rc2's orphan hazard (/etc/rc2 feeds EVERY non-empty
# /etc/rc2.d/S* to /sbin/sh, editor backups included). Idempotent: a re-install
# rewrites the line rather than appending a second one.
log "adding the inittab respawn entry"
say "cp -p /etc/inittab /etc/inittab.preagent"
say "echo 'ia:23:respawn:/usr/local/bin/irixagent.sh </dev/null >/dev/null 2>&1' >> /etc/inittab"
say "/etc/telinit q"
sleep 8

# ---- 4. prove it, on the framebuffer-independent channel it created ----------
log "waiting for the agent to answer on the exec line"
ok=0
for _ in $(seq 1 12); do
  if out="$("$RIG" exec "$NAME" "echo AGENT-ALIVE" 2>&1)" && [ "${out%AGENT-ALIVE*}" != "$out" ]; then
    ok=1
    break
  fi
  sleep 5
done
[ "$ok" = 1 ] || die "the agent never answered: $out"
log "agent answered"

# The single-instance guard is an flock the agent holds for its whole life (a pid
# lock is not enough: the write is not atomic and the boot pid is deterministic,
# so a stale pid frozen into a golden would disable the agent for ever). The
# agent falls back to a pid test if flock is missing — assert here that it does
# not have to, because that fallback is the weak one.
have="$("$RIG" exec "$NAME" "perl -e 'open(F,\">/var/tmp/.flockprobe\"); print flock(F,2) ? \"FLOCK-OK\" : \"FLOCK-NO\"'")"
[ "$have" = "FLOCK-OK" ] || die "the guest's perl has no working flock (got '$have')"
say "rm -f /var/tmp/.flockprobe"
log "guest perl flock: OK"

# Exactly one agent, or the line is unreadable (see above).
# The bracket in the pattern keeps the probe from matching its own command line.
n="$("$RIG" exec "$NAME" "ps -ef | grep 'irixagen[t].pl' | wc -l" | tr -d ' ')"
[ "$n" = 1 ] || die "expected exactly 1 irixagent process, found $n"
log "single agent confirmed"

log "verifying the transferred bytes"
for f in irixagent.pl irixagent.sh; do
  want="$(cksum <"$SRC/$f" | awk '{ print $1, $2 }')"
  got="$("$RIG" exec "$NAME" "cksum < /usr/local/bin/$f" | awk '{ print $1, $2 }')"
  [ "$want" = "$got" ] || die "$f corrupted in transit (host '$want' guest '$got')"
  log "  $f cksum $got OK"
done

# The agent computes an additive 16-bit checksum of its own source at startup and
# puts it in every PING reply. --agent-src makes the client exit 126 unless the
# GUEST is running exactly this file — the only check that can see inside a
# golden without mounting it, and the answer to "somebody edited the repo agent,
# ran the gates green, and shipped; which one is the exhibit running?".
log "confirming the baked agent IS this repo's irixagent.pl"
"$RIG" ping "$NAME" --agent-src "$SRC/irixagent.pl" || die "the guest is not running $SRC/irixagent.pl"
log "INSTALLED. Record the banner above (proto/version/src-sum) next to the"
log "golden's md5 in docs/guests/irix.md. Next: $RIG halt $NAME"

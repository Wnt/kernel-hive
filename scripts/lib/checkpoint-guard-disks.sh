#!/bin/bash
# checkpoint-guard-disks.sh — WHICH FILES HOLD THIS STATION'S CHECKPOINT, and how
# the guard knows.
#
# The third half of checkpoint-guard. checkpoint-guard.sh answers "what is safe to
# delete, and when"; checkpoint-guard-proof.sh answers "does this checkpoint
# actually restore"; this file answers "what, exactly, am I about to back up and
# overwrite". docs/lab/checkpoint-guard.md has carried that as its own section
# ("Which disk it backs up, and how it knows") since before the split.
#
# Sourced by the guard, never run on its own: every function below uses the
# guard's _cpg_qmp / _cpg_log / _cpg_err and its ST_* variables. It is a box-sync
# pair for the same reason the other two halves are (see box-sync-pairs.sh).

# The launcher with comments stripped: a prose line saying "runs WITHOUT -snapshot"
# must not be read as a -snapshot flag.
_cpg_launcher_code() {
  sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "$ST_LAUNCHER"
}

# Exact snapshot-TAG match, never `grep -qw` (wrong because `grep -qw golden` also
# matches `golden-new`). Getting this wrong here is catastrophic: resume would
# believe `golden` was already promoted, delete the staging label, and leave the
# station with no checkpoint at all.
_cpg_have_label() {
  local first
  first="$(printf '%s' "$ST_DISKS" | head -1)"
  qemu-img snapshot -l "$first" 2>/dev/null | awk -v t="$1" '$2 == t { found = 1 } END { exit !found }'
}

# Expand a leading `$D/` or `${D}/` against the launcher's OWN literal assignment
# of that name.
#
# THE DEFECT THIS FIXES. A stopped station's disks can only come from the launcher
# text, and essentially every station launcher writes
#
#     D=/data/vms/streamhost/stations/rhapsody
#     ...
#     -drive file=$D/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0
#
# Unexpanded, the scrape below yielded the literal string `$D/rhapsody-golden.qcow2`,
# which of course does not exist, so cpg_resolve refused — and it refused for
# `rollback`, `status` and `prune`, the three subcommands that exist for a station
# whose guest is DOWN. `rollback` in particular failed in exactly the situation you
# reach for it in.
#
# LITERAL ABSOLUTE ASSIGNMENTS ONLY. A value built by `$(...)` or a backtick is not
# statically knowable, and a name assigned two different literals is ambiguous;
# in both cases the token is left untouched and the existence check below refuses
# loudly, naming the variable. The guard does not guess which disk holds a
# checkpoint. Requiring the `/` after the name is what keeps `$D/` from matching
# inside `$DISK/`.
_cpg_expand_leading_var() {
  local p="$1" n v
  case "$p" in
    '$'*/*) : ;;
    *)
      printf '%s\n' "$p"
      return 0
      ;;
  esac
  n="${p%%/*}"
  n="${n#\$}"
  n="${n#\{}"
  n="${n%\}}"
  case "$n" in
    '' | *[!A-Za-z0-9_]*)
      printf '%s\n' "$p"
      return 0
      ;;
  esac
  v="$(_cpg_launcher_code |
    sed -n "s|^[[:space:]]*$n=[\"']\{0,1\}\(/[^\"'[:space:]]*\)[\"']\{0,1\}[[:space:]]*\$|\1|p" |
    sort -u)"
  if [ "$(printf '%s' "$v" | grep -c .)" -ne 1 ]; then
    printf '%s\n' "$p"
    return 0
  fi
  printf '%s/%s\n' "${v%/}" "${p#*/}"
}

# ---- the checkpoint-bearing disks ----------------------------------------------
# savevm writes the vmstate into the first qcow2 and a snapshot record into every
# other one, so ALL of them must be backed up for the backup to be a rollback
# target rather than a souvenir.
#
# Ask the RUNNING QEMU first (query-block resolves what the process actually
# opened, whatever shell variables built the path). The launcher scrape is the
# fallback for a STOPPED station, where status/prune/rollback still must work.
cpg_resolve_disks() {
  ST_DISKS=""
  if [ -S "$ST_QMP" ]; then
    ST_DISKS="$(_cpg_qmp blocks qcow2 2>/dev/null | grep -E '^/' | sort -u)"
  fi
  local d
  if [ -z "$ST_DISKS" ]; then
    ST_DISKS="$(_cpg_launcher_code |
      grep -Eho '(-drive[[:space:]]+file=|-hda[[:space:]]+)[^ ,]+' |
      sed -E 's/^(-drive[[:space:]]+file=|-hda[[:space:]]+)//' | grep -E '\.qcow2$' | sort -u)"
    ST_DISKS="$(while read -r d; do
      [ -n "$d" ] && _cpg_expand_leading_var "$d"
    done <<<"$ST_DISKS" | sort -u)"
  fi
  if [ -z "$ST_DISKS" ]; then
    _cpg_err "could not determine which qcow2 holds '$STATION' checkpoint — query-block returned nothing and $ST_LAUNCHER names no qcow2. REFUSING: without the disk there is nothing to back up."
    return 5
  fi
  while read -r d; do
    [ -n "$d" ] || continue
    if [ ! -f "$d" ]; then
      case "$d" in
        *'$'*)
          _cpg_err "the launcher builds disk path '$d' from a shell variable this guard could not resolve statically — it expands only a leading \$VAR/ that $ST_LAUNCHER assigns ONCE, to a literal absolute path. Start the station so query-block can answer instead, or make that assignment a plain literal. REFUSING rather than guessing which disk holds the checkpoint."
          ;;
        *)
          _cpg_err "launcher references disk '$d', which does not exist"
          ;;
      esac
      return 5
    fi
  done <<<"$ST_DISKS"
  return 0
}

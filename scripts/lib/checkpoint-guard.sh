#!/bin/bash
# checkpoint-guard.sh — HARD safety guard for RECAPTURING a live station's checkpoint.
# Full story, per-step kill analysis and proof: docs/lab/checkpoint-guard.md
#
# WHY THIS EXISTS. 2026-08-24, win95: an agent recapturing the checkpoint typed the
# folklore by hand — `delvm golden` then `savevm golden` — and was killed INSIDE that
# window. The result was a LIVE, listed station with no checkpoint at all; `labctl
# reset` had nothing to restore. Recoverable only because a byte-copy backup happened
# to exist. AGENTS.md's "Never retire a golden before its replacement is proven" is the
# rule; this is its tool, in the clone-guard / chroot-guard idiom: an operation that has
# already caused damage gets wrapped once, centrally, fail-closed.
#
# WHAT IT GUARANTEES (non-zero exit + loud message on any doubt)
#   * Byte-copy backup of every checkpoint-bearing qcow2 FIRST, SHA256-verified with
#     the guest STOPPED (a running guest writes its active layer; a live hash proves
#     nothing). Mismatch aborts before anything is captured.
#   * The new checkpoint is captured under a DIFFERENT label and restore-proven ON THE
#     FRAMEBUFFER, and the restored guest asserted RUNNING (one captured while stopped
#     restores paused: the screenshot looks perfect and the station is dead), before
#     anything of the old one is touched. A failed run DELETES NOTHING, and says so.
#   * Write-ahead journal at <stationdir>/.checkpoint-guard.json, so a process killed
#     anywhere leaves a state `resume` can finish or `rollback` can undo.
#   * Holds the wake lease so idle-pause cannot re-freeze the guest mid-capture.
#   RESIDUAL WINDOW, honestly: QEMU has no snapshot rename, so promoting to the label
#   `golden` is necessarily delvm-then-savevm. The guard cannot remove that window; it
#   removes it being FATAL — throughout it the restore-PROVEN staging snapshot is still
#   in the qcow2, the verified byte copy is still on disk, and the journal names the
#   state so `resume` finishes in one step.
#
# DUAL USE: source it -> cpg_* functions; or run it:
#   checkpoint-guard recapture|resume|rollback|status|prune <station>
# RUNTIMES: QEMU vmstate/loadvm stations only. es40 (.axp) and MAME (.sta) are REFUSED
#   loudly rather than half-covered.
#
# SOURCE OF TRUTH: this file, kept byte-identical to /usr/local/bin/checkpoint-guard
#   (box-sync pair). Runs on labhost as root: station QMP sockets are root-only there.
# VOCABULARY (docs/GLOSSARY.md): a CHECKPOINT is the captured machine state; `golden` is
#   the opaque stored LABEL; RECAPTURE is the act.
set -uo pipefail

CPG_STATIONS_ROOT="${CPG_STATIONS_ROOT:-/data/vms/streamhost/stations}"
CPG_LABEL="${CPG_LABEL:-golden}"
# NOT "golden-new", and this is load-bearing. Launchers probe `qemu-img snapshot -l
# DISK | grep -qw golden`, and `grep -qw golden` MATCHES "golden-new" ("-" is not a
# word constituent). With `golden` gone but a golden-new label present, that probe says
# "yes", the launcher adds `-loadvm golden`, and QEMU REFUSES TO START — the interrupted
# state takes the station down instead of merely cold-booting it.
CPG_STAGING_LABEL="${CPG_STAGING_LABEL:-cpg-staging}"
CPG_DIRTY_TEXT="${CPG_DIRTY_TEXT:-checkpoint-guard-dirty}"
# Command that moves THIS guest's framebuffer when typing cannot reach it; run
# only after the keystrokes fail. docs/lab/checkpoint-guard.md, "When typing
# cannot dirty the guest".
CPG_DIRTY_CMD="${CPG_DIRTY_CMD:-}"
CPG_SETTLE="${CPG_SETTLE:-2}"
CPG_IDLE_SECONDS="${CPG_IDLE_SECONDS:-3}"
CPG_SSIM_MIN="${CPG_SSIM_MIN:-0.999}"
CPG_WAKE_LEASE_DIR="${SH_WAKE_LEASE_DIR:-/run/streamhost/wake}"

_cpg_err() { printf 'checkpoint-guard: REFUSED: %s\n' "$*" >&2; }
_cpg_log() { printf '[checkpoint-guard:%s] %s\n' "${STATION:-?}" "$*" >&2; }

# ---- labqmp resolution ---------------------------------------------------------
# Sibling copy first (repo checkout), then the installed copy, so the guard behaves
# identically run from either place.
_cpg_labqmp() {
  local here candidate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "$here/labqmp.py" /usr/local/lib/labqmp.py \
    /data/kernel-hive/scripts/lib/labqmp.py; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  _cpg_err "labqmp.py not found (looked beside the guard, /usr/local/lib, /data/kernel-hive)"
  return 2
}

_cpg_qmp() {
  local lq
  lq="$(_cpg_labqmp)" || return $?
  python3 "$lq" "$ST_QMP" "$@"
}

# The launcher with comments stripped: a prose line saying "runs WITHOUT -snapshot"
# must not be read as a -snapshot flag.
_cpg_launcher_code() {
  sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "$ST_LAUNCHER"
}

# Exact snapshot-TAG match, never `grep -qw` (wrong for the reason above). Getting this
# wrong here is catastrophic: resume would believe `golden` was already promoted, delete
# the staging label, and leave the station with no checkpoint at all.
_cpg_have_label() {
  local first
  first="$(printf '%s' "$ST_DISKS" | head -1)"
  qemu-img snapshot -l "$first" 2>/dev/null | awk -v t="$1" '$2 == t { found = 1 } END { exit !found }'
}
_cpg_status() { _cpg_qmp status 2>/dev/null | tr -d '"' | tail -1; }

# The framebuffer proof (rule 9) lives in a sibling; same discovery as labqmp.py,
# so the guard behaves identically run from the repo or from /usr/local/bin.
_cpg_source_proof() {
  local here candidate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "$here/checkpoint-guard-proof.sh" \
    /usr/local/lib/checkpoint-guard-proof.sh \
    /data/kernel-hive/scripts/lib/checkpoint-guard-proof.sh; do
    if [ -f "$candidate" ]; then
      # shellcheck source=/dev/null
      . "$candidate"
      return 0
    fi
  done
  _cpg_err "checkpoint-guard-proof.sh not found — REFUSING: without it there is no framebuffer proof, and a guard that cannot prove a restore must not delete a checkpoint."
  exit 2
}
_cpg_source_proof

# ---- wake lease ----------------------------------------------------------------
# streamhost re-asserts a believed idle pause every 60 s; without the lease that lands
# mid-savevm and the guest we prove is not the guest we captured. The file expires on
# its own, so a killed guard never leaves a station pinned awake.
_cpg_lease_hold() {
  [ -d "$CPG_WAKE_LEASE_DIR" ] || return 0
  CPG_LEASE="$CPG_WAKE_LEASE_DIR/$STATION.lease"
  touch "$CPG_LEASE" 2>/dev/null || return 0
  # The refresher must not outlive the guard, or a `kill -9` orphans a loop that pins
  # the station awake forever. It watches the owning shell and exits with it.
  local owner=$$
  while kill -0 "$owner" 2>/dev/null && touch "$CPG_LEASE" 2>/dev/null; do sleep 20; done &
  CPG_LEASE_PID=$!
  _cpg_log "holding streamhost wake lease $CPG_LEASE (pid $CPG_LEASE_PID)"
}
_cpg_lease_release() {
  [ -n "${CPG_LEASE_PID:-}" ] || return 0
  kill "$CPG_LEASE_PID" 2>/dev/null
  wait "$CPG_LEASE_PID" 2>/dev/null
  CPG_LEASE_PID=""
}

# ---- resolution: station dir, runtime kind, checkpoint-bearing disks ------------
# Refuses LOUDLY for every runtime it cannot cover safely. Half-covering a runtime
# is how the folklore comes back.
cpg_resolve() {
  STATION="${1:-}"
  case "$STATION" in
    '' | */* | .*)
      _cpg_err "invalid station name '${STATION}'"
      return 2
      ;;
  esac
  ST_DIR="$CPG_STATIONS_ROOT/$STATION"
  ST_LAUNCHER="$ST_DIR/qemu-streamhost.sh"
  ST_QMP="$ST_DIR/qmp.sock"
  ST_PID="$ST_DIR/qemu.pid"
  ST_JOURNAL="$ST_DIR/.checkpoint-guard.json"
  if [ ! -d "$ST_DIR" ]; then
    _cpg_err "no station dir $ST_DIR"
    return 2
  fi

  local mode=""
  [ -f "$ST_DIR/station.env" ] &&
    mode="$(sed -n 's/^[[:space:]]*SH_RESET_MODE=["'"'"']\{0,1\}\([a-z-]*\).*/\1/p' "$ST_DIR/station.env" | head -1)"
  case "${mode:-loadvm}" in
    loadvm) : ;;
    restart)
      _cpg_err "station '$STATION' has SH_RESET_MODE=restart: its boot artifact IS the reset source and it holds no checkpoint to recapture. Nothing to guard."
      return 5
      ;;
    pve-rollback)
      _cpg_err "station '$STATION' has SH_RESET_MODE=pve-rollback: its checkpoint is a PVE snapshot taken with 'qm snapshot --vmstate 1', not a qcow2 label. This guard does not cover it. REFUSING rather than half-covering it."
      return 5
      ;;
    relaunch | criu)
      _cpg_err "station '$STATION' has SH_RESET_MODE=$mode, which is not a QMP-captured checkpoint. REFUSING — see docs/lab/checkpoint-guard.md 'Runtimes refused'."
      return 5
      ;;
  esac

  if printf '%s' "$CPG_STAGING_LABEL" | grep -qw "$CPG_LABEL"; then
    _cpg_err "staging label '$CPG_STAGING_LABEL' is matched by 'grep -qw $CPG_LABEL', which is how every station launcher probes for its checkpoint. A launcher would then add '-loadvm $CPG_LABEL' with no such snapshot and QEMU would refuse to start. Choose a staging label that does not contain '$CPG_LABEL' as a word."
    return 5
  fi

  # Runtime detection is by what the station's own launcher actually runs.
  local runner=""
  if [ -f "$ST_LAUNCHER" ]; then
    runner="$(_cpg_launcher_code |
      grep -Eho '(qemu-system-[a-z0-9_]+|\bes40\b|\bmame[a-z0-9_]*\b|mamectl)' | head -1)"
  fi
  case "$runner" in
    qemu-system-*) ST_KIND="qemu-vmstate" ;;
    es40)
      _cpg_err "station '$STATION' runs the es40 AlphaServer emulator. Its checkpoint is an .axp savestate written by the emulator's own SAVEST verb and paired with a disk image frozen in the same SIGSTOP window — not a QMP snapshot. REFUSING rather than half-covering it; see docs/lab/checkpoint-guard.md 'Runtimes refused'."
      return 5
      ;;
    mame*)
      _cpg_err "station '$STATION' runs MAME. Its checkpoint is a .sta savestate paired with a CHD copied inside a PAUSE window, plus a provenance md5 binding both to the emulator binary — not a QMP snapshot. REFUSING rather than half-covering it; see docs/lab/checkpoint-guard.md 'Runtimes refused'."
      return 5
      ;;
    *)
      _cpg_err "cannot tell what runtime station '$STATION' uses (no qemu-system-*/es40/mame in $ST_LAUNCHER). REFUSING: a guard that guesses the runtime is worse than no guard."
      return 5
      ;;
  esac

  if _cpg_launcher_code | grep -qE '(^|[[:space:]])-snapshot([[:space:]]|$)'; then
    _cpg_err "launcher runs QEMU with -snapshot: guest writes never reach the qcow2, so a captured checkpoint could not survive the process. REFUSING."
    return 5
  fi

  # savevm writes the vmstate into the first qcow2 and a snapshot record into every
  # other one, so ALL of them must be backed up for the backup to be a rollback
  # target rather than a souvenir.
  #
  # Ask the RUNNING QEMU, not the launcher: most stations build the disk path from a
  # shell variable, which no static parse can resolve. The launcher scrape is only the
  # fallback for a stopped station, where status/prune/rollback still must work.
  ST_DISKS=""
  if [ -S "$ST_QMP" ]; then
    ST_DISKS="$(_cpg_qmp blocks qcow2 2>/dev/null | grep -E '^/' | sort -u)"
  fi
  if [ -z "$ST_DISKS" ]; then
    ST_DISKS="$(_cpg_launcher_code |
      grep -Eho '(-drive[[:space:]]+file=|-hda[[:space:]]+)[^ ,]+' |
      sed -E 's/^(-drive[[:space:]]+file=|-hda[[:space:]]+)//' | grep -E '\.qcow2$' | sort -u)"
  fi
  if [ -z "$ST_DISKS" ]; then
    _cpg_err "could not determine which qcow2 holds '$STATION' checkpoint — query-block returned nothing and $ST_LAUNCHER names no literal qcow2. REFUSING: without the disk there is nothing to back up."
    return 5
  fi
  local d
  while read -r d; do
    [ -n "$d" ] || continue
    if [ ! -f "$d" ]; then
      _cpg_err "launcher references disk '$d', which does not exist"
      return 5
    fi
  done <<<"$ST_DISKS"
  return 0
}

# ---- journal (write-ahead, atomic) ---------------------------------------------
# Written BEFORE the step it names, so the recorded state is always at-or-ahead of
# what happened on disk, never behind it. That is what makes `resume` safe.
cpg_journal_write() {
  local state="$1" tmp first=1 line
  tmp="$ST_JOURNAL.tmp.$$"
  {
    printf '{\n  "state": "%s",\n  "station": "%s",\n' "$state" "$STATION"
    printf '  "label": "%s",\n  "staging_label": "%s",\n' "$CPG_LABEL" "$CPG_STAGING_LABEL"
    printf '  "session": "%s",\n  "ts": "%s",\n' \
      "${KH_SESSION:-unknown}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "backups": ['
    while read -r line; do
      [ -n "$line" ] || continue
      [ "$first" -eq 1 ] || printf ','
      printf '\n    {"disk": "%s", "backup": "%s", "sha256": "%s"}' \
        "${line%%|*}" "$(printf '%s' "$line" | cut -d'|' -f2)" "${line##*|}"
      first=0
    done <<<"${CPG_BACKUPS:-}"
    [ "$first" -eq 1 ] || printf '\n  '
    printf ']\n}\n'
  } >"$tmp" && mv -f "$tmp" "$ST_JOURNAL"
  _cpg_log "journal: $state"
}

cpg_journal_state() {
  if [ ! -f "$ST_JOURNAL" ]; then
    printf 'none'
    return 0
  fi
  sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ST_JOURNAL" | head -1
}

_cpg_journal_backup_rows() {
  sed -n 's/.*"disk": "\([^"]*\)", "backup": "\([^"]*\)", "sha256": "\([^"]*\)".*/\1|\2|\3/p' \
    "$ST_JOURNAL"
}

# Load the journal's recorded backup rows back into CPG_BACKUPS.
#
# cpg_journal_write RE-RENDERS the whole journal from CPG_BACKUPS every time it
# is called, so any path that writes the journal without having run cpg_backup
# in the SAME process silently replaces a populated "backups" array with []. That
# is not a missing carry-over, it is an ERASURE of the only record of where the
# rollback copy is -- and the loss is invisible until an incident, because the
# backup FILE is still sitting on disk next to the disk it came from.
#
# Measured on aix432, 2026-08-31: a `recapture` wrote the row correctly, the run
# refused at the dirty step, and the `resume` that finished it wrote the journal
# four more times (promoting, promoted, cleanup, done) and left "backups": [].
cpg_journal_load_backups() {
  CPG_BACKUPS=""
  [ -f "$ST_JOURNAL" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    CPG_BACKUPS="${CPG_BACKUPS}${line}"$'\n'
  done < <(_cpg_journal_backup_rows)
}

# ---- step 1: byte-copy backup, SHA256-verified with the guest STOPPED -----------
cpg_backup() {
  local ts d bak h1 h2
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  _cpg_log "stopping vCPUs (a running guest writes its active layer, so a live hash proves nothing)"
  if ! _cpg_qmp stop >/dev/null; then
    _cpg_err "QMP stop failed — cannot take a hashable backup. Nothing has been touched."
    return 6
  fi
  CPG_BACKUPS=""
  while read -r d; do
    [ -n "$d" ] || continue
    bak="$d.cpg-bak-$ts"
    _cpg_log "byte-copy backup: $d -> $bak"
    if ! cp --reflink=auto -f "$d" "$bak"; then
      _cpg_err "backup copy failed for $d. Nothing has been captured or deleted."
      return 6
    fi
    h1="$(sha256sum "$d" | cut -d' ' -f1)"
    h2="$(sha256sum "$bak" | cut -d' ' -f1)"
    if [ "$h1" != "$h2" ]; then
      _cpg_err "SHA256 MISMATCH: $d is $h1 but its backup $bak is $h2. The backup is not a byte copy, so the old checkpoint would have no rollback target. REFUSING to go further — nothing has been captured or deleted."
      return 6
    fi
    _cpg_log "backup verified with the guest stopped: sha256=$h1"
    CPG_BACKUPS="${CPG_BACKUPS}${d}|${bak}|${h1}"$'\n'
  done <<<"$ST_DISKS"
  return 0
}

# ---- step 2+3: capture under a different label, then prove it -------------------
cpg_capture_and_prove() {
  local ref="$ST_DIR/.cpg-reference.ppm"
  _cpg_log "resuming the guest: the checkpoint must be captured RUNNING or it restores paused"
  _cpg_qmp cont >/dev/null
  sleep 1
  local st
  st="$(_cpg_status)"
  if [ "$st" != "running" ]; then
    _cpg_err "guest status is '$st' after cont; refusing to capture a checkpoint that would restore paused. Nothing has been captured or deleted."
    return 7
  fi

  if _cpg_have_label "$CPG_STAGING_LABEL"; then
    _cpg_log "removing a stale staging label '$CPG_STAGING_LABEL' (it is not the live checkpoint)"
    _cpg_qmp delvm "$CPG_STAGING_LABEL" >/dev/null 2>&1
  fi
  _cpg_log "capturing the NEW checkpoint under staging label '$CPG_STAGING_LABEL' — '$CPG_LABEL' is untouched"
  if ! _cpg_qmp savevm "$CPG_STAGING_LABEL" >/dev/null; then
    _cpg_err "savevm $CPG_STAGING_LABEL failed. '$CPG_LABEL' is untouched and still authoritative."
    return 7
  fi
  if ! _cpg_have_label "$CPG_STAGING_LABEL"; then
    _cpg_err "savevm reported success but '$CPG_STAGING_LABEL' is absent from the snapshot list. '$CPG_LABEL' is untouched."
    return 7
  fi
  cpg_reference "$ref" || return $?
  cpg_prove_label "$CPG_STAGING_LABEL" "$ref" \
    "$ST_DIR/.cpg-dirty.ppm" "$ST_DIR/.cpg-restored.ppm"
}

# ---- step 4: promote — the ONLY step that touches the old checkpoint ------------
cpg_promote() {
  _cpg_log "promoting: '$CPG_STAGING_LABEL' is proven, so '$CPG_LABEL' may now be retired"
  _cpg_qmp delvm "$CPG_LABEL" >/dev/null 2>&1
  if ! _cpg_qmp savevm "$CPG_LABEL" >/dev/null; then
    _cpg_err "savevm $CPG_LABEL failed INSIDE the promote window. The PROVEN '$CPG_STAGING_LABEL' snapshot is still in the disk and the verified backup is still there: run 'checkpoint-guard resume $STATION'."
    return 8
  fi
  if ! _cpg_have_label "$CPG_LABEL"; then
    _cpg_err "savevm $CPG_LABEL reported success but the label is absent. Run 'checkpoint-guard resume $STATION'."
    return 8
  fi
  cpg_prove_label "$CPG_LABEL" "$ST_DIR/.cpg-reference.ppm" \
    "$ST_DIR/.cpg-dirty2.ppm" "$ST_DIR/.cpg-restored2.ppm" || {
    _cpg_err "the promoted '$CPG_LABEL' did not re-prove. '$CPG_STAGING_LABEL' is still present as the proven fallback and the backup is still on disk."
    return 8
  }
  return 0
}

cpg_finish() {
  cpg_journal_write "cleanup"
  _cpg_qmp delvm "$CPG_STAGING_LABEL" >/dev/null 2>&1
  cpg_journal_write "done"
  rm -f "$ST_DIR"/.cpg-*.ppm "$ST_DIR"/.cpg-*.ppm.b
  _cpg_log "DONE — '$CPG_LABEL' is the new checkpoint, restore-proven on the framebuffer, guest running."
  _cpg_log "backup KEPT (remove it only once you are happy): checkpoint-guard prune $STATION"
  sed -n 's/.*"backup": "\([^"]*\)".*/  backup: \1/p' "$ST_JOURNAL" >&2
}

# ---- subcommands ---------------------------------------------------------------
cpg_recapture() {
  cpg_resolve "${1:-}" || return $?
  local prior
  prior="$(cpg_journal_state)"
  case "$prior" in
    none | done) : ;;
    *)
      _cpg_err "station '$STATION' has an UNFINISHED checkpoint-guard run in state '$prior' ($ST_JOURNAL). Refusing to start a second one on top of it: run 'checkpoint-guard resume $STATION' to finish it, or 'checkpoint-guard rollback $STATION' to undo it."
      return 3
      ;;
  esac
  if [ ! -S "$ST_QMP" ]; then
    _cpg_err "no QMP socket at $ST_QMP — the station must be running for its live state to be captured"
    return 3
  fi
  _cpg_have_label "$CPG_LABEL" ||
    _cpg_log "NOTE: no existing '$CPG_LABEL' label — this is a FIRST capture, nothing to retire"

  trap '_cpg_lease_release' EXIT
  _cpg_lease_hold
  CPG_BACKUPS=""
  cpg_journal_write "backup"
  cpg_backup || return $?
  cpg_journal_write "captured"
  cpg_capture_and_prove || return $?
  cpg_journal_write "promoting"
  cpg_promote || return $?
  cpg_journal_write "promoted"
  cpg_finish
}

cpg_resume() {
  cpg_resolve "${1:-}" || return $?
  local state
  state="$(cpg_journal_state)"
  _cpg_log "journal state: $state"
  case "$state" in
    none | done)
      _cpg_log "nothing to resume"
      return 0
      ;;
    backup)
      _cpg_err "the run died during the BACKUP, before anything was captured or deleted. '$CPG_LABEL' is untouched and authoritative. Clear the journal with 'checkpoint-guard prune $STATION' and start again."
      return 4
      ;;
    captured | promoting | promoted | cleanup) ;;
    *)
      _cpg_err "unknown journal state '$state'"
      return 4
      ;;
  esac
  if ! _cpg_have_label "$CPG_STAGING_LABEL" && ! _cpg_have_label "$CPG_LABEL"; then
    _cpg_err "neither '$CPG_LABEL' nor '$CPG_STAGING_LABEL' is present: resume cannot rebuild a checkpoint from nothing. Use 'checkpoint-guard rollback $STATION'."
    return 4
  fi
  trap '_cpg_lease_release' EXIT
  _cpg_lease_hold
  # Inherit the backup rows the recapture recorded: every cpg_journal_write below
  # re-renders the journal from CPG_BACKUPS, and this process has not run
  # cpg_backup. Without this a resumed run finishes with "backups": [] and the
  # rollback it advertises does not exist.
  cpg_journal_load_backups
  if _cpg_have_label "$CPG_LABEL" && ! _cpg_have_label "$CPG_STAGING_LABEL"; then
    _cpg_log "'$CPG_LABEL' is present and the staging label is gone: the promote had completed"
    cpg_finish
    return 0
  fi
  _cpg_log "finishing the promote from the PROVEN '$CPG_STAGING_LABEL'"
  if ! _cpg_qmp loadvm "$CPG_STAGING_LABEL" >/dev/null; then
    _cpg_err "loadvm $CPG_STAGING_LABEL failed; use 'checkpoint-guard rollback $STATION'"
    return 4
  fi
  sleep "$CPG_SETTLE"
  _cpg_qmp cont >/dev/null 2>&1
  cpg_reference "$ST_DIR/.cpg-reference.ppm" || return $?
  cpg_journal_write "promoting"
  cpg_promote || return $?
  cpg_journal_write "promoted"
  cpg_finish
}

cpg_rollback() {
  cpg_resolve "${1:-}" || return $?
  if [ ! -f "$ST_JOURNAL" ]; then
    _cpg_err "no journal at $ST_JOURNAL — nothing to roll back"
    return 4
  fi
  local disk bak sha now rows=0 restored=0
  rows="$(_cpg_journal_backup_rows | grep -c . || true)"
  # ZERO ROWS IS A REFUSAL, NOT AN EMPTY SUCCESS.
  #
  # Every loop below is `while read` over those rows, so with none of them this
  # function used to verify nothing and then say "Every recorded backup verified,
  # so the rollback is available" -- and under CPG_ROLLBACK_CONFIRM=1 it restored
  # nothing, deleted the journal, and logged "ROLLED BACK to the pre-recapture
  # disks." A false success on the incident path is worse than no rollback: it
  # ends the investigation. Fail loudly instead (AGENTS.md rule 7).
  if [ "$rows" -eq 0 ]; then
    _cpg_err "the journal at $ST_JOURNAL records NO backups (\"backups\": []), so there is nothing to roll back TO and this cannot restore anything. It is REFUSING rather than reporting a rollback it did not perform. The backup FILES may still be on disk -- look for ${ST_DIR}/*.cpg-bak-* and 'checkpoint-guard status $STATION' -- and if one is the copy you want, re-record it in the journal's \"backups\" array (disk, backup, sha256 of the backup file) before running this again, or restore it by hand with the station STOPPED. A journal can reach this state through a resumed run recorded by a guard older than 2026-08-31; see docs/lab/checkpoint-guard.md."
    return 4
  fi
  while IFS='|' read -r disk bak sha; do
    [ -n "$disk" ] || continue
    if [ ! -f "$bak" ]; then
      _cpg_err "recorded backup '$bak' is gone; cannot roll $disk back"
      return 4
    fi
    now="$(sha256sum "$bak" | cut -d' ' -f1)"
    if [ "$now" != "$sha" ]; then
      _cpg_err "backup '$bak' no longer hashes to its recorded sha256 ($now != $sha). REFUSING to restore a backup that changed under us."
      return 4
    fi
    _cpg_log "backup still verifies: $bak"
  done < <(_cpg_journal_backup_rows)

  if [ "${CPG_ROLLBACK_CONFIRM:-0}" != "1" ]; then
    _cpg_err "rollback replaces LIVE disks and needs the guest DOWN. Stop the station (systemctl stop streamhost@$STATION), then re-run with CPG_ROLLBACK_CONFIRM=1. All $rows recorded backup(s) verified against their sha256, so the rollback is available."
    return 4
  fi
  if [ -f "$ST_PID" ] && kill -0 "$(cat "$ST_PID")" 2>/dev/null; then
    _cpg_err "the station's QEMU (pid $(cat "$ST_PID")) is still alive. REFUSING to swap a disk under a running guest."
    return 4
  fi
  while IFS='|' read -r disk bak sha; do
    [ -n "$disk" ] || continue
    _cpg_log "restoring $bak -> $disk"
    cp --reflink=auto -f "$bak" "$disk" || return 4
    now="$(sha256sum "$disk" | cut -d' ' -f1)"
    if [ "$now" != "$sha" ]; then
      _cpg_err "restored $disk does not hash to $sha"
      return 4
    fi
    _cpg_log "restored and verified: $disk"
    restored=$((restored + 1))
  done < <(_cpg_journal_backup_rows)
  # Belt and braces behind the zero-row refusal: never delete the journal, and
  # never claim a rollback, on the strength of a loop that copied nothing.
  if [ "$restored" -eq 0 ]; then
    _cpg_err "restored 0 disks despite $rows recorded backup(s) — REFUSING to delete the journal or report a rollback. Nothing has been changed."
    return 4
  fi
  rm -f "$ST_JOURNAL"
  _cpg_log "ROLLED BACK $restored disk(s) to the pre-recapture copies. Start the station and confirm on the framebuffer."
}

cpg_status() {
  cpg_resolve "${1:-}" || return $?
  printf 'station    %s (%s)\n' "$STATION" "$ST_KIND"
  printf 'journal    %s\n' "$(cpg_journal_state)"
  local d b
  while read -r d; do
    [ -n "$d" ] || continue
    printf -- '--- %s\n' "$d"
    qemu-img snapshot -l "$d" 2>&1 | sed 's/^/    /'
    for b in "$d".cpg-bak-*; do
      [ -f "$b" ] && printf '    backup: %s\n' "$b"
    done
  done <<<"$ST_DISKS"
  return 0
}

cpg_prune() {
  cpg_resolve "${1:-}" || return $?
  local d b
  while read -r d; do
    [ -n "$d" ] || continue
    for b in "$d".cpg-bak-*; do
      [ -f "$b" ] || continue
      _cpg_log "removing backup $b"
      rm -f "$b"
    done
  done <<<"$ST_DISKS"
  rm -f "$ST_JOURNAL" "$ST_DIR"/.cpg-*.ppm "$ST_DIR"/.cpg-*.ppm.b
  _cpg_log "pruned"
}

_cpg_cli() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    recapture) cpg_recapture "$@" ;;
    resume) cpg_resume "$@" ;;
    rollback) cpg_rollback "$@" ;;
    status) cpg_status "$@" ;;
    prune) cpg_prune "$@" ;;
    '' | -h | --help | help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      return 0
      ;;
    *)
      _cpg_err "unknown subcommand '$cmd' (see: checkpoint-guard --help)"
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cpg_cli "$@"
  exit $?
fi

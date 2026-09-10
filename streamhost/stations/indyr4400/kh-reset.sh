#!/usr/bin/env bash
# kh-reset.sh — the reset/checkpoint half of the host-native `indyr4400`
# launcher. SOURCE this from `x11-runtime.sh`; it is not executable on its own.
#
# Stream D owns this file; stream B owns the launcher that sources it. After
# the 2026-09-10 integration the seam is TWO functions:
#
#   kh_reset_preflight  decide restore-vs-cold-boot; enforce the bounded
#                       fallback. Sets KH_STATE, which the launcher passes to
#                       the container as IRIS_STATE.
#   kh_reset_confirm    background watcher that clears the failure ledger once
#                       the emulator answers a verb (call after launching)
#
# Two functions are gone and it is worth saying why, because their absence
# looks like an omission:
#   kh_reset_env    the emulator knobs are NOT exported into the launcher's
#                   environment any more. The payload runs inside a container
#                   and only sees what `systemd-nspawn --setenv` hands it, so
#                   the launcher states them there — one list, one place.
#   kh_reset_sweep  x11-runtime.sh's `reap_previous` already refuses to start
#                   over a survivor, scoped to the station's own asset dir and
#                   sweeping the nspawn supervisor too. Two sweeps racing each
#                   other's SIGKILL is worse than one.
#
# ---------------------------------------------------------------------------
# WHY A LEDGER
#
# Iris has no `--restore` flag, so the fork restores at startup from
# `IRIS_STATE` (src/kh_ctl.rs `startup_restore`). A checkpoint that has gone
# bad — a half-written snapshot, a binary bumped without a recapture — would
# otherwise wedge the station in a restore loop that looks like a boot loop.
#
# So: every launch that intends to restore writes a mark; the mark is cleared
# only once the running emulator has ACKED a verb on its control socket. Two
# consecutive launches that never got that far make the third cold-boot on
# purpose, saying so in the log. A cold boot here is ~7 minutes (PROM, IRIX
# autoconfig relink, graphical login) — expensive enough that it must never
# happen silently, and cheap enough that it is the right floor.
#
# The emulator refuses a checkpoint whose binary does not match it (rule 6:
# checkpoint + binary + device set are ONE combination), so the common case
# this ledger catches is "someone rebuilt iris and did not recapture" — which
# the log line names explicitly, because the fix is a recapture, not a retry.
# ---------------------------------------------------------------------------

# Defaults; the launcher may set any of these before sourcing.
: "${SH_STATION:=indyr4400}"
: "${KH_STATION_DIR:=/data/vms/streamhost/stations/${SH_STATION}}"
: "${KH_ASSET_DIR:=/data/vms/streamhost/assets/${SH_STATION}}"
: "${IRIS_BIN:=${KH_ASSET_DIR}/iris}"
: "${KH_CHECKPOINT:=golden}"
: "${KH_RESTORE_FAIL_LIMIT:=2}"

KH_LEDGER="${KH_STATION_DIR}/kh-restore-attempts"
# The station has ONE control socket and it lives in run/, not in the station
# dir: the station dir holds the cert hash and signaling.json and is never bound
# into the container, while run/ is (docs/lab/IRIS-DEBRIDGE-LEDGER.md).
KH_CTL_SOCK="${KH_CTL_SOCK:-${KH_STATION_DIR}/run/ctl.sock}"
# Iris resolves `saves/<name>` relative to its PROCESS CWD, which is /work — and
# work/ is wiped on every launch. So the snapshots live in a PERSISTENT dir that
# /work/saves symlinks to, and this is the host-side view of it. Reading the
# checkpoint from anywhere else is how a launcher decides to restore a golden
# the last relaunch already deleted.
KH_SAVES_DIR="${KH_SAVES_DIR:-${KH_STATION_DIR}/state}"

kh_log() { echo "kh-reset[${SH_STATION}]: $*" >&2; }

# --- decide restore vs cold boot -------------------------------------------
kh_reset_preflight() {
  KH_STATE=""
  local snap="${KH_SAVES_DIR}/${KH_CHECKPOINT}"
  if [ ! -f "${snap}/snapshot.toml" ]; then
    kh_log "no checkpoint at ${snap} — COLD BOOT (~7 min: PROM, IRIX autoconfig, login)"
    return 0
  fi
  local fails=0
  [ -f "$KH_LEDGER" ] && fails="$(cat "$KH_LEDGER" 2>/dev/null || echo 0)"
  case "$fails" in *[!0-9]*) fails=0 ;; esac
  if [ "$fails" -ge "$KH_RESTORE_FAIL_LIMIT" ]; then
    kh_log "BOUNDED FALLBACK: ${fails} consecutive launches restored '${KH_CHECKPOINT}'"
    kh_log "  and never acked a verb. COLD BOOTING instead (~7 min). If the binary"
    kh_log "  was rebuilt, the fix is to RECAPTURE the checkpoint (SAVEST), not to"
    kh_log "  retry: golden + binary + device set are ONE combination (rule 6)."
    : >"$KH_LEDGER"
    return 0
  fi
  KH_STATE="$KH_CHECKPOINT"
  echo $((fails + 1)) >"$KH_LEDGER"
  kh_log "restoring checkpoint '${KH_CHECKPOINT}' at startup (attempt $((fails + 1)))"
  return 0
}

# --- clear the ledger once the emulator is really answering ----------------
# An ack from the control socket proves the restored MIPS is servicing its
# queue, which "a process exists" does not (docs/guests/nextstep.md §5).
kh_reset_confirm() {
  local deadline="${1:-180}"
  (
    local i
    for i in $(seq 1 "$deadline"); do
      if [ -S "$KH_CTL_SOCK" ] &&
        python3 /root/mctl.py "$KH_CTL_SOCK" --timeout 20 CKPT "$KH_CHECKPOINT" >/dev/null 2>&1; then
        : >"$KH_LEDGER"
        kh_log "checkpoint plane acked after ${i}s — failure ledger cleared"
        exit 0
      fi
      sleep 1
    done
    kh_log "checkpoint plane never acked within ${deadline}s — the ledger keeps"
    kh_log "  this launch's mark, so a third failure will cold-boot on purpose."
  ) &
}

#!/usr/bin/env bash
# kh-reset.sh — the reset/checkpoint half of the host-native `indyr4400`
# launcher. SOURCE this from `x11-runtime.sh`; it is not executable on its own.
#
# Stream D owns this file; stream B owns the launcher that sources it. The
# seam is four functions and nothing else:
#
#   kh_reset_env        export the emulator knobs (call before exec'ing iris)
#   kh_reset_preflight  decide restore-vs-cold-boot; enforce the bounded
#                       fallback; must run BEFORE kh_reset_env
#   kh_reset_confirm    background watcher that clears the failure ledger once
#                       the emulator answers a verb (call after launching)
#   kh_reset_sweep      refuse to start while a previous emulator survives
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
KH_CTL_SOCK="${KH_STATION_DIR}/ctl.sock"
# Iris resolves `saves/<name>` relative to its PROCESS CWD, so the launcher
# MUST cd here before exec'ing the binary. Stated once, used by both halves.
KH_WORKDIR="${KH_STATION_DIR}/iris"

kh_log() { echo "kh-reset[${SH_STATION}]: $*" >&2; }

# --- refuse to start over a survivor ---------------------------------------
# `systemctl restart` does not kill the previous emulator, and a SIGSTOPped
# standby never runs to handle SIGTERM: SIGCONT, then TERM, then KILL, and
# resolve processes by /proc/<pid>/exe — never a cmdline grep, which on this
# box matches the caller's own ssh (AGENTS.md rule 5).
kh_reset_sweep() {
  local pid exe survivors=0
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" || continue
    case "$exe" in
      "${KH_ASSET_DIR}"/*) ;;
      *) continue ;;
    esac
    kh_log "sweeping surviving emulator pid=${pid} exe=${exe}"
    kill -CONT "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    local i
    for i in $(seq 1 40); do
      [ -d "/proc/${pid}" ] || break
      sleep 0.25
    done
    if [ -d "/proc/${pid}" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.5
    fi
    [ -d "/proc/${pid}" ] && survivors=$((survivors + 1))
  done
  if [ "$survivors" -gt 0 ]; then
    kh_log "REFUSING TO START: ${survivors} emulator(s) survived the sweep — two"
    kh_log "  emulators into one framebuffer mapping is the failure this refuses."
    return 1
  fi
  return 0
}

# --- decide restore vs cold boot -------------------------------------------
kh_reset_preflight() {
  KH_STATE=""
  local snap="${KH_WORKDIR}/saves/${KH_CHECKPOINT}"
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

# --- the knobs the emulator reads ------------------------------------------
kh_reset_env() {
  export IRIS_STATE="${KH_STATE-}"
  export IRIS_KH_CTL_SOCK="$KH_CTL_SOCK"
  # Keep the COW overlay station-local and PERSISTENT. Without this, `--ci`
  # redirects it to /tmp/iris-ci-<pid>-scsiN.overlay: every guest write is
  # thrown away on restart and multi-GB of dirty sectors land on the host's
  # tmpfs. The 6.3 GB read-only asset is never touched either way.
  export IRIS_CI_OVERLAY_DIR="$KH_WORKDIR"
  # The monitor console is a hardcoded loopback singleton upstream; give this
  # station its own address so a second Iris process on the box cannot steal it.
  export IRIS_MONITOR_ADDR="${KH_MONITOR_ADDR:-127.0.0.1:18136}"
  # Strict provenance: refuse a checkpoint captured by a different binary.
  export KH_PROVENANCE="${KH_PROVENANCE:-strict}"
  mkdir -p "$KH_WORKDIR"
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

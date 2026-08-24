#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# streamhost-artifacts.sh — the versioned-artifact plane for streamhost@ units:
# which binary a station points at, how that pointer is moved, and how a station
# proves it came back up afterwards.
#
# Sourced, not executed. Extracted from scripts/dev/build-deploy.sh, which owns
# the POLICY (what to build, which stations, in what order) while this file owns
# the MECHANISM. The split is what keeps either half readable.
#
# Two invariants live here and are worth stating, because both are load-bearing
# and neither is obvious from the code:
#
#   * EVERY pointer move is a rename, never a rewrite. `ln -s` to a temp name
#     followed by `mv -Tf` is atomic on the same filesystem, so a station that
#     execs `.../stations/<tile>/current` mid-switch gets either the old binary
#     or the new one and never an empty path. A plain `ln -sf` unlinks first and
#     leaves exactly that window open.
#   * READINESS IS THE DAEMON'S OWN LINE, not systemd's. `systemctl is-active`
#     goes green the moment the process execs, long before it has opened its UDP
#     socket — so a wave could "succeed" against a station that never came back.
#     The gate is the station's own `LISTENING udp/ ... tile=<tile>` journal line
#     from THIS invocation's MainPID, which cannot be satisfied by a stale entry
#     from the previous run.
#
# The caller supplies: ssh_lab, ok, die, DRY_RUN, INSTALL_ROOT, READINESS_SECS.
# =============================================================================

service_uses_versioned() {
  local tile="$1"
  ssh_lab "systemctl show -p ExecStart --value 'streamhost@${tile}.service'" |
    grep -Fq "path=${INSTALL_ROOT}/stations/${tile}/current"
}

require_versioned_service() {
  local tile="$1"
  [ "$DRY_RUN" -eq 1 ] && return
  service_uses_versioned "$tile" ||
    die "streamhost@${tile} still uses the legacy ExecStart; run migrate-to-versioned.sh under supervision"
}

switch_tile() {
  local tile="$1" artifact="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN ${tile}: previous <- current; current -> ../../${artifact} (atomic rename)"
    printf '%s\n' "DRY_RUN_PREVIOUS"
    return
  fi
  ssh_lab "set -eu; d='${INSTALL_ROOT}/stations/${tile}'; a='${INSTALL_ROOT}/${artifact}'; [ -x \"\$a\" ]; [ -L \"\$d/current\" ]; old=\$(readlink -f \"\$d/current\"); [ -x \"\$old\" ]; old_name=\$(basename \"\$old\"); ptmp=\"\$d/.previous.\$\$\"; ctmp=\"\$d/.current.\$\$\"; ln -s \"../../\$old_name\" \"\$ptmp\"; mv -Tf \"\$ptmp\" \"\$d/previous\"; ln -s '../../${artifact}' \"\$ctmp\"; mv -Tf \"\$ctmp\" \"\$d/current\"; printf '%s\\n' \"\$old_name\""
}

set_tile_links() {
  local tile="$1" current="$2" previous="$3"
  [ "$DRY_RUN" -eq 0 ] || return 0
  ssh_lab "set -eu; d='${INSTALL_ROOT}/stations/${tile}'; [ -x '${INSTALL_ROOT}/${current}' ]; [ -x '${INSTALL_ROOT}/${previous}' ]; ctmp=\"\$d/.current.\$\$\"; ptmp=\"\$d/.previous.\$\$\"; ln -s '../../${current}' \"\$ctmp\"; mv -Tf \"\$ctmp\" \"\$d/current\"; ln -s '../../${previous}' \"\$ptmp\"; mv -Tf \"\$ptmp\" \"\$d/previous\""
}

readiness() { # waits READINESS_SECS; openvms' dual-VM stack needs ~40s+ (30 was too short)
  local tile="$1" out
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would require active streamhost@${tile} and its PID's 'LISTENING ... tile=${tile}' line"
    return
  fi
  if out=$(ssh_lab "set -u; t='${tile}'; for i in \$(seq 1 ${READINESS_SECS}); do active=\$(systemctl is-active \"streamhost@\$t.service\" 2>/dev/null || true); pid=\$(systemctl show -p MainPID --value \"streamhost@\$t.service\" 2>/dev/null || true); if [ \"\$active\" = active ] && [ \"\${pid:-0}\" -gt 0 ] 2>/dev/null; then line=\$(journalctl _PID=\"\$pid\" -n 120 --no-pager 2>/dev/null | grep -F 'LISTENING udp/' | grep -F \" tile=\$t \" | tail -1); if [ -n \"\$line\" ]; then printf '%s\\n' \"\$line\"; exit 0; fi; fi; sleep 1; done; exit 3"); then
    ok "streamhost@${tile} ready: $(printf '%s' "$out" | tail -1)"
  else
    return 1
  fi
}

restart_tiles() {
  local units="" t
  for t in "$@"; do units+=" streamhost@${t}.service"; done
  if [ "$DRY_RUN" -eq 1 ]; then
    ok "DRY-RUN would run: systemctl restart${units}"
    for t in "$@"; do readiness "$t"; done
    return
  fi
  ssh_lab "systemctl restart${units}" || return 1
  for t in "$@"; do readiness "$t" || return 1; done
}

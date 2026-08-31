#!/usr/bin/env bash
# locate-relay.sh — run the guest-cursor locator on LABHOST for a probe running
# in CT950.
#
# WHY. The browser probes run in CT950 (that is where Chrome and the VNC display
# are), but the cursor locator needs QMP, which lives on labhost. CT950 has NO
# ssh route to labhost — so `cursor-track.mjs`'s original
# `execFileSync('ssh', ['lab', …])` could never have worked from there. It fails
# silently into its own catch and reports `measured: none`, which reads as "the
# guest cursor did not move" — a station finding it has no right to make.
#
# /data/vms is bind-mounted into CT950, so a file drop is the honest channel:
# the probe writes a request, this loop answers it. Start it from a session that
# HAS the door (`ssh lab`), point the probe at the same dir, stop it when done.
#
#   ssh lab 'bash .../locate-relay.sh /data/vms/sandbox/<slot>/relay' &   # labhost
#   KH_LOCATE_RELAY=/data/vms/sandbox/<slot>/relay node cursor-track.mjs <id>   # CT950
#
# SAFETY. `--no-reset` is FORCED here and the station id is charset-checked.
# The locator without --no-reset RESTORES THE GOLDEN, which on a live station is
# an intervention, not an observation (rule 4). This relay must never be the
# thing that resets an exhibit out from under a visitor or another agent.
#
# OBSERVER TRAP. The locator attaches a QMP client, and one extra QMP client is
# a known cause of a station stall. This loop is strictly serial and each answer
# is a short-lived process, so at most one client exists at a time and it is
# gone before the next. Do not parallelise it.
set -uo pipefail

RELAY="${1:?usage: locate-relay.sh <relay-dir> [mgc-path]}"
MGC="${2:-/tmp/mgc.py}"
mkdir -p "$RELAY/req" "$RELAY/resp"
echo "locate-relay: watching $RELAY/req (mgc=$MGC), pid $$" >&2
echo $$ >"$RELAY/relay.pid"

cleanup() {
  rm -f "$RELAY/relay.pid"
  echo "locate-relay: stopped" >&2
}
trap cleanup EXIT INT TERM

while [ -e "$RELAY/run" ]; do
  shopt -s nullglob
  for req in "$RELAY"/req/*; do
    id="$(basename "$req")"
    station="$(tr -d '\n\r' <"$req")"
    rm -f "$req"
    # Never let a request name a path or a flag.
    if ! [[ "$station" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
      printf 'ERR bad station id\n' >"$RELAY/resp/$id.tmp"
      mv "$RELAY/resp/$id.tmp" "$RELAY/resp/$id"
      continue
    fi
    out="$(timeout 90 python3 "$MGC" "$station" --no-reset 2>&1)" || true
    printf '%s\n' "$out" >"$RELAY/resp/$id.tmp"
    mv "$RELAY/resp/$id.tmp" "$RELAY/resp/$id"
  done
  sleep 0.2
done

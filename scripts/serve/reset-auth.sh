#!/bin/bash
# reset-auth.sh — the ONLY sanctioned way to wipe the gallery's accounts.
#
# `rm auth-state.json` is not an equivalent shortcut. That file is the account
# database: the passkey public keys in it are the only thing that lets anyone
# in, and nothing can regenerate them. Deleting it locks every enrolled device
# out permanently. That is not hypothetical — it is how a real admin account
# with two devices was destroyed on 2026-08-05, by an agent that wanted a fresh
# bootstrap token for a test run.
#
# So this script refuses by default the moment the gallery has a user, always
# takes a timestamped copy first, and tells you how to undo itself.
#
#   reset-auth.sh                 # safe: only resets an EMPTY gallery
#   reset-auth.sh --force         # wipes real accounts, after a backup
#   reset-auth.sh --restore FILE  # put a backup back
#   reset-auth.sh --list          # show what can be restored
set -euo pipefail

SERVE=/data/vms/streamhost/serve
STATE="$SERVE/auth-state.json"
UNIT=osgallery-https.service
MODE=reset
RESTORE_FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --force) MODE=force && shift ;;
    --restore) MODE=restore && RESTORE_FROM="${2:-}" && shift 2 ;;
    --list) MODE=list && shift ;;
    -h | --help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '[reset-auth] %s\n' "$*"; }
die() {
  printf '[reset-auth] ERROR: %s\n' "$*" >&2
  exit 1
}

accounts() {
  [ -f "$STATE" ] || {
    echo 0
    return
  }
  python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))['users']))" "$STATE" 2>/dev/null || echo 0
}

backup() {
  [ -f "$STATE" ] || return 0
  local dest
  dest="$SERVE/auth-state.backup-$(date -u +%Y%m%dT%H%M%SZ).json"
  cp -a "$STATE" "$dest"
  chmod 600 "$dest"
  log "backed up -> $dest"
}

if [ "$MODE" = list ]; then
  # find, not `ls glob1 glob2`: with one of the two patterns unmatched ls exits
  # non-zero even though it listed the other, which made this print a real
  # restore point AND "no backups yet" directly underneath it.
  found=$(find "$SERVE" -maxdepth 1 \( -name 'auth-state.backup-*.json' -o -name 'auth-state.2*.json' \) \
    -printf '%T@ %TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  if [ -n "$found" ]; then
    log "restore points, newest first:"
    printf '%s\n' "$found"
  else
    log "no backups yet"
  fi
  exit 0
fi

if [ "$MODE" = restore ]; then
  [ -n "$RESTORE_FROM" ] && [ -f "$RESTORE_FROM" ] || die "--restore needs a file that exists (see --list)"
  backup
  systemctl stop "$UNIT"
  install -m 600 "$RESTORE_FROM" "$STATE"
  systemctl start "$UNIT"
  log "restored $RESTORE_FROM — $(accounts) account(s) are back"
  exit 0
fi

HAVE="$(accounts)"
if [ "$HAVE" -gt 0 ] && [ "$MODE" != force ]; then
  log "this gallery has $HAVE account(s), with passkeys enrolled on real devices."
  log "Wiping it logs every one of them out FOREVER — passkeys cannot be recovered."
  log "If you are sure: $0 --force   (a backup is taken either way)"
  die "refusing to reset a gallery that has accounts"
fi

backup
systemctl stop "$UNIT"
rm -f "$STATE"
systemctl start "$UNIT"
sleep 2
log "reset done; the new one-time master token is:"
grep BOOTSTRAP "$SERVE/https-server.log" | tail -1
newest=$(find "$SERVE" -maxdepth 1 -name 'auth-state.backup-*.json' -printf '%T@ %p\n' 2>/dev/null |
  sort -rn | head -1 | cut -d' ' -f2-)
log "undo with: $0 --restore $newest"

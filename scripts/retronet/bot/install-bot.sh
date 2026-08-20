#!/usr/bin/env bash
# install-bot.sh — install the retronet ICQ bot + its caged systemd unit on
# labhost. Idempotent; run as root on labhost.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/bot/install-bot.sh --apply'
#
# Steps:
#   1. copy bot.py / oscar.py / llmclient.py / eliza.py -> /data/retronet/bot
#   2. write /etc/retronet/bot.env (0600) — the password comes from
#      registry/local.env (gitignored), NEVER from a committed file
#   3. drop-in the IPAddressAllow for the configured server, if not the default
#   4. install + enable + start retronet-bot.service
#
# Where the values come from, in order: the environment, then
# registry/local.env, then the defaults. registry/local.env is written by the
# gateway provisioner (stream B) and is gitignored — it is the single source of
# the UINs and the one password:
#   RETRONET_ICQ_HOST / _PORT / _BOT_UIN / _BOT_PASS / _PERSONA_UIN
# Overrides for a test rig: RN_BOT_SERVER=host:port RN_BOT_UIN=… RN_BOT_PASSWORD=…
#   RN_BOT_PERSONAS=98980:win98se   RN_BOT_LLM_URL=http://127.0.0.1:8091
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../../.." && pwd)"
DEST=/data/retronet/bot
APPLY=0
# The gateway provisioner mirrors credentials into the BOX checkout's local.env;
# a sandbox worktree has its own (usually older) copy. Prefer whichever has the
# keys, so this works both from /data/kernel-hive and from a wt.sh sandbox.
LOCAL_ENVS=("$REPO/registry/local.env" /data/kernel-hive/registry/local.env)

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "install-bot.sh: unknown arg $a" >&2
      exit 2
      ;;
  esac
done

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
do_or_plan() {
  if [ "$APPLY" = 1 ]; then "$@"; else say "PLAN: $*"; fi
}

[ "$(id -u)" = 0 ] || {
  echo "install-bot.sh: must run as root on labhost" >&2
  exit 1
}

# Read one key out of whichever local.env has it. Never `source` these files:
# they hold secrets and arbitrary shell would run as root.
from_local_env() {
  local key="$1" f val
  for f in "${LOCAL_ENVS[@]}"; do
    [ -f "$f" ] || continue
    val="$(sed -n "s/^[[:space:]]*$key=//p" "$f" | tail -1 | tr -d '"'"'"'')"
    [ -n "$val" ] && {
      printf '%s' "$val"
      return
    }
  done
}

# The one secret in this stream. It must never reach a committed file or a log.
RN_BOT_PASSWORD="${RN_BOT_PASSWORD:-$(from_local_env RETRONET_ICQ_BOT_PASS)}"
[ -n "${RN_BOT_PASSWORD:-}" ] || {
  echo "install-bot.sh: no bot password — set RN_BOT_PASSWORD, or run the gateway" >&2
  echo "  provisioner so RETRONET_ICQ_BOT_PASS lands in registry/local.env:" >&2
  echo "    ssh lab '/data/kernel-hive/scripts/retronet/gateway/provision-gateway-ct.sh accounts'" >&2
  exit 1
}

ICQ_HOST="$(from_local_env RETRONET_ICQ_HOST)"
ICQ_PORT="$(from_local_env RETRONET_ICQ_PORT)"
PERSONA_UIN="$(from_local_env RETRONET_ICQ_PERSONA_UIN)"
RN_BOT_SERVER="${RN_BOT_SERVER:-${ICQ_HOST:-10.99.0.2}:${ICQ_PORT:-5190}}"
RN_BOT_UIN="${RN_BOT_UIN:-$(from_local_env RETRONET_ICQ_BOT_UIN)}"
RN_BOT_UIN="${RN_BOT_UIN:-10000}"
RN_BOT_PERSONAS="${RN_BOT_PERSONAS:-${PERSONA_UIN:-98980}:win98se}"
RN_BOT_LLM_URL="${RN_BOT_LLM_URL:-http://127.0.0.1:8091}"
SERVER_HOST="${RN_BOT_SERVER%%:*}"

step "code -> $DEST"
do_or_plan mkdir -p "$DEST"
for f in bot.py oscar.py llmclient.py eliza.py; do
  do_or_plan install -m 0755 "$SRC/$f" "$DEST/$f"
done
# DynamicUser= is a transient uid with no group membership: it must be able to
# traverse /data/retronet and read the code. root's 0077 umask leaves 0700 dirs
# behind, which is a silent "Permission denied" at ExecStart and nowhere else.
do_or_plan chmod a+rX /data/retronet "$DEST"

step "/etc/retronet/bot.env"
if [ "$APPLY" = 1 ]; then
  mkdir -p /etc/retronet
  umask 077
  cat >/etc/retronet/bot.env <<EOF
# Written by install-bot.sh. Contains a password: mode 0600, never committed.
RN_BOT_SERVER=$RN_BOT_SERVER
RN_BOT_UIN=$RN_BOT_UIN
RN_BOT_PASSWORD=$RN_BOT_PASSWORD
RN_BOT_PERSONAS=$RN_BOT_PERSONAS
RN_BOT_LLM_URL=$RN_BOT_LLM_URL
RN_BOT_GREET_DELAY=${RN_BOT_GREET_DELAY:-30}
RN_BOT_MAX_CHARS=${RN_BOT_MAX_CHARS:-200}
EOF
  chmod 0600 /etc/retronet/bot.env
  say "wrote /etc/retronet/bot.env (0600) — server=$RN_BOT_SERVER uin=$RN_BOT_UIN"
else
  say "PLAN: write /etc/retronet/bot.env (0600) server=$RN_BOT_SERVER uin=$RN_BOT_UIN personas=$RN_BOT_PERSONAS"
fi

step "unit"
do_or_plan install -m 0644 "$SRC/retronet-bot.service" /etc/systemd/system/retronet-bot.service
DROPIN=/etc/systemd/system/retronet-bot.service.d/10-server.conf
if [ "$SERVER_HOST" != "10.99.0.2" ]; then
  # The cage is an explicit allowlist; a server that is not the contract gateway
  # has to be named, or the bot silently cannot reach it.
  if [ "$APPLY" = 1 ]; then
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Service]\nIPAddressAllow=%s\n' "$SERVER_HOST" >"$DROPIN"
    say "wrote $DROPIN (IPAddressAllow=$SERVER_HOST)"
  else
    say "PLAN: write $DROPIN (IPAddressAllow=$SERVER_HOST)"
  fi
else
  do_or_plan rm -f "$DROPIN"
fi
do_or_plan systemctl daemon-reload
do_or_plan systemctl enable retronet-bot.service
# restart, not just `enable --now` (a no-op on an already-running unit that left
# stale code/env live) — so a re-run of --apply actually picks up the new bot.py,
# llmclient.py and RN_BOT_PERSONAS.
do_or_plan systemctl restart retronet-bot.service
[ "$APPLY" = 1 ] && systemctl --no-pager --lines=10 status retronet-bot.service || true

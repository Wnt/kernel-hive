#!/usr/bin/env bash
# install-bot.sh — install the retronet ICQ bot + its caged systemd unit on
# labhost. Idempotent; run as root on labhost.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/bot/install-bot.sh --apply'
#   ssh lab '/data/kernel-hive/scripts/retronet/bot/install-bot.sh --instance aim --apply'
#
# TWO INSTANCES, ONE CODEBASE. --instance icq (the default) is HiveBot, ICQ UIN
# 10000, /etc/retronet/bot.env, retronet-bot.service. --instance aim is the AIM
# screen name `hivebot`, /etc/retronet/bot-aim.env, retronet-bot-aim.service —
# it exists because win311's AIM client refuses an all-numeric screen name and
# so cannot reply to a UIN at all (retronet-bot-aim.service explains this in
# full). roster.json's `greeter` field partitions the fleet between them, so a
# station is greeted exactly once, by an identity its client can answer.
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
#   RETRONET_ICQ_HOST / _PORT / _BOT_UIN / _BOT_PASS
# Overrides for a test rig: RN_BOT_SERVER=host:port RN_BOT_UIN=… RN_BOT_PASSWORD=…
#   RN_BOT_PERSONAS=98980:win98se   RN_BOT_LLM_URL=http://127.0.0.1:8091
#
# RN_BOT_PERSONAS is otherwise DERIVED from scripts/retronet/icq/roster.json
# (the onboarded rows) — see `seed_contacts.py personas`. Adding a station is
# one roster row; this script is safe to re-run and never invents the list.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SRC/../../.." && pwd)"
DEST=/data/retronet/bot
APPLY=0
INSTANCE=icq
# The gateway provisioner mirrors credentials into the BOX checkout's local.env;
# a sandbox worktree has its own (usually older) copy. Prefer whichever has the
# keys, so this works both from /data/kernel-hive and from a wt.sh sandbox.
LOCAL_ENVS=("$REPO/registry/local.env" /data/kernel-hive/registry/local.env)

want_instance=0
for a in "$@"; do
  if [ "$want_instance" = 1 ]; then
    INSTANCE="$a"
    want_instance=0
    continue
  fi
  case "$a" in
    --apply) APPLY=1 ;;
    --instance) want_instance=1 ;;
    --instance=*) INSTANCE="${a#--instance=}" ;;
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
case "$INSTANCE" in
  icq | aim) ;;
  *)
    echo "install-bot.sh: --instance must be icq or aim (got '$INSTANCE')" >&2
    exit 2
    ;;
esac
# Everything below is written per instance, so the two never share a file.
if [ "$INSTANCE" = aim ]; then
  UNIT=retronet-bot-aim.service
  ENV_FILE=/etc/retronet/bot-aim.env
else
  UNIT=retronet-bot.service
  ENV_FILE=/etc/retronet/bot.env
fi

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
if [ "$INSTANCE" = aim ]; then
  RN_BOT_PASSWORD="${RN_BOT_PASSWORD:-$(from_local_env RETRONET_AIM_BOT_PASS)}"
else
  RN_BOT_PASSWORD="${RN_BOT_PASSWORD:-$(from_local_env RETRONET_ICQ_BOT_PASS)}"
fi
[ -n "${RN_BOT_PASSWORD:-}" ] || {
  echo "install-bot.sh: no bot password — set RN_BOT_PASSWORD, or run the gateway" >&2
  echo "  provisioner so RETRONET_ICQ_BOT_PASS lands in registry/local.env:" >&2
  echo "    ssh lab '/data/kernel-hive/scripts/retronet/gateway/provision-gateway-ct.sh accounts'" >&2
  exit 1
}

ICQ_HOST="$(from_local_env RETRONET_ICQ_HOST)"
ICQ_PORT="$(from_local_env RETRONET_ICQ_PORT)"
RN_BOT_SERVER="${RN_BOT_SERVER:-${ICQ_HOST:-10.99.0.2}:${ICQ_PORT:-5190}}"
if [ "$INSTANCE" = aim ]; then
  RN_BOT_UIN="${RN_BOT_UIN:-$(from_local_env RETRONET_AIM_BOT_NAME)}"
  RN_BOT_UIN="${RN_BOT_UIN:-hivebot}"
else
  RN_BOT_UIN="${RN_BOT_UIN:-$(from_local_env RETRONET_ICQ_BOT_UIN)}"
  RN_BOT_UIN="${RN_BOT_UIN:-10000}"
fi
# The persona list is DERIVED from scripts/retronet/icq/roster.json — the same
# single source seed_contacts.py seeds contacts from. Onboarding a station is
# ONE roster row and nothing else; nobody hand-appends to bot.env, so there is
# no box-side state for a re-run to drop. Only `onboarded` rows become personas:
# a pending station has no live client to greet. RN_BOT_PERSONAS in the
# environment still wins, for a test rig (see the header).
# Rendering here, at install time, rather than reading the roster from bot.py at
# runtime: the unit is a DynamicUser cage whose only inputs are its code under
# /data/retronet/bot and this env file, and a git checkout is neither stable
# (mid-merge) nor declared as a dependency of the service. Install time is also
# when a bad roster can still be refused without leaving a broken bot behind.
roster_personas() { python3 "$REPO/scripts/retronet/icq/roster_lib.py" personas "$INSTANCE"; }
# `|| true`: on a FIRST install the env file does not exist yet, and under
# `set -o pipefail` sed's failure would abort the run before it could write it.
existing_personas() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n 's/^RN_BOT_PERSONAS=//p' "$ENV_FILE" | tail -1 || true
}
if [ -z "${RN_BOT_PERSONAS:-}" ]; then
  # No `|| true`, no fallback: a roster we cannot read must abort the install,
  # never silently write an empty or partial list over a working one.
  RN_BOT_PERSONAS="$(roster_personas)" || {
    echo "install-bot.sh: cannot derive personas from $REPO/scripts/retronet/icq/roster.json" >&2
    echo "  refusing to write a partial persona list. Fix the roster, or set RN_BOT_PERSONAS." >&2
    exit 1
  }
  [ -n "$RN_BOT_PERSONAS" ] || {
    echo "install-bot.sh: roster yielded no onboarded $INSTANCE stations — refusing to write" >&2
    exit 1
  }
fi
# Never silent about a change: say what this run adds or drops versus the box.
PREV_PERSONAS="$(existing_personas)"
if [ -n "$PREV_PERSONAS" ] && [ "$PREV_PERSONAS" != "$RN_BOT_PERSONAS" ]; then
  printf '  personas change: %s\n            -> %s\n' "$PREV_PERSONAS" "$RN_BOT_PERSONAS"
  for p_old in ${PREV_PERSONAS//,/ }; do
    case ",$RN_BOT_PERSONAS," in *",$p_old,"*) ;; *) printf '  DROPPED persona %s (not onboarded in roster.json)\n' "$p_old" ;; esac
  done
  for p_new in ${RN_BOT_PERSONAS//,/ }; do
    case ",$PREV_PERSONAS," in *",$p_new,"*) ;; *) printf '  ADDED persona %s\n' "$p_new" ;; esac
  done
fi
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

step "$ENV_FILE"
if [ "$APPLY" = 1 ]; then
  mkdir -p /etc/retronet
  umask 077
  cat >"$ENV_FILE" <<EOF
# Written by install-bot.sh. Contains a password: mode 0600, never committed.
RN_BOT_SERVER=$RN_BOT_SERVER
RN_BOT_UIN=$RN_BOT_UIN
RN_BOT_PASSWORD=$RN_BOT_PASSWORD
RN_BOT_PERSONAS=$RN_BOT_PERSONAS
RN_BOT_LLM_URL=$RN_BOT_LLM_URL
RN_BOT_GREET_DELAY=${RN_BOT_GREET_DELAY:-30}
RN_BOT_MAX_CHARS=${RN_BOT_MAX_CHARS:-200}
EOF
  chmod 0600 "$ENV_FILE"
  say "wrote $ENV_FILE (0600) — server=$RN_BOT_SERVER uin=$RN_BOT_UIN"
else
  say "PLAN: write $ENV_FILE (0600) server=$RN_BOT_SERVER uin=$RN_BOT_UIN personas=$RN_BOT_PERSONAS"
fi

step "unit"
do_or_plan install -m 0644 "$SRC/$UNIT" "/etc/systemd/system/$UNIT"
DROPIN=/etc/systemd/system/$UNIT.d/10-server.conf
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
do_or_plan systemctl enable "$UNIT"
# restart, not just `enable --now` (a no-op on an already-running unit that left
# stale code/env live) — so a re-run of --apply actually picks up the new bot.py,
# llmclient.py and RN_BOT_PERSONAS.
do_or_plan systemctl restart "$UNIT"
[ "$APPLY" = 1 ] && systemctl --no-pager --lines=10 status "$UNIT" || true

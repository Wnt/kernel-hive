#!/usr/bin/env bash
# box-deploy.sh — deploy a COMMIT to labhost: sync the checkout, install from it.
#
# The one door for "get the repo onto the box". It replaces the reactive
# box-sync-push / hand-scp loop with two steps that always run in this order:
#
#   1. scripts/dev/box-repo.sh sync      /data/kernel-hive fast-forwards to
#                                        origin/main (refuses over local edits)
#   2. scripts/host/box-install.sh       ON labhost, FROM that checkout, every
#                                        repo-authoritative pair row → live path
#                                        (scrub applied there), then stamps
#                                        /data/vms/streamhost/.deployed-rev
#
# Nothing is restarted. Restarts are per-station decisions:
# build-deploy.sh (daemon), systemctl restart streamhost@<station> (launcher/env).
#
# usage:
#   box-deploy.sh                 plan: what --apply would change (dry-run)
#   box-deploy.sh --apply         sync + install + stamp
#   box-deploy.sh --status        deployed rev vs origin/main, one screen
#   box-deploy.sh LABEL… --apply  only these pair labels (no stamp advance)
#   box-deploy.sh --stage         (P2) install THIS sandbox's UI + manifests
#                                 under /staging/<KH_SESSION>/ — see
#                                 scripts/dev/stage.sh
#   --no-sync                     skip step 1 (box already at the wanted commit)
#   --force-overlay               write over an active darklaunch overlay
# exit: box-install's exit code; 3 labhost unreachable
set -uo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOX_REPO="${BOX_REPO_DIR:-/data/kernel-hive}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/kh-session.sh"

APPLY=0 STATUS=0 SYNC=1 FORCE=""
declare -a LABELS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --status) STATUS=1 ;;
    --no-sync) SYNC=0 ;;
    --force-overlay) FORCE="--force-overlay" ;;
    --stage)
      exec "$SCRIPT_DIR/stage.sh" "$@"
      ;;
    -h | --help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "box-deploy: unknown flag $1" >&2
      exit 2
      ;;
    *) LABELS+=("$1") ;;
  esac
  shift
done

ssh -n -o ConnectTimeout=6 -o BatchMode=yes "$LAB" true 2>/dev/null || {
  echo "box-deploy: $LAB unreachable" >&2
  exit 3
}

if [ "$STATUS" = 1 ]; then
  git fetch -q origin main 2>/dev/null || true
  want="$(git rev-parse --short origin/main 2>/dev/null || echo '?')"
  "$SCRIPT_DIR/labrun" -- "$BOX_ROOT" "$BOX_REPO" "$want" <<'EOF'
BOX_ROOT="$1" REPO="$2" WANT="$3"
if [ -f "$BOX_ROOT/.deployed-rev" ]; then
  . "$BOX_ROOT/.deployed-rev"
  printf 'deployed  %s@%s  at %s  by %s\n' "$branch" "$short" "$when" "$by"
else
  echo "deployed  (no .deployed-rev yet — box was hand-mirrored; run box-deploy.sh --apply once)"
  short=""
fi
printf 'checkout  %s@%s\n' "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "$(git -C "$REPO" rev-parse --short HEAD)"
printf 'origin    main@%s\n' "$WANT"
if [ -n "$short" ] && [ "$short" != "$WANT" ]; then
  git -C "$REPO" fetch -q origin main 2>/dev/null || true
  n="$(git -C "$REPO" rev-list --count "$short..origin/main" 2>/dev/null || echo '?')"
  echo "box is BEHIND origin/main by $n commit(s)  → scripts/dev/box-deploy.sh --apply"
fi
"$REPO/scripts/host/box-install.sh" --repo "$REPO" | sed -n '2p'
EOF
  exit $?
fi

if [ "$SYNC" = 1 ]; then
  "$SCRIPT_DIR/box-repo.sh" sync || {
    echo "box-deploy: box-repo.sh sync refused — fix that first (dirty checkout or diverged)" >&2
    exit 1
  }
fi

args=(--repo "$BOX_REPO")
[ "$APPLY" = 1 ] && args+=(--apply)
[ -n "$FORCE" ] && args+=("$FORCE")
args+=("${LABELS[@]}")
q=""
for a in "${args[@]}"; do q="$q $(printf '%q' "$a")"; done
"$SCRIPT_DIR/labrun" -c "export KH_SESSION=$(printf '%q' "$KH_SESSION"); $BOX_REPO/scripts/host/box-install.sh$q"

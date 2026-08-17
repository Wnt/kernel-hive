#!/usr/bin/env bash
# here.sh — one screen of situational awareness; run it FIRST in a session.
#
# Replaces the ~6-command bootstrap every resumed session paid (git log,
# worktree list, box status, `labctl ls`, claims, "is anyone else working?")
# with one call that answers, in order: where am I · what is deployed · who
# else is here · what is staged · what is stopped/paused · what to run next.
# Costs one ssh round trip. Read it, then work.
#
# usage: here.sh [--no-fleet]     (--no-fleet skips the labctl ls summary)
set -uo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOX_REPO="${BOX_REPO_DIR:-/data/kernel-hive}"
SANDBOX="${KH_SANDBOX_ROOT:-/data/vms/sandbox}"
FLEET=1
[ "${1:-}" = "--no-fleet" ] && FLEET=0
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/kh-session.sh"

hr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

hr "where"
printf 'session   %s\nrepo      %s\nbranch    %s  %s\n' "$KH_SESSION" "$REPO" \
  "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null | cut -c1-70)"
n_dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l)"
[ "$n_dirty" = 0 ] || printf 'dirty     %s path(s) uncommitted here\n' "$n_dirty"
git -C "$REPO" fetch -q origin main 2>/dev/null || true
ab="$(git -C "$REPO" rev-list --left-right --count origin/main...HEAD 2>/dev/null | awk '{printf "ahead %s / behind %s", $2, $1}')"
printf 'vs main   %s\n' "${ab:-?}"
case "$REPO" in
  "$SANDBOX"/*) ;;
  *)
    if [ -e "$REPO/.claude/shared-clone-ok" ]; then
      echo "note      SHARED-CLONE EDITS ALLOWED (.claude/shared-clone-ok, operator said 'use shared clone'; 'back to sandboxes' removes it)"
    elif [ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" = main ]; then
      echo "note      shared clone is land-only — for work: scripts/dev/wt.sh new <name>  (operator: 'use shared clone' lifts this)"
    fi
    ;;
esac
git -C "$REPO" log -3 --format='  %h %<(60,trunc)%s %cr' 2>/dev/null

if ! ssh -n -o ConnectTimeout=4 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  hr "labhost"
  echo "unreachable (ssh $LAB) — box state, claims and fleet not shown"
  exit 0
fi

want="$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null || echo '?')"
"$SCRIPT_DIR/labrun" -- "$want" "$FLEET" "$SANDBOX" "$BOX_REPO" <<'EOF'
want="$1" fleet="$2" sandbox="$3" boxrepo="$4"
hr() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
hr "deployed (box)"
if [ -f /data/vms/streamhost/.deployed-rev ]; then
  . /data/vms/streamhost/.deployed-rev
  printf 'box       %s@%s  %s  by %s\n' "$branch" "$short" "$when" "$by"
  if [ "$short" != "$want" ]; then
    n="$(git -C "$boxrepo" rev-list --count "$short..origin/main" 2>/dev/null || echo '?')"
    printf 'origin    main@%s  — box BEHIND by %s: scripts/dev/box-deploy.sh --apply\n' "$want" "$n"
  else
    printf 'origin    main@%s  — box is current\n' "$want"
  fi
else
  echo "box       no .deployed-rev — run scripts/dev/box-deploy.sh --apply once"
fi
d="$("$boxrepo/scripts/host/box-install.sh" --repo "$boxrepo" --json 2>/dev/null)"
[ -z "$d" ] || printf 'live vs checkout: %s\n' "$(printf '%s' "$d" | sed 's/.*"same"/same/; s/,"apply.*//; s/"//g')"

hr "who else is here"
labctl who 2>/dev/null | sed 's/^/  /' || kh-claim ls
mapfile -t st < <(ls -d "$sandbox"/*/ 2>/dev/null)
printf '  sandboxes: %s dir(s) under %s   (scripts/dev/wt.sh ls · labctl who)\n' "${#st[@]}" "$sandbox"
if [ -d /data/vms/streamhost/serve/webroot/staging ]; then
  for s in /data/vms/streamhost/serve/webroot/staging/*/; do
    [ -f "$s/.staged-rev" ] || continue
    . "$s/.staged-rev"
    printf '  staged UI  /staging/%s/  %s@%s  %s\n' "$(basename "$s")" "$branch" "$sha" "$when"
  done
fi
for f in /data/vms/streamhost/serve/darklaunch.d/*.json; do
  [ -f "$f" ] && printf '  darklaunch overlay: %s  (legacy — prefer stage.sh)\n' "$(basename "$f" .json)"
done

if [ "$fleet" = 1 ]; then
  hr "fleet"
  labctl ls 2>/dev/null | awk 'NR>2 && NF>=8 {s[$8]++} END{for(k in s) printf "  %-10s %s\n", k, s[k]}' | sort -k2 -nr | head -6
  echo "  (labctl ls for the table; stopped/paused is routine — check for in-flight work first)"
fi
EOF

hr "next"
cat <<'EON'
  work        scripts/dev/wt.sh new <name>   → full stack; cd there; edit; commit; push branch
  remote      scripts/dev/labrun <<'EOF' … EOF   (no quoting; KH_SESSION forwarded)
  preview     scripts/dev/stage.sh              → https://<lab>:8443/staging/<name>/
  ship        merge to main · git push · scripts/dev/box-deploy.sh --apply
  wait        labctl wait-for --unit streamhost@<x> | --file P | --cmd C   (on the box, not sleep)
EON

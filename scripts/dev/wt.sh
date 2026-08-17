#!/usr/bin/env bash
# wt.sh — one FULL STACK per worker: worktree + sandbox + build dir + staging
# slot + claim, under one name, at one path that is the SAME on CT950 and on
# labhost.
#
# WHY. Worktrees fixed git collisions; every remaining collision was a
# box-side singleton (shared build dir, shared serve manifests, unnamed rigs,
# leaked displays) and every "workaround" — patching a shared file from the
# wrong tree, hand-copying scripts to a staging dir, editing live paths — was
# an agent that could not reach the RIGHT location from where it stood
# (docs/lab/research/workflow-friction-2026-08.md). The fix is structural:
# a worker's code, its clones, its Rust build and its UI staging all live in
#
#     /data/vms/sandbox/<name>/
#       repo/        git worktree of /data/kernel-hive on branch <name>
#       build/       scratch for box-side builds (cargo itself uses the warm
#                    shared target dir from streamhost/.cargo/config.toml)
#       <station>-*/ its clones (clone-guard root is the sandbox)
#       .kh-session  = <name>
#
# and its UI staging is served at /staging/<name>/ (box-deploy.sh --stage).
# /data/vms is bind-mounted into CT950, so the worker edits repo/ with local
# tools and labhost builds and runs from the very same bytes — no scp, no
# mirror, no "which copy is this". Fixes go where they belong.
#
# The worktree hangs off /data/kernel-hive (the labhost checkout), not the
# workstation clone, so `git` works on BOTH sides. `origin` is GitHub; commit
# on the branch, push the branch, land it on main from wherever you like.
#
# usage:
#   wt.sh new <name> [--from REF]   create everything (REF default origin/main)
#   wt.sh ls                        every sandbox: branch, ahead/behind, size, claim
#   wt.sh path <name>               print the repo path (for `cd "$(wt.sh path x)"`)
#   wt.sh rm <name> [--force]       remove worktree+branch+sandbox; refuses live
#                                   processes / unmerged commits unless --force
#   wt.sh gc [--apply]              rm every sandbox whose branch is merged into
#                                   origin/main and that has no live process;
#                                   also prunes legacy .claude/worktrees/ trees
#                                   whose branch is merged
# exit: 0 · 1 refused · 2 usage · 3 labhost unreachable
set -uo pipefail

LAB="${LAB:-lab}"
BOX_REPO="${BOX_REPO_DIR:-/data/kernel-hive}"
SANDBOX="${KH_SANDBOX_ROOT:-/data/vms/sandbox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABRUN="$SCRIPT_DIR/labrun"

die() {
  echo "wt.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

sanitize() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-24; }

# CT950 sees /data/vms and /data/kernel-hive through bind mounts (2026-08-17);
# without them this tool has nothing to stand on.
need_mounts() {
  [ -d "$SANDBOX" ] && [ -d "$BOX_REPO/.git" ] || die "$SANDBOX or $BOX_REPO not visible here — CT950 needs the /data bind mounts (AGENTS.md → CLOUD-AGENTS)"
}

# /data/kernel-hive/.git is written by root (box-repo.sh sync over ssh) and by
# us (worktree add). Make it ours once; root can still write it.
own_box_git() {
  local owner key
  # The box checkout's core.sshCommand names the GitHub key by its HOST path;
  # inside CT950 that path does not exist, so fall back to plain ssh here.
  key="$(git -C "$BOX_REPO" config core.sshCommand 2>/dev/null | sed -n 's/.*-i \([^ ]*\).*/\1/p')"
  if [ -n "$key" ] && [ ! -r "$key" ]; then
    export GIT_SSH_COMMAND="ssh"
  fi
  # root (box-repo.sh sync over ssh) leaves root-owned index/refs behind
  owner="$(find "$BOX_REPO/.git" -not -user "$(id -u)" -print -quit 2>/dev/null)"
  if [ -n "$owner" ] || [ "$(stat -c %u "$BOX_REPO/.git")" != "$(id -u)" ]; then
    sudo chown -R "$(id -u):$(id -g)" "$BOX_REPO/.git" || die "cannot chown $BOX_REPO/.git"
  fi
}

# processes whose cwd or exe or open files sit under a sandbox dir (box side)
live_pids() { # name
  "$LABRUN" -- "$1" <<'EOF'
d="/data/vms/sandbox/$1"
for p in /proc/[0-9]*; do
  cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
  case "$cwd" in "$d"|"$d"/*) echo "${p#/proc/} $(readlink "$p/exe" 2>/dev/null) cwd=$cwd"; continue;; esac
  if grep -qs -- "$d" "$p/cmdline" 2>/dev/null; then
    case "$(readlink "$p/exe" 2>/dev/null)" in *sshd*|*/bash|*/grep) ;; *) echo "${p#/proc/} $(readlink "$p/exe" 2>/dev/null) cmdline";; esac
  fi
done
EOF
}

cmd_new() {
  local raw="${1:-}" from="origin/main"
  [ -n "$raw" ] || usage 2
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        from="$2"
        shift
        ;;
      *) usage 2 ;;
    esac
    shift
  done
  local name dir repo
  name="$(sanitize "$raw")"
  [ "$name" = "$raw" ] || echo "wt.sh: name sanitized to '$name'" >&2
  dir="$SANDBOX/$name"
  repo="$dir/repo"
  need_mounts
  own_box_git

  # 1. the claim IS the proof — a second `new` with the same name refuses.
  KH_SESSION="$name" "$LABRUN" -- "$name" "$USER@$(hostname -s)" <<'EOF' || die "sandbox/$1 is claimed by another session (kh-claim ls)"
export KH_SESSION="$1"
kh-claim take sandbox "$1" --purpose "wt.sh full stack ($2)"
install -d -o 1000 -g 1000 -m 2775 "/data/vms/sandbox/$1" "/data/vms/sandbox/$1/build"
# root reads uid-1000 trees on labhost: tell its git so, once per tree
for d in /data/kernel-hive "/data/vms/sandbox/$1/repo"; do
  git config --global --get-all safe.directory 2>/dev/null | grep -qx "$d" || git config --global --add safe.directory "$d"
done
EOF

  # 2. worktree of the labhost checkout, on a fresh branch.
  git -C "$BOX_REPO" fetch -q origin || die "fetch failed"
  if [ -e "$repo" ]; then
    die "$repo already exists"
  fi
  if git -C "$BOX_REPO" show-ref --verify -q "refs/heads/$name"; then
    git -C "$BOX_REPO" worktree add -q "$repo" "$name" || die "worktree add failed"
  else
    git -C "$BOX_REPO" worktree add -q -b "$name" "$repo" "$from" || die "worktree add failed"
  fi

  # 3. the rest of the stack: identity, real addresses, node_modules, hooks.
  printf '%s\n' "$name" >"$repo/.kh-session"
  # keep the identity file out of `git status` even before .gitignore has it
  printf '.kh-session\n' >>"$(git -C "$repo" rev-parse --git-path info/exclude)"
  for src in "$MAIN_REPO/registry/local.env" "$BOX_REPO/registry/local.env"; do
    if [ -f "$src" ] && [ ! -f "$repo/registry/local.env" ]; then
      cp "$src" "$repo/registry/local.env"
      break
    fi
  done
  if [ -d "$MAIN_REPO/spa/node_modules" ] && [ ! -e "$repo/spa/node_modules" ]; then
    ln -s "$MAIN_REPO/spa/node_modules" "$repo/spa/node_modules"
  fi
  git -C "$repo" config core.hooksPath .claude/hooks 2>/dev/null || true

  cat <<EOM
wt.sh: full stack ready — $name
  repo      $repo   (branch $name from $from)
  sandbox   $dir/            clones + build/ live here; clone-guard root
  session   KH_SESSION=$name  (auto from $repo/.kh-session)
  staging   scripts/dev/box-deploy.sh --stage        → https://<lab>:8443/staging/$name/
  build     scripts/dev/labrun -c 'cd $repo/streamhost && cargo build --release'   (warm shared target)
            then land on main → scripts/dev/build-deploy.sh --canary <station>
next:  cd $repo
EOM
}

cmd_path() {
  local name
  name="$(sanitize "${1:-}")"
  [ -n "$name" ] || usage 2
  printf '%s\n' "$SANDBOX/$name/repo"
}

cmd_ls() {
  need_mounts
  git -C "$BOX_REPO" fetch -q origin 2>/dev/null || true
  local d name br ab size claim
  printf '%-24s %-22s %-12s %-8s %s\n' NAME BRANCH AHEAD/BEHIND SIZE CLAIM
  for d in "$SANDBOX"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    [ -e "$d/repo/.git" ] || continue
    br="$(git -C "$d/repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    ab="$(git -C "$d/repo" rev-list --left-right --count "origin/main...HEAD" 2>/dev/null | awk '{print "+"$2"/-"$1}')"
    size="$(du -sh "$d" 2>/dev/null | cut -f1)"
    claim="$(ssh -n "$LAB" "kh-claim who sandbox $name" 2>/dev/null)"
    printf '%-24s %-22s %-12s %-8s %s\n' "$name" "$br" "${ab:-?}" "$size" "$claim"
  done
  # legacy agent worktrees under the workstation clone
  local n
  n="$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | grep -c '^worktree .*/.claude/worktrees/')"
  [ "$n" = 0 ] || echo "legacy: $n .claude/worktrees/ trees under $MAIN_REPO (wt.sh gc prunes the merged ones)"
}

_remove_one() { # name force
  local name="$1" force="$2" dir="$SANDBOX/$1" repo="$SANDBOX/$1/repo" pids unmerged
  cd "$MAIN_REPO" || return 1 # never stand inside the tree being removed
  pids="$(live_pids "$name")"
  if [ -n "$pids" ] && [ "$force" != 1 ]; then
    echo "wt.sh: REFUSED $name — live processes in its sandbox:" >&2
    echo "$pids" >&2
    return 1
  fi
  if [ -d "$repo" ]; then
    unmerged="$(git -C "$repo" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 0)"
    if [ "$unmerged" != 0 ] && [ "$force" != 1 ]; then
      echo "wt.sh: REFUSED $name — $unmerged commit(s) not on origin/main (push or --force)" >&2
      return 1
    fi
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ] && [ "$force" != 1 ]; then
      echo "wt.sh: REFUSED $name — uncommitted changes in $repo" >&2
      return 1
    fi
    git -C "$BOX_REPO" worktree remove --force "$repo" 2>/dev/null || rm -rf "$repo"
    git -C "$BOX_REPO" branch -D "$name" >/dev/null 2>&1 || true
  fi
  # the sandbox dir may hold root-owned clone state; every clone kill already
  # went through clone-guard, so what is left is files.
  KH_SESSION="$name" "$LABRUN" -- "$name" <<'EOF'
export KH_SESSION="$1"
rm -rf "/data/vms/sandbox/$1"
kh-claim release sandbox "$1" --force >/dev/null 2>&1 || true
EOF
  git -C "$BOX_REPO" worktree prune
  echo "wt.sh: removed $name   (next task? wt.sh new <name> — the shared clone is land-only)"
}

cmd_rm() {
  local name force=0
  name="$(sanitize "${1:-}")"
  [ -n "$name" ] || usage 2
  [ "${2:-}" = "--force" ] && force=1
  need_mounts
  [ -d "$SANDBOX/$name" ] || die "no sandbox $name"
  _remove_one "$name" "$force"
}

cmd_gc() {
  local apply=0
  [ "${1:-}" = "--apply" ] && apply=1
  need_mounts
  git -C "$BOX_REPO" fetch -q origin 2>/dev/null || true
  local d name n=0
  for d in "$SANDBOX"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    [ -d "$d/repo" ] || continue
    [ "$(git -C "$d/repo" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 1)" = 0 ] || continue
    [ -z "$(git -C "$d/repo" status --porcelain 2>/dev/null)" ] || continue
    [ -z "$(live_pids "$name")" ] || continue
    n=$((n + 1))
    if [ "$apply" = 1 ]; then _remove_one "$name" 0; else echo "gc: would remove sandbox $name (merged, clean, idle)"; fi
  done
  # legacy: .claude/worktrees under the workstation clone
  local wt br
  while read -r wt; do
    br="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
    [ "$(git -C "$wt" rev-list --count "origin/main..HEAD" 2>/dev/null || echo 1)" = 0 ] || continue
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || continue
    n=$((n + 1))
    if [ "$apply" = 1 ]; then
      git -C "$MAIN_REPO" worktree remove --force "$wt" && git -C "$MAIN_REPO" branch -D "$br" >/dev/null 2>&1
      echo "gc: removed legacy $wt ($br)"
    else
      echo "gc: would remove legacy $wt ($br: merged, clean)"
    fi
  done < <(git -C "$MAIN_REPO" worktree list --porcelain | awk '/^worktree .*\/\.claude\/worktrees\//{print $2}')
  git -C "$MAIN_REPO" worktree prune
  [ "$apply" = 1 ] || [ "$n" = 0 ] || echo "gc: $n candidate(s); re-run with --apply"
}

case "${1:-}" in
  new)
    shift
    cmd_new "$@"
    ;;
  ls) cmd_ls ;;
  path)
    shift
    cmd_path "$@"
    ;;
  rm)
    shift
    cmd_rm "$@"
    ;;
  gc)
    shift
    cmd_gc "$@"
    ;;
  -h | --help | help | "") usage 0 ;;
  *) usage 2 ;;
esac

#!/usr/bin/env bash
# =============================================================================
# box-repo.sh — the canonical kernel-hive checkout ON the box, and its gate.
#
# WHY IT EXISTS
#   Builders run on the HOST, not in CT950: the golden images, the bridge bases
#   and every tile directory live under /data, and CT950 has no /data mount. But
#   until now there was no checkout on the host, so host-side build work reached
#   its own source by hand-copying it — `/root/kh-bridge/{scripts,registry}` for
#   the trixie base, a per-run rsync staging dir inside
#   scripts/dev/migrate-tile.sh for every single tile migration, and a copy of
#   scripts/build-guests/tiles/gt40.sh in /data/vms/soltest/BUILD-gt40/ that went
#   stale across the bookworm->trixie flip and would have silently built the tile
#   on the WRONG base. A hand-copy has no version, no drift signal and no way to
#   tell which commit a build actually ran.
#
#   The checkout fixes the class: one path, one commit id, one dirty flag.
#
# WHERE, AND WHY THERE
#   /data/kernel-hive. `/` is a 32 G LVM root with ~15 G free and carries the
#   Proxmox install; /data is the 473 G NVMe pool with ~451 G free. A fresh
#   clone is ~82 MB today, but it only grows (and a working clone with several
#   worktrees is already >1 G), and a full `/` breaks the hypervisor, not just a
#   build. It sits at the TOP of /data rather than under
#   /data/vms/ because /data/vms is guest state (and /data/vms/streamhost is
#   protected), and beside — never inside — /data/vms/streamhost/build, which is
#   build-deploy.sh's rsync mirror of the Rust workspace and is not a git tree.
#
# HOW IT AUTHENTICATES
#   With the GitHub key the box ALREADY has, read in place: CT950's
#   ~/.ssh/id_github, visible to host root at
#   /data/subvol-950-disk-0/home/wnt/.ssh/id_github. Nothing is generated, and
#   no key material is copied anywhere (least of all into the repo) — the clone
#   just points `core.sshCommand` at that file with IdentitiesOnly=yes, so the
#   credential keeps exactly one home and revoking it in GitHub revokes it for
#   both machines at once. If the operator later adds a host-root deploy key at
#   /root/.ssh/id_github, it is preferred automatically; BOX_REPO_SSH_KEY
#   overrides both.
#
# HOW IT IS UPDATED — EXPLICITLY, NEVER ON A TIMER
#   `box-repo.sh sync` fast-forwards it, and nothing else does. No cron, no
#   pull-on-use: a background pull can swap build-guests/ out from under a tile
#   bake that is 40 minutes into a golden, and the resulting image would carry no
#   record of which source produced it. Explicit sync means the operator chooses
#   the moment, and `status` prints the commit any report should quote.
#
# HOW IT MUST NOT DRIFT
#   It is a CLEAN checkout that is never edited in place. Edit in the repo, push,
#   `sync`. `status` prints the working tree's dirty files and `--strict` FAILS
#   on any of them (and on being behind origin/main), so drift is a red gate
#   rather than a surprise in a build log. `sync` refuses outright to fast-forward
#   over local modifications — it will not silently discard someone's edit, and it
#   will not silently build from one.
#
# usage: box-repo.sh [status|sync|init|path] [--strict] [--fetch]
# exit:  0 ok
#        1 dirty / behind under --strict, or sync refused
#        2 usage or local error
#        3 box unreachable — actual state could not be verified
# =============================================================================
set -uo pipefail

LAB="${LAB:-lab}"
DIR="${BOX_REPO_DIR:-/data/kernel-hive}"
REMOTE_URL="${BOX_REPO_REMOTE:-git@github.com:Wnt/kernel-hive.git}"
BRANCH="${BOX_REPO_BRANCH:-main}"
# Candidate GitHub keys, in preference order, as they exist ON THE BOX. These are
# paths, not secrets: nothing here is printed, copied or committed.
KEY_CANDIDATES="${BOX_REPO_SSH_KEY:-}
/root/.ssh/id_github
/data/subvol-950-disk-0/home/wnt/.ssh/id_github"

CMD=status
STRICT=0
FETCH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    status | sync | init | path) CMD="$1" ;;
    --strict) STRICT=1 ;;
    --fetch) FETCH=1 ;;
    -h | --help)
      sed -n '3,58p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "box-repo: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ "$CMD" = path ]; then
  printf '%s\n' "$DIR"
  exit 0
fi

if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  echo "box-repo: ssh $LAB unreachable — the box checkout was NOT inspected."
  echo "  (public clone, offline, or CI: this tool needs the box by definition.)"
  exit 3
fi

# ---------------------------------------------------------------------------
# Box side. One round trip: the program travels on stdin to `bash -s`, its
# parameters on argv.
# argv: <cmd> <dir> <url> <branch> <strict> <fetch> <key-candidate>...
# ---------------------------------------------------------------------------
read -r -d '' REMOTE <<'REMOTE_EOF' || true
set -uo pipefail
cmd=$1 dir=$2 url=$3 branch=$4 strict=$5 want_fetch=$6
shift 6

key=""
for cand in "$@"; do
  if [ -r "$cand" ]; then
    key="$cand"
    break
  fi
done

ssh_cmd=""
if [ -n "$key" ]; then
  ssh_cmd="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20"
fi

die() {
  echo "box-repo[box]: $*" >&2
  exit 2
}

# --- init: clone if absent, then (re)assert the auth + safety config ---------
if [ ! -d "$dir/.git" ]; then
  if [ "$cmd" != init ]; then
    echo "MISSING $dir"
    echo "  No checkout on the box. Create it:  scripts/dev/box-repo.sh init"
    exit 4
  fi
  [ -n "$key" ] || die "no readable GitHub key found; set BOX_REPO_SSH_KEY"
  [ ! -e "$dir" ] || die "$dir exists but is not a git checkout; move it aside first"
  mkdir -p "$(dirname "$dir")" || die "cannot create $(dirname "$dir")"
  GIT_SSH_COMMAND="$ssh_cmd" git clone --branch "$branch" "$url" "$dir" >&2 ||
    die "clone failed (is the key authorised for the private repo?)"
fi

cd "$dir" || die "cannot enter $dir"
if [ -n "$ssh_cmd" ]; then
  git config core.sshCommand "$ssh_cmd"
fi
git config --global --get-all safe.directory | grep -qxF "$dir" ||
  git config --global --add safe.directory "$dir"

# --- sync: fast-forward only, and never over local edits --------------------
if [ "$cmd" = sync ]; then
  cur=$(git rev-parse --abbrev-ref HEAD)
  [ "$cur" = "$branch" ] ||
    die "checked out on '$cur', not '$branch'; this tree tracks $branch only"
  if [ -n "$(git status --porcelain)" ]; then
    echo "REFUSED: the box checkout has local modifications." >&2
    git status --porcelain >&2
    echo "It is a clean mirror by contract — edit in the repo, push, then sync." >&2
    echo "Deliberately discarding them:  ssh lab 'git -C $dir checkout -- .'" >&2
    exit 1
  fi
  git fetch --quiet origin "$branch" || die "fetch failed"
  git merge --ff-only "origin/$branch" >&2 || die "not a fast-forward; resolve on the box"
elif [ "$want_fetch" = 1 ]; then
  git fetch --quiet origin "$branch" || die "fetch failed"
fi

# --- status ------------------------------------------------------------------
head=$(git rev-parse --short HEAD)
subject=$(git log -1 --format=%s)
when=$(git log -1 --format=%ci)
cur=$(git rev-parse --abbrev-ref HEAD)
dirty=$(git status --porcelain)
n_dirty=$(printf '%s' "$dirty" | grep -c . || true)
behind=0
ahead=0
if git rev-parse --verify --quiet "origin/$branch" >/dev/null; then
  behind=$(git rev-list --count "HEAD..origin/$branch")
  ahead=$(git rev-list --count "origin/$branch..HEAD")
fi

echo "path      $dir"
echo "branch    $cur"
echo "commit    $head  $subject"
echo "committed $when"
echo "auth      ${key:-NONE (no readable GitHub key — clone/fetch will fail)}"
if [ "$n_dirty" -eq 0 ]; then
  echo "worktree  clean"
else
  echo "worktree  DIRTY ($n_dirty path(s)) — this tree is a mirror, not a workspace"
  printf '%s\n' "$dirty" | sed 's/^/            /'
fi
if [ "$behind" -gt 0 ]; then
  echo "vs origin BEHIND by $behind commit(s) — run: scripts/dev/box-repo.sh sync"
elif [ "$ahead" -gt 0 ]; then
  echo "vs origin AHEAD by $ahead commit(s) — the box has commits nobody pushed"
else
  echo "vs origin up to date (as of the last fetch; --fetch to refresh)"
fi

rc=0
if [ "$strict" = 1 ]; then
  [ "$n_dirty" -eq 0 ] || rc=1
  [ "$behind" -eq 0 ] || rc=1
  [ "$ahead" -eq 0 ] || rc=1
  [ "$rc" -eq 0 ] || echo "box-repo: FAIL (--strict) — the box checkout is not a clean, current mirror."
fi
exit $rc
REMOTE_EOF

ARGS=("$CMD" "$DIR" "$REMOTE_URL" "$BRANCH" "$STRICT" "$FETCH")
while IFS= read -r cand; do
  [ -n "$cand" ] && ARGS+=("$cand")
done <<<"$KEY_CANDIDATES"

printf '%s' "$REMOTE" |
  ssh -o ConnectTimeout=20 "$LAB" "bash -s -- $(printf '%q ' "${ARGS[@]}")"
rc=$?
# 4 = "no checkout yet"; that is a local usage error, not a box failure.
[ "$rc" -eq 4 ] && rc=2
exit "$rc"

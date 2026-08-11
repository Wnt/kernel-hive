#!/usr/bin/env bash
# harvest.sh — safely collate labhost's authored source back into this repo.
#
# Dry-run is the default.  A real, marker-writing harvest is deliberately two-key:
#
#   scripts/dev/harvest.sh --dry-run
#   scripts/dev/harvest.sh --apply --commit
#
# Select a subset by repeating --tree NAME.  Run --list-trees for the allowlist.
# A subset apply is useful for review, but only a committed harvest that includes
# `src` refreshes labhost's .last-harvest source digest.
set -euo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${HARVEST_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BOX_ROOT="${HARVEST_BOX_ROOT:-/data/vms/streamhost}"
BOX_BUILD="$BOX_ROOT/build"
BOX_MEMBER="$BOX_BUILD/streamhost"
MARKER="$BOX_MEMBER/.last-harvest"

MODE=dry-run
DO_COMMIT=0
MESSAGE="chore: harvest lab box changes"
declare -a REQUESTED=()
declare -a TREES=(src launchers labctl tiles-json serve registry)
declare -a SECRET_EXCLUDES=(
  '--exclude=uptoken'
  '--exclude=unifitoken'
  '--exclude=credentials.md'
  '--exclude=gallery-credentials.md'
  '--exclude=credentials.ts'
  '--exclude=pki/'
  '--exclude=*.key'
)

die() {
  printf 'harvest: ERROR: %s\n' "$*" >&2
  exit 1
}
note() { printf 'harvest: %s\n' "$*"; }

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  -n, --dry-run       itemize box->repo changes without writing (default)
  --apply             copy the selected allowlisted files into the worktree
  --commit            commit after review checks (requires --apply)
  -m, --message MSG   commit message
  --tree NAME         select one tree; repeatable
  --list-trees        print the allowlist
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n | --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --commit) DO_COMMIT=1 ;;
    -m | --message)
      [ $# -ge 2 ] || die "$1 requires a value"
      MESSAGE="$2"
      shift
      ;;
    --tree)
      [ $# -ge 2 ] || die "--tree requires a value"
      REQUESTED+=("$2")
      shift
      ;;
    --list-trees)
      printf '%s\n' "${TREES[@]}"
      exit 0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$DO_COMMIT" -eq 0 ] || [ "$MODE" = apply ] || die "--commit requires --apply"
command -v rsync >/dev/null || die "rsync is required"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git worktree: $REPO"

if [ "${#REQUESTED[@]}" -eq 0 ]; then
  REQUESTED=("${TREES[@]}")
fi

selected() {
  local want="$1" item
  for item in "${REQUESTED[@]}"; do [ "$item" = "$want" ] && return 0; done
  return 1
}

for item in "${REQUESTED[@]}"; do
  case " ${TREES[*]} " in *" $item "*) : ;; *) die "unknown tree '$item' (use --list-trees)" ;; esac
done

is_secret_path() {
  case "$1" in
    *uptoken* | *unifitoken* | *credentials.md* | *credentials.ts* | */pki/* | pki/* | *.key)
      return 0
      ;;
  esac
  return 1
}

allowed_repo_path() {
  case "$1" in
    streamhost/Cargo.toml | streamhost/Cargo.lock | streamhost/streamhost/Cargo.toml | streamhost/streamhost/src/*.rs) selected src ;;
    streamhost/stations/*/qemu-streamhost.sh) selected launchers ;;
    scripts/labctl) selected labctl ;;
    scripts/tiles.json.sample) selected tiles-json ;;
    scripts/serve/clientcmd.sh | scripts/serve/gen-local-ca.sh | scripts/serve/osgallery-https-server.py | scripts/serve/reset-tile.sh | scripts/serve/restart-https.sh | scripts/serve/tiles.json | scripts/serve/golden-manifest.json) selected serve ;;
    registry/*.md | registry/*.json | registry/*.in) selected registry ;;
    *) return 1 ;;
  esac
}

if [ "$MODE" = apply ]; then
  branch="$(git -C "$REPO" symbolic-ref --quiet --short HEAD || true)"
  [ -n "$branch" ] || die "refusing an apply from detached HEAD"
  case "$branch" in main | master) die "refusing to harvest directly on $branch; use a review branch" ;; esac
  [ -z "$(git -C "$REPO" status --porcelain --untracked-files=all)" ] ||
    die "worktree must be clean before --apply"
fi

declare -a RSYNC=(-a --checksum --itemize-changes)
[ "$MODE" = dry-run ] && RSYNC+=(--dry-run)
RSYNC+=("${SECRET_EXCLUDES[@]}")
SSH_TRANSPORT="ssh -o ConnectTimeout=15"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pull_file() { # remote path, repo-relative destination
  local remote="$1" local_rel="$2"
  [ "$MODE" = dry-run ] || mkdir -p "$REPO/$(dirname "$local_rel")"
  rsync "${RSYNC[@]}" -e "$SSH_TRANSPORT" "$LAB:$remote" "$REPO/$local_rel"
}

note "mode=$MODE trees=${REQUESTED[*]} host=$LAB"
note "secret exclusions are mandatory: tokens, credentials docs/TS, pki/, and private keys"

if selected src; then
  note "[src] inverse of build-deploy.sh source + manifest mirror"
  rsync "${RSYNC[@]}" --include='*/' --include='*.rs' --exclude='*' \
    -e "$SSH_TRANSPORT" "$LAB:$BOX_MEMBER/src/" "$REPO/streamhost/streamhost/src/"
  pull_file "$BOX_BUILD/Cargo.toml" streamhost/Cargo.toml
  pull_file "$BOX_BUILD/Cargo.lock" streamhost/Cargo.lock
  pull_file "$BOX_MEMBER/Cargo.toml" streamhost/streamhost/Cargo.toml
fi

if selected launchers; then
  note "[launchers] tracked verbatim qemu-streamhost.sh files only"
  git -C "$REPO" ls-files 'streamhost/stations/*/qemu-streamhost.sh' |
    sed 's#^streamhost/stations/##' | sort >"$tmpdir/repo-launchers"
  ssh -o ConnectTimeout=15 "$LAB" \
    "find '$BOX_ROOT/tiles' -mindepth 2 -maxdepth 2 -type f -name qemu-streamhost.sh -printf '%P\\n' | sort" \
    >"$tmpdir/box-launchers"
  comm -12 "$tmpdir/repo-launchers" "$tmpdir/box-launchers" >"$tmpdir/launchers"
  comm -23 "$tmpdir/repo-launchers" "$tmpdir/box-launchers" |
    sed 's/^/harvest:   tracked launcher missing on box: /' >&2 || true
  rsync "${RSYNC[@]}" --files-from="$tmpdir/launchers" -e "$SSH_TRANSPORT" \
    "$LAB:$BOX_ROOT/tiles/" "$REPO/streamhost/stations/"
fi

if selected labctl; then
  note "[labctl] /usr/local/bin/labctl"
  pull_file /usr/local/bin/labctl scripts/labctl
fi

if selected tiles-json; then
  note "[tiles-json] live labctl matrix -> committed sample"
  pull_file "$BOX_ROOT/tiles.json" scripts/tiles.json.sample
fi

if selected serve; then
  note "[serve] README-declared live/reference files, exact-mode rows only"
  # osgallery-https.service and restart-https.sh are deliberately absent: they
  # are SCRUB-mode pairs (real host IP/domain on labhost, placeholders in the
  # repo), so pulling them verbatim would commit real addresses. The labhost copy
  # is a scrubbed deployment of repo content, never a harvest source.
  # tiles.json and golden-manifest.json are deliberately absent: both are
  # RENDERED from the registry (stations-registry.py rendered()) and have no repo
  # copy to harvest into. A live/repo divergence in those is fixed in
  # registry/stations/<id>.json and republished, never pulled back.
  cat >"$tmpdir/serve-files" <<'EOF'
clientcmd.sh
gen-local-ca.sh
install-https-service.sh
osgallery-https-server.py
reset-tile.sh
EOF
  rsync "${RSYNC[@]}" --files-from="$tmpdir/serve-files" -e "$SSH_TRANSPORT" \
    "$LAB:$BOX_ROOT/serve/" "$REPO/scripts/serve/"
fi

if selected registry; then
  note "[registry] JSON/schema/templates/README allowlist from box checkout"
  rsync "${RSYNC[@]}" --include='*/' --include='README.md' --include='*.json' --include='*.in' --exclude='*' \
    -e "$SSH_TRANSPORT" "$LAB:$BOX_BUILD/registry/" "$REPO/registry/"
fi

if [ "$MODE" = dry-run ]; then
  note "dry-run complete; review the itemized box->repo changes above"
  note "rerun with --apply --commit only after that review"
  exit 0
fi

note "review summary"
git -C "$REPO" status --short
git -C "$REPO" diff --stat
git -C "$REPO" diff --check

while IFS= read -r -d '' path; do
  is_secret_path "$path" && die "secret-like path escaped the hard excludes: $path"
  allowed_repo_path "$path" || die "rsync changed a path outside the selected allowlist: $path"
done < <({
  git -C "$REPO" diff --name-only -z
  git -C "$REPO" ls-files --others --exclude-standard -z
})

if [ "$DO_COMMIT" -eq 0 ]; then
  note "apply complete but uncommitted; marker intentionally NOT refreshed"
  note "review, then rerun from a clean branch with --apply --commit"
  exit 0
fi

if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=all)" ]; then
  git -C "$REPO" add -- \
    streamhost/Cargo.toml streamhost/Cargo.lock streamhost/streamhost/Cargo.toml \
    streamhost/streamhost/src streamhost/stations scripts/labctl scripts/tiles.json.sample \
    scripts/serve registry
  while IFS= read -r -d '' path; do
    is_secret_path "$path" && die "refusing to commit secret-like path: $path"
    allowed_repo_path "$path" || die "refusing to commit path outside the selected allowlist: $path"
  done < <(git -C "$REPO" diff --cached --name-only -z)
  git -C "$REPO" commit -m "$MESSAGE"
else
  note "box and repo already match for the selected trees; no commit needed"
fi

if selected src; then
  sha="$(git -C "$REPO" rev-parse HEAD)"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  src_md5="$(ssh -o ConnectTimeout=15 "$LAB" \
    "find '$BOX_MEMBER/src' -type f -name '*.rs' -print0 | sort -z | xargs -0 -r md5sum | md5sum | awk '{print \$1}'")"
  [ -n "$src_md5" ] || die "could not compute the remote source digest; marker not written"
  printf 'version=1\ngit_sha=%s\nharvested_at=%s\nsrc_tree_md5=%s\n' "$sha" "$stamp" "$src_md5" |
    ssh -o ConnectTimeout=15 "$LAB" \
      "umask 022; cat > '$MARKER.tmp'; mv -f '$MARKER.tmp' '$MARKER'"
  note "wrote $LAB:$MARKER (git_sha=$sha, src_tree_md5=$src_md5)"
else
  note "src was not selected; marker intentionally left unchanged"
fi

note "harvest complete"

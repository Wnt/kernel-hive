#!/usr/bin/env bash
# =============================================================================
# box-install.sh — install a COMMIT onto labhost, from the checkout, in place.
#
# Runs ON labhost as root, from a clean git checkout (normally /data/kernel-hive
# after `box-repo.sh sync`; a sandbox repo for a staged install). It reads the
# ONE pair table (scripts/lib/box-sync-pairs.sh) — the same rows, modes,
# authorities and scrub map the gate reads — and for every repo-authoritative
# row writes the checkout's bytes to the live path: verbatim for `exact`,
# through the forward scrub (registry/local.env) for `scrub`. It then stamps
# $BOX_ROOT/.deployed-rev with the commit it installed.
#
# WHY. Until 2026-08-17 the box ran a hand-mirrored COPY of the repo (~230
# md5 pairs pushed by scp / box-sync-push from whichever workstation checkout
# ran last) — so "what is deployed?" had no answer, drift was a push blocker
# every session hit, and rendered manifests were clobbered by the last
# publisher (docs/lab/research/workflow-friction-2026-08.md). Installing from
# a checkout at a sha turns all of that into ONE fact: `.deployed-rev`.
#
# GUARANTEES
#   * dry-run by default; --apply writes. Every write is tmp + mv -f in the
#     target dir, mode preserved from the file being replaced (repo mode for a
#     new file); the previous bytes go to $BOX_ROOT/.deploys/<ts>-<sha>/backup/.
#   * a `scrub` row with no scrub map is REFUSED (never a placeholder over a
#     live address); a row under an ACTIVE darklaunch overlay is skipped and
#     named (staging replaces overlays — box-deploy.sh --stage);
#   * `box`-authority rows (live matrix, golden manifest) are never written;
#   * post=daemon-reload rows trigger exactly one `systemctl daemon-reload`;
#   * `src/*.rs` rows re-stamp streamhost/.last-harvest (build-deploy's guard);
#   * nothing is restarted — that is a station decision, not an install.
#
# usage: box-install.sh [--repo DIR] [--apply] [--all | LABEL…] [--json]
#                        [--force-overlay] [--stamp-only]
#   default rows: every repo-authoritative row (= --all)
# exit: 0 nothing to do or applied+verified · 1 refused/failed rows · 2 usage
# =============================================================================
set -uo pipefail

REPO="${BOX_INSTALL_REPO:-/data/kernel-hive}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"
APPLY=0 FORCE_OVERLAY=0 JSON=0
declare -a WANT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift
      ;;
    --apply) APPLY=1 ;;
    --all) ;;
    --force-overlay) FORCE_OVERLAY=1 ;;
    --json) JSON=1 ;;
    -h | --help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "box-install: unknown flag $1" >&2
      exit 2
      ;;
    *) WANT+=("$1") ;;
  esac
  shift
done

[ "$(id -u)" = 0 ] || {
  echo "box-install: must run as root on labhost" >&2
  exit 2
}
[ -d "$REPO/.git" ] || [ -f "$REPO/.git" ] || {
  echo "box-install: $REPO is not a git checkout" >&2
  exit 2
}

# shellcheck disable=SC1091
. "$REPO/scripts/lib/box-sync-pairs.sh"

SHA="$(git -C "$REPO" rev-parse HEAD)"
SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
DIRTY="$(git -C "$REPO" status --porcelain --untracked-files=no | wc -l)"
if [ "$DIRTY" != 0 ] && [ "$APPLY" = 1 ]; then
  echo "box-install: REFUSED — $REPO has $DIRTY uncommitted change(s); install a commit, not an edit" >&2
  exit 1
fi

TMP="$(mktemp -d /run/box-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEPLOY_DIR="$BOX_ROOT/.deploys/$STAMP-$SHORT"

box_sync_scrub_init "$REPO"
box_sync_load_pairs "$REPO" "$BOX_ROOT" local "$TMP" || exit 1
box_sync_darklaunch_load local "$BOX_ROOT"

want_row() { # label
  [ "${#WANT[@]}" = 0 ] && return 0
  local w
  for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

n_same=0 n_change=0 n_new=0 n_skip=0 n_refuse=0 n_orphan=0
declare -a CHANGED=() NEWROWS=() SKIPPED=() REFUSED=() ORPHANS=() PLAN_I=()
declare -A DESIRED=()
need_reload=0 rust_moved=0

for i in "${!BOX_SYNC_LABELS[@]}"; do
  label="${BOX_SYNC_LABELS[$i]}"
  want_row "$label" || continue
  [ "${BOX_SYNC_AUTHORITY[$i]}" = repo ] || continue
  rf="$REPO/${BOX_SYNC_REPO_FILES[$i]}"
  bf="${BOX_SYNC_BOX_FILES[$i]}"
  mode="${BOX_SYNC_MODES[$i]}"
  if [ ! -f "$rf" ]; then
    # union-discovered row that only the box has: not ours to delete blindly
    ORPHANS+=("$label")
    n_orphan=$((n_orphan + 1))
    continue
  fi
  if [ "$mode" = scrub ] && [ "$BOX_SYNC_SCRUB_READY" != 1 ]; then
    REFUSED+=("$label (scrub row, no registry/local.env in $REPO)")
    n_refuse=$((n_refuse + 1))
    continue
  fi
  if [ -n "${BOX_SYNC_DL_NAMES[$bf]:-}" ] && [ "$FORCE_OVERLAY" != 1 ]; then
    SKIPPED+=("$label [darklaunch ${BOX_SYNC_DL_NAMES[$bf]}]")
    n_skip=$((n_skip + 1))
    continue
  fi
  d="$TMP/desired-$i"
  if [ "$mode" = scrub ]; then
    sed -e "$BOX_SYNC_FORWARD_PROG" -- "$rf" >"$d"
  else
    cp -- "$rf" "$d"
  fi
  DESIRED[$i]="$d"
  # "same" for a scrub row is judged the way the gate judges it — reverse-scrub
  # the live copy and compare canonical forms — so a live copy that carries the
  # placeholder-with-shell-fallback form (serve-https-spa.sh writes that) is
  # not rewritten to the flat real form on every install and back again.
  same=0
  if [ -f "$bf" ]; then
    if [ "$mode" = scrub ]; then
      if cmp -s <(sed -e "$BOX_SYNC_REVERSE_PROG" -- "$bf") <(sed -e "$BOX_SYNC_CANON_PROG" -- "$rf"); then same=1; fi
    elif cmp -s "$d" "$bf"; then
      same=1
    fi
  fi
  if [ ! -f "$bf" ]; then
    NEWROWS+=("$label")
    n_new=$((n_new + 1))
    PLAN_I+=("$i")
  elif [ "$same" = 1 ]; then
    n_same=$((n_same + 1))
  else
    CHANGED+=("$label")
    n_change=$((n_change + 1))
    PLAN_I+=("$i")
  fi
done

if [ "$JSON" = 1 ]; then
  printf '{"sha":"%s","branch":"%s","dirty":%s,"same":%s,"changed":%s,"new":%s,"skipped":%s,"refused":%s,"orphan":%s,"apply":%s}\n' \
    "$SHA" "$BRANCH" "$DIRTY" "$n_same" "$n_change" "$n_new" "$n_skip" "$n_refuse" "$n_orphan" "$APPLY"
else
  echo "box-install: $BRANCH@$SHORT from $REPO → $BOX_ROOT"
  echo "  same $n_same · changed $n_change · new $n_new · skipped $n_skip · refused $n_refuse · box-only $n_orphan"
  for l in "${CHANGED[@]}"; do echo "  changed  $l"; done
  for l in "${NEWROWS[@]}"; do echo "  new      $l"; done
  for l in "${SKIPPED[@]}"; do echo "  skipped  $l"; done
  for l in "${REFUSED[@]}"; do echo "  REFUSED  $l"; done
  for l in "${ORPHANS[@]}"; do echo "  box-only $l   (repo has no such file; remove on labhost by hand if obsolete)"; done
fi

if [ "$APPLY" != 1 ]; then
  [ "${#PLAN_I[@]}" = 0 ] && [ "$n_refuse" = 0 ] || echo "box-install: dry-run — re-run with --apply"
  [ "$n_refuse" = 0 ] || exit 1
  exit 0
fi

# --- apply -------------------------------------------------------------------
failed=0
if [ "${#PLAN_I[@]}" -gt 0 ]; then
  mkdir -p "$DEPLOY_DIR/backup"
  for i in "${PLAN_I[@]}"; do
    label="${BOX_SYNC_LABELS[$i]}"
    bf="${BOX_SYNC_BOX_FILES[$i]}"
    d="${DESIRED[$i]}"
    dir="$(dirname "$bf")"
    mkdir -p "$dir" || {
      echo "  FAIL mkdir $dir" >&2
      failed=$((failed + 1))
      continue
    }
    if [ -f "$bf" ]; then
      mode_bits="$(stat -c %a "$bf")"
      mkdir -p "$DEPLOY_DIR/backup$dir" && cp -p -- "$bf" "$DEPLOY_DIR/backup$bf"
    else
      mode_bits="$(stat -c %a "$REPO/${BOX_SYNC_REPO_FILES[$i]}")"
    fi
    tmpf="$(mktemp "$dir/.box-install.XXXXXX")"
    if cp -- "$d" "$tmpf" && chmod "$mode_bits" "$tmpf" && mv -f -- "$tmpf" "$bf" && cmp -s "$d" "$bf"; then
      echo "  installed $label"
      [ "${BOX_SYNC_POST[$i]}" = daemon-reload ] && need_reload=1
      case "$label" in src/*.rs) rust_moved=1 ;; esac
    else
      rm -f -- "$tmpf"
      echo "  FAIL      $label" >&2
      failed=$((failed + 1))
    fi
  done
fi

if [ "$need_reload" = 1 ]; then
  systemctl daemon-reload && echo "  daemon-reload done"
fi
if [ "$rust_moved" = 1 ]; then
  src="$BOX_ROOT/build/streamhost/src" marker="$BOX_ROOT/build/streamhost/.last-harvest"
  dgst="$(find "$src" -type f -name '*.rs' -print0 | sort -z | xargs -0 -r md5sum | md5sum | awk '{print $1}')"
  printf 'version=1\ngit_sha=%s\nharvested_at=%s\nsrc_tree_md5=%s\n' "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$dgst" >"$marker" &&
    echo "  re-stamped .last-harvest"
fi

# --- the stamp: ONE fact about what the box runs ------------------------------
if [ "$failed" = 0 ] && [ "${#WANT[@]}" = 0 ]; then
  {
    printf 'sha=%s\nshort=%s\nbranch=%s\nwhen=%s\nby=%s\nrepo=%s\nrows_installed=%s\nrows_skipped=%s\n' \
      "$SHA" "$SHORT" "$BRANCH" "$STAMP" "${KH_SESSION:-root}" "$REPO" "${#PLAN_I[@]}" "$n_skip"
  } >"$BOX_ROOT/.deployed-rev"
  echo "box-install: $BOX_ROOT/.deployed-rev = $BRANCH@$SHORT"
elif [ "$failed" = 0 ]; then
  echo "box-install: partial install (${#WANT[@]} label(s)) — .deployed-rev not advanced"
fi
[ "$failed" = 0 ] && [ "$n_refuse" = 0 ] || exit 1
exit 0

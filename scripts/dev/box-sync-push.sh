#!/usr/bin/env bash
# =============================================================================
# box-sync-push.sh — the reconcile half of verify-box-sync.sh: repo -> labhost.
#
# WHY THIS EXISTS. On 2026-08-10 the detector said DIFFERS four separate times
# and the only remedy in the repo was a human typing `scp` at a production path,
# one file at a time. `verify-box-sync.sh` ends at "decide which side is
# authoritative, then sync that way"; `harvest.sh` only ever runs labhost -> repo.
# The pre-push gate blocks on that drift, so hand-scp sat on the critical path
# of every branch that touched a mirrored file — and each hand-scp was a fresh
# chance to make the one mistake this repo cannot take back.
#
# THE MISTAKE. Three of the mirrored rows are DEPLOYED with the operator's real
# LAN address and public hostnames substituted in for this repo's scrubbed
# RFC 5737 / RFC 2606 placeholders (AGENTS.md "Placeholder values"). A blind
# copy of the repo file writes `192.0.2.10` and `gallery.example.com` over a
# live HTTPS origin and its systemd unit. The exhibit keeps serving until the
# next restart, and then it does not. So a safe push is NOT "scp with a sed":
#
#   * scrub rows are written through the FORWARD substitution built from the
#     same registry/local.env map the gate reverses with — one map, one
#     library (scripts/lib/box-sync-pairs.sh), never a second copy of it;
#   * an `exact` row whose labhost copy turns out to contain a real value is a
#     MIS-DECLARED row, and pushing it is refused, not fixed up silently. That
#     is detected with the reverse program alone: if reverse-scrubbing the labhost
#     copy changes its hash, the labhost copy holds a real value;
#   * with no registry/local.env NOTHING is pushed. Unable to tell a
#     placeholder from a real value is a REFUSAL in the write direction. The
#     gate is allowed to report UNCHECKED; a writer is not.
#
# DIRECTION IS PER ROW AND DECLARED, NEVER GUESSED. Each pair carries an
# `authority` field. This tool pushes `repo` rows only. A `box` row (the live
# labctl matrix, the signaling registry, the golden manifest — generated on
# labhost, mirrored into the repo as a committed reference) is refused by name and
# sent to `harvest.sh`, which is the tool for that direction. A row under an
# ACTIVE darklaunch overlay (serve/darklaunch.d — see box-sync-pairs.sh) is
# likewise refused: pushing over it would strip the overlaid rows. `--all-drift`
# skips such rows with a note instead of selecting them.
#
# NOTHING MOVES WITHOUT --apply. The default prints the unified diff of the
# reverse-scrubbed labhost copy against the canonicalised repo copy — the same read
# path the gate hashes, so what you review is what gets compared afterwards.
#
# THE CLAIM IS THE PROOF. Every applied row takes a labhost-side backup
# `<box>.presync-<UTC>`, is written atomically (tmp + `mv -f`, mode preserved
# from the file being replaced), and is then RE-HASHED through the gate's own
# reverse-scrub read path. A row whose deployed bytes do not hash back to the
# repo's canonical form is restored from its backup and this script exits
# non-zero. A push is not done until the detector agrees, and the whole run
# ends by re-running the detector over every row it touched. (Those `.presync-`
# files match none of the mirror's find filters — `*.rs`, `qemu-streamhost.sh`,
# `README.md|*.json|*.in` — so a backup can never invent a phantom pair.)
#
# usage: box-sync-push.sh [LABEL…] [--all-drift] [--apply] [--allow-dirty]
#                         [--no-post] [--lab HOST] [--list]
#   LABEL…         pair labels exactly as verify-box-sync.sh --table prints them
#   --all-drift    select every repo-authoritative row that needs attention
#   --apply        actually push (default: dry-run diff, touches nothing)
#   --allow-dirty  push a repo file with uncommitted changes (default: refuse —
#                  a half-edited file is not a thing to deploy)
#   --no-post      skip `systemctl daemon-reload` after a unit row lands
#   --list         print every row with its authority/mode/post and exit
# exit:  0 in sync — pushed, or nothing to do
#        1 a push failed re-verification (backup restored), or drift remains
#        2 usage, unknown label, or a refusal (box-authoritative, dirty repo
#          file, box-only file, broken pair)
#        3 box unreachable
#        4 scrub-unsafe: no usable registry/local.env, or a row declared exact
#          whose box copy holds a real value
# =============================================================================
set -uo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BOX_SYNC_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"

APPLY=0 ALL_DRIFT=0 ALLOW_DIRTY=0 DO_POST=1 LIST=0
declare -a WANT=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --all-drift) ALL_DRIFT=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --no-post) DO_POST=0 ;;
    --list) LIST=1 ;;
    --lab)
      [ "$#" -ge 2 ] || {
        echo "box-sync-push: --lab needs a host" >&2
        exit 2
      }
      LAB="$2"
      shift
      ;;
    -h | --help)
      sed -n '3,66p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "box-sync-push: unknown option: $1" >&2
      exit 2
      ;;
    *) WANT+=("$1") ;;
  esac
  shift
done

say() { printf 'box-sync-push: %s\n' "$*"; }
die() {
  printf 'box-sync-push: %s\n' "$2" >&2
  exit "$1"
}

# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/box-sync-pairs.sh"

tmpdir="$(mktemp -d)" || die 2 "could not create a temp dir"
trap 'rm -rf "$tmpdir"' EXIT

ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null ||
  die 3 "ssh $LAB unreachable — nothing was pushed"

box_sync_scrub_init "$REPO"
box_sync_load_pairs "$REPO" "$BOX_ROOT" "$LAB" "$tmpdir"
box_sync_darklaunch_load "$LAB" "$BOX_ROOT"

# Is an ACTIVE darklaunch declaration deployed over this row? Pushing repo->box
# would silently strip its overlaid rows, so an active declaration is a refusal
# in the write direction; the owner tool withdraws it, the push runs, and the
# owner re-publishes. A stale declaration (ids not actually present) does not
# block a push — the gate flags it DARKLAUNCH_STALE on its own.
dl_active() { # <index>
  local bf="${BOX_SYNC_BOX_FILES[$1]}"
  [ -n "${BOX_SYNC_DL_NAMES[$bf]:-}" ] || return 1
  case "${BOX_SYNC_DL_MD5[$bf]}" in ERROR:*) return 0 ;; esac
  [ "${BOX_SYNC_DL_FOUND[$bf]:-0}" -gt 0 ]
}

if [ "$LIST" = 1 ]; then
  printf '%-46s %-6s %-9s %s\n' PAIR MODE AUTHORITY POST
  for i in "${!BOX_SYNC_LABELS[@]}"; do
    printf '%-46s %-6s %-9s %s\n' "${BOX_SYNC_LABELS[$i]}" "${BOX_SYNC_MODES[$i]}" \
      "${BOX_SYNC_AUTHORITY[$i]}" "${BOX_SYNC_POST[$i]}"
  done
  exit 0
fi

[ "${#WANT[@]}" -gt 0 ] || [ "$ALL_DRIFT" = 1 ] ||
  die 2 "select rows by label, or --all-drift (see --list, or verify-box-sync.sh --table)"

# The write direction cannot run blind. Without the map there is no way to tell
# a scrubbed placeholder from a real value, and guessing is exactly the failure
# this script exists to make impossible.
[ "$BOX_SYNC_SCRUB_READY" = 1 ] || die 4 \
  "no usable registry/local.env — refusing to push ANY row.
  The gate may report scrubbed rows UNCHECKED; a writer may not, because
  without the substitution map a placeholder and a real value are the same
  bytes. Copy registry/local.env.example to registry/local.env and fill it in."

# --- current state: the gate's own hash pass, verbatim ---------------------
lines=()
for i in "${!BOX_SYNC_LABELS[@]}"; do
  lines+=("$(printf '%s\t%s' "${BOX_SYNC_MODES[$i]}" "${BOX_SYNC_BOX_FILES[$i]}")")
done
mapfile -t BOX_MD5 < <(printf '%s\n' "$BOX_SYNC_REVERSE_PROG" "${lines[@]}" |
  ssh -o ConnectTimeout=15 "$LAB" "$BOX_SYNC_REMOTE_HASH")
[ "${#BOX_MD5[@]}" -eq "${#BOX_SYNC_BOX_FILES[@]}" ] ||
  die 2 "incomplete remote hash response"

repo_hash() { # <index> -> the canonical repo-side hash, or MISSING
  local i="$1"
  local f="$REPO/${BOX_SYNC_REPO_FILES[$i]}"
  [ -f "$f" ] || {
    printf 'MISSING\n'
    return 0
  }
  if [ "${BOX_SYNC_MODES[$i]}" = scrub ]; then
    sed -e "$BOX_SYNC_CANON_PROG" -- "$f" | md5sum | awk '{print $1}'
  else
    md5sum -- "$f" | awk '{print $1}'
  fi
}

index_of() { # <label> -> index, or nothing
  local want="$1" i
  for i in "${!BOX_SYNC_LABELS[@]}"; do
    [ "${BOX_SYNC_LABELS[$i]}" = "$want" ] && {
      printf '%s\n' "$i"
      return 0
    }
  done
  return 1
}

# --- selection -------------------------------------------------------------
declare -a SEL=()
if [ "$ALL_DRIFT" = 1 ]; then
  for i in "${!BOX_SYNC_LABELS[@]}"; do
    [ "${BOX_SYNC_AUTHORITY[$i]}" = repo ] || continue
    r="$(repo_hash "$i")"
    [ "$r" = MISSING ] && continue
    [ "$r" = "${BOX_MD5[$i]}" ] && continue
    if dl_active "$i"; then
      bf="${BOX_SYNC_BOX_FILES[$i]}"
      if [ "${BOX_SYNC_DL_MD5[$bf]}" = "$(box_sync_canon_json_md5 "$REPO/${BOX_SYNC_REPO_FILES[$i]}")" ]; then
        say "darklaunched (${BOX_SYNC_DL_NAMES[$bf]}), in sync modulo the declaration — not selected: ${BOX_SYNC_LABELS[$i]}"
      else
        say "WARNING: ${BOX_SYNC_LABELS[$i]} differs BEYOND its darklaunch declaration (${BOX_SYNC_DL_NAMES[$bf]}) — resolve by hand; not selected"
      fi
      continue
    fi
    SEL+=("$i")
  done
  [ "${#SEL[@]}" -gt 0 ] || {
    say "no repo-authoritative row needs attention — nothing to do"
    exit 0
  }
fi
for label in "${WANT[@]:-}"; do
  [ -n "$label" ] || continue
  idx="$(index_of "$label")" || die 2 "unknown pair label: $label   (see --list)"
  SEL+=("$idx")
done

# --- refusals, decided BEFORE anything is written --------------------------
# One mis-declared row must stop the whole run: a partial push leaves labhost in
# a state no single verify run describes.
declare -a PUSH=() SKIP=()
refusals=0
for i in "${SEL[@]}"; do
  label="${BOX_SYNC_LABELS[$i]}"
  rel="${BOX_SYNC_REPO_FILES[$i]}"
  r="$(repo_hash "$i")"
  b="${BOX_MD5[$i]}"
  if [ "${BOX_SYNC_AUTHORITY[$i]}" != repo ]; then
    printf 'REFUSE %-40s the BOX is authoritative for this row (generated/live\n' "$label" >&2
    case "$rel" in
      build/registry/*)
        # Rendered from the registry: there is no repo copy to harvest INTO, so
        # harvest.sh is the wrong tool. Replacing the live document is a publish.
        printf '       %-40s artifact). Publish it with: scripts/serve-https-spa.sh manifests\n' '' >&2
        ;;
      *)
        printf '       %-40s artifact). Pull it with: scripts/dev/harvest.sh\n' '' >&2
        ;;
    esac
    refusals=$((refusals + 1))
    continue
  fi
  if [ "$r" = MISSING ] && [ "$b" = MISSING ]; then
    printf 'REFUSE %-40s absent on BOTH sides — the pair definition is wrong;\n' "$label" >&2
    printf '       %-40s fix or drop it in scripts/lib/box-sync-pairs.sh\n' '' >&2
    refusals=$((refusals + 1))
    continue
  fi
  if [ "$r" = MISSING ]; then
    printf 'REFUSE %-40s box-only (stale or scratch). Deleting it on the box or\n' "$label" >&2
    printf '       %-40s adopting it into the repo is a deliberate human call.\n' '' >&2
    refusals=$((refusals + 1))
    continue
  fi
  if [ "$r" = "$b" ]; then
    SKIP+=("$i")
    continue
  fi
  if dl_active "$i"; then
    printf 'REFUSE %-40s an active darklaunch overlay (%s) is deployed on this\n' \
      "$label" "${BOX_SYNC_DL_NAMES[${BOX_SYNC_BOX_FILES[$i]}]}" >&2
    printf '       %-40s row; pushing repo -> box would strip its overlaid rows.\n' '' >&2
    printf '       %-40s Withdraw it with its owner tool (see the declaration in\n' '' >&2
    printf '       %-40s serve/darklaunch.d), push, then re-publish it.\n' '' >&2
    refusals=$((refusals + 1))
    continue
  fi
  if [ "$ALLOW_DIRTY" = 0 ] &&
    [ -n "$(git -C "$REPO" status --porcelain --untracked-files=all -- "$rel" 2>/dev/null)" ]; then
    printf 'REFUSE %-40s the repo copy has uncommitted changes. Deploying a\n' "$label" >&2
    printf '       %-40s half-edited file is how the box gets a state no commit\n' '' >&2
    printf '       %-40s describes. Commit it, or pass --allow-dirty.\n' '' >&2
    refusals=$((refusals + 1))
    continue
  fi
  PUSH+=("$i")
done
[ "$refusals" -eq 0 ] || die 2 "$refusals row(s) refused — nothing was pushed"

# The scrub guard, and the reason it is a second pass: ask labhost to hash each
# selected `exact` row a SECOND time, through the reverse-scrub program. If that
# changes the hash, the labhost copy contains one of the operator's real values —
# so the row is deployed with substitution while declaring `exact`, and pushing
# the repo copy verbatim would write a placeholder over a live deployment. The
# real value is never named, fetched or printed; only the two hashes are.
declare -a EXACT_IDX=() exact_lines=()
for i in "${PUSH[@]:-}"; do
  [ -n "${i:-}" ] || continue
  [ "${BOX_SYNC_MODES[$i]}" = exact ] || continue
  [ "${BOX_MD5[$i]}" != MISSING ] || continue
  EXACT_IDX+=("$i")
  exact_lines+=("$(printf 'scrub\t%s' "${BOX_SYNC_BOX_FILES[$i]}")")
done
if [ "${#EXACT_IDX[@]}" -gt 0 ]; then
  mapfile -t EXACT_REV < <(printf '%s\n' "$BOX_SYNC_REVERSE_PROG" "${exact_lines[@]}" |
    ssh -o ConnectTimeout=15 "$LAB" "$BOX_SYNC_REMOTE_HASH")
  [ "${#EXACT_REV[@]}" -eq "${#EXACT_IDX[@]}" ] || die 2 "incomplete scrub-probe response"
  bad=0
  for n in "${!EXACT_IDX[@]}"; do
    i="${EXACT_IDX[$n]}"
    [ "${EXACT_REV[$n]}" = "${BOX_MD5[$i]}" ] && continue
    printf 'REFUSE %-40s declared exact, but the box copy holds a real value for\n' \
      "${BOX_SYNC_LABELS[$i]}" >&2
    printf '       %-40s one of: %s\n' '' "${BOX_SYNC_LIVE_PLACEHOLDERS[*]}" >&2
    printf '       %-40s Pushing it verbatim would write a placeholder over a live\n' '' >&2
    printf '       %-40s deployment. Declare the row scrub in\n' '' >&2
    printf '       %-40s scripts/lib/box-sync-pairs.sh first.\n' '' >&2
    bad=$((bad + 1))
  done
  [ "$bad" -eq 0 ] || die 4 "$bad mis-declared row(s) — nothing was pushed"
fi

for i in "${SKIP[@]:-}"; do
  [ -n "${i:-}" ] || continue
  say "already in sync, nothing to do: ${BOX_SYNC_LABELS[$i]}"
done
[ "${#PUSH[@]}" -gt 0 ] || {
  say "nothing to push"
  exit 0
}

# --- the diff: the gate's read path, so review == what is compared later ----
# stdin: reverse program, mode, path. Reverse-scrubbing happens ON labhost, so
# the operator's real values never reach a local file or this terminal.
# shellcheck disable=SC2016  # REMOTE script; $vars must reach labhost unexpanded
REMOTE_READ='
IFS= read -r SEDPROG
IFS= read -r MODE
IFS= read -r P
[ -f "$P" ] || exit 3
if [ "$MODE" = scrub ] && [ -n "$SEDPROG" ]; then sed -e "$SEDPROG" -- "$P"; else cat -- "$P"; fi
'
printf '\n'
for i in "${PUSH[@]}"; do
  label="${BOX_SYNC_LABELS[$i]}"
  printf -- '--- %s   repo -> box (%s)\n' "$label" "${BOX_SYNC_MODES[$i]}"
  printf -- '    repo: %s\n    box:  %s\n' "${BOX_SYNC_REPO_FILES[$i]}" "${BOX_SYNC_BOX_FILES[$i]}"
  sed -e "$BOX_SYNC_CANON_PROG" -- "$REPO/${BOX_SYNC_REPO_FILES[$i]}" >"$tmpdir/repo.$i"
  if printf '%s\n' "$BOX_SYNC_REVERSE_PROG" "${BOX_SYNC_MODES[$i]}" "${BOX_SYNC_BOX_FILES[$i]}" |
    ssh -o ConnectTimeout=15 "$LAB" "$REMOTE_READ" >"$tmpdir/box.$i" 2>/dev/null; then
    diff -u --label "box (${BOX_SYNC_BOX_FILES[$i]}, placeholder form)" \
      --label "repo (${BOX_SYNC_REPO_FILES[$i]})" "$tmpdir/box.$i" "$tmpdir/repo.$i" || true
  else
    printf '    CREATE — no file on the box yet\n'
  fi
  printf '\n'
done

if [ "$APPLY" = 0 ]; then
  say "dry-run: ${#PUSH[@]} row(s) would move repo -> box. Nothing was written."
  say "rerun with --apply to push, back up, re-hash and re-verify."
  exit 0
fi

# --- apply -----------------------------------------------------------------
# stdin: forward prog, reverse prog, the live placeholder list, mode, dest,
# expected canonical hash, stamp, mode-for-a-new-file, then the repo file's
# bytes. Both sed programs travel on stdin — never argv, never a local file,
# never printed. (The placeholders are placeholders; they are safe either way.)
#
# The placeholder sweep is NOT belt-and-braces, it is the half the round-trip
# hash cannot see: reverse-scrubbing a file that was never forward-substituted
# is a no-op, so an inert forward program produces a deployed file full of
# 192.0.2.10 that hashes back to the repo's canonical form PERFECTLY and passes
# re-verification. Asserting the substituted form carries no placeholder is the
# only independent evidence that the substitution actually happened — and it
# runs against the temp file, so a bad form is never installed at all.
# shellcheck disable=SC2016  # REMOTE script; $vars must reach labhost unexpanded
REMOTE_PUSH='
IFS= read -r FWD
IFS= read -r REV
IFS= read -r PHS
IFS= read -r MODE
IFS= read -r DEST
IFS= read -r WANT
IFS= read -r STAMP
IFS= read -r NEWMODE
tmp="$DEST.boxsync-tmp.$$"
if [ "$MODE" = scrub ]; then
  sed -e "$FWD" >"$tmp" || exit 5
  for ph in $PHS; do
    grep -qF -- "$ph" "$tmp" || continue
    rm -f -- "$tmp"
    printf "ERR forward substitution left %s in the deployed form; nothing written\n" "$ph"
    exit 5
  done
else
  cat >"$tmp" || exit 5
fi
bak=""
if [ -f "$DEST" ]; then
  bak="$DEST.presync-$STAMP"
  cp -a -- "$DEST" "$bak" || { rm -f -- "$tmp"; printf "ERR backup failed\n"; exit 5; }
  chmod --reference="$DEST" -- "$tmp" || { rm -f -- "$tmp"; printf "ERR chmod failed\n"; exit 5; }
else
  chmod "$NEWMODE" -- "$tmp" || { rm -f -- "$tmp"; printf "ERR chmod failed\n"; exit 5; }
fi
mv -f -- "$tmp" "$DEST" || { printf "ERR mv failed\n"; exit 5; }
if [ "$MODE" = scrub ] && [ -n "$REV" ]; then
  got=$(sed -e "$REV" -- "$DEST" | md5sum | awk "{print \$1}")
else
  got=$(md5sum -- "$DEST" | awk "{print \$1}")
fi
if [ "$got" = "$WANT" ]; then printf "OK %s\n" "${bak:--}"; exit 0; fi
if [ -n "$bak" ]; then
  cp -a -- "$bak" "$DEST"; printf "ROLLBACK %s restored-from %s\n" "$got" "$bak"
else
  rm -f -- "$DEST"; printf "ROLLBACK %s removed-there-was-no-prior-file\n" "$got"
fi
exit 1
'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
failed=0
declare -a BACKUPS=() PUSHED=() NEEDS_RELOAD=()
for i in "${PUSH[@]}"; do
  label="${BOX_SYNC_LABELS[$i]}"
  src="$REPO/${BOX_SYNC_REPO_FILES[$i]}"
  newmode="$(stat -c '%a' -- "$src")"
  out="$({
    printf '%s\n' "$BOX_SYNC_FORWARD_PROG" "$BOX_SYNC_REVERSE_PROG" \
      "${BOX_SYNC_LIVE_PLACEHOLDERS[*]}" \
      "${BOX_SYNC_MODES[$i]}" "${BOX_SYNC_BOX_FILES[$i]}" "$(repo_hash "$i")" \
      "$STAMP" "$newmode"
    cat -- "$src"
  } | ssh -o ConnectTimeout=30 "$LAB" "$REMOTE_PUSH")"
  case "$out" in
    OK*)
      say "pushed  $label   (backup: ${out#OK })"
      PUSHED+=("$i")
      [ "${out#OK }" = "-" ] || BACKUPS+=("${out#OK }")
      [ "${BOX_SYNC_POST[$i]}" = daemon-reload ] && NEEDS_RELOAD+=("$label")
      ;;
    *)
      printf 'box-sync-push: FAILED %s: %s\n' "$label" "$out" >&2
      failed=$((failed + 1))
      ;;
  esac
done

if [ "${#NEEDS_RELOAD[@]}" -gt 0 ] && [ "$DO_POST" = 1 ]; then
  if ssh -o ConnectTimeout=15 "$LAB" 'systemctl daemon-reload'; then
    say "systemctl daemon-reload (units: ${NEEDS_RELOAD[*]})"
  else
    say "WARNING: systemctl daemon-reload failed for: ${NEEDS_RELOAD[*]}"
    failed=$((failed + 1))
  fi
elif [ "${#NEEDS_RELOAD[@]}" -gt 0 ]; then
  say "--no-post: units changed but NOT reloaded: ${NEEDS_RELOAD[*]}"
fi

# --- re-verify: a push is not done until the detector agrees ---------------
printf '\n'
say "re-verifying through scripts/dev/verify-box-sync.sh …"
verify_out="$("$SCRIPT_DIR/verify-box-sync.sh" --table)"
verify_rc=$?
remaining=0
for i in "${PUSHED[@]:-}"; do
  [ -n "${i:-}" ] || continue
  label="${BOX_SYNC_LABELS[$i]}"
  row="$(printf '%s\n' "$verify_out" | awk -F'\t' -v l="$label" '$2==l {print $1}')"
  printf '  %-46s %s\n' "$label" "${row:-<row not found>}"
  [ "$row" = MATCH ] || remaining=$((remaining + 1))
done
if [ "${#BACKUPS[@]}" -gt 0 ]; then
  printf '\n'
  say "box-side backups kept (delete them once you are satisfied):"
  printf '    %s\n' "${BACKUPS[@]}"
fi

if [ "$failed" -gt 0 ] || [ "$remaining" -gt 0 ]; then
  die 1 "$failed push failure(s), $remaining row(s) still drifted"
fi
say "${#PUSHED[@]} row(s) pushed and re-verified MATCH (fleet gate exit $verify_rc)"
exit 0

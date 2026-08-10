#!/usr/bin/env bash
# verify-box-sync.sh — MD5-gate every documented repo/live box mirror.
#
# Placeholder awareness (the reason this gate can be green at all):
# this repo is scrubbed for public release — the operator's real LAN IP and
# public hostnames live ONLY in gitignored registry/local.env, and tracked
# files carry RFC 5737 / RFC 2606 placeholders instead (see AGENTS.md and
# registry/README.md). A handful of box copies are DEPLOYED with the real
# values substituted in, so a naive md5 compare marks them drifted forever.
# Those pairs are declared `scrub`: the box-side hash is taken AFTER reversing
# the substitution (real value -> repo placeholder), on the box, inside the one
# batched SSH session. Real values therefore never touch the wire in a hash,
# never land in a local temp file, and are never printed. With no
# registry/local.env (a fresh public clone) scrubbed pairs report UNCHECKED —
# they never silently pass and never spuriously fail.
#
# Usage: verify-box-sync.sh [--all] [--table]
#   (default)  only rows that need attention, grouped by kind, with counts
#   --all      every row, including MATCH
#   --table    machine-readable TSV: status<TAB>label<TAB>repo_md5<TAB>box_md5
# Exit 0 when nothing needs attention (UNCHECKED rows do not fail the gate).
set -euo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BOX_SYNC_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"

show_all=0 table=0
for arg in "$@"; do
  case "$arg" in
    --all) show_all=1 ;;
    --table) table=1 ;;
    -h | --help)
      printf 'usage: verify-box-sync.sh [--all] [--table]\n'
      printf '  (default)  only rows needing attention, grouped by kind\n'
      printf '  --all      every row, including MATCH\n'
      printf '  --table    TSV: status<TAB>label<TAB>repo_md5<TAB>box_md5\n'
      exit 0
      ;;
    *)
      printf 'verify-box-sync: unknown argument %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

declare -a LABELS=() REPO_FILES=() BOX_FILES=() MODES=()
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# --- scrub map -------------------------------------------------------------
# Built from registry/local.env via the shared helper. Only keys whose value
# actually differs from the repo placeholder contribute a rule; a local.env
# that still holds the placeholders is the same as having none.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/local-env.sh"

sed_prog=""
canon_prog=""
scrub_ready=0
add_rule() { # $1 local.env key, $2 its real value, $3 the repo placeholder
  local key="$1" real="$2" placeholder="$3" escaped
  # Canonicalisation, applied to BOTH sides of a scrub pair and containing only
  # placeholders: a tracked file may spell the value either bare (a unit's
  # `Environment=SIGNAL_HOST=192.0.2.10`) or as the local.env-aware fallback
  # `${KEY:-placeholder}` that resolves to it. Deploy substitution flattens both
  # to the same bare real value, so collapse the wrapper before comparing.
  canon_prog+="s/\\\${$key:-$(printf '%s' "$placeholder" | sed -e 's/[.]/\\./g')}/$placeholder/g;"
  [ -n "$real" ] || return 0
  [ "$real" != "$placeholder" ] || return 0
  # Escape regex metacharacters so a dotted IP matches literally.
  escaped="$(printf '%s' "$real" | sed -e 's/[][\.*^$/&]/\\&/g')"
  sed_prog+="s/$escaped/$placeholder/g;"
  scrub_ready=1
}
add_rule SH_HOST_IP "${SH_HOST_IP:-}" 192.0.2.10
add_rule SH_TUNNEL_HOST "${SH_TUNNEL_HOST:-}" tunnel.example.com
add_rule SH_GALLERY_HOST "${SH_GALLERY_HOST:-}" gallery.example.com
sed_prog+="$canon_prog"

# --- pair table ------------------------------------------------------------
# add_pair <label> <repo-relative path> <box absolute path> [scrub]
add_pair() {
  case "$1$2$3" in
    *uptoken* | *unifitoken* | *credentials.* | */pki/* | *.key*)
      printf 'verify-box-sync: refusing secret-like path\n' >&2
      exit 2
      ;;
  esac
  LABELS+=("$1") REPO_FILES+=("$2") BOX_FILES+=("$3")
  MODES+=("${4:-exact}")
}

# scripts/README.md "Box-sync pairs" (expanded to one byte pair per row).
add_pair labctl scripts/labctl /usr/local/bin/labctl
add_pair clone-guard scripts/lib/clone-guard.sh /usr/local/bin/clone-guard
add_pair xvfb-alloc scripts/lib/xvfb-alloc.sh /usr/local/bin/xvfb-alloc
add_pair chroot-guard scripts/lib/chroot-guard.sh /usr/local/bin/chroot-guard
add_pair gen-tiles-json scripts/gen_tiles_json.py /root/gen_tiles_json.py
for name in clientcmd.sh gen-local-ca.sh osgallery-https-server.py reset-tile.sh install-https-service.sh tiles.json golden-manifest.json; do
  add_pair "serve/$name" "scripts/serve/$name" "$BOX_ROOT/serve/$name"
done
# The serving plane is deployed WITH the operator's real host/gallery names
# substituted in (scripts/serve/restart-https.sh's SIGNAL_HOST default and the
# unit's SIGNAL_HOST/PUBLIC_HOST Environment= lines), so these three compare
# against the reverse-scrubbed box copy.
add_pair serve/restart-https.sh scripts/serve/restart-https.sh "$BOX_ROOT/serve/restart-https.sh" scrub
add_pair serve/osgallery-https.service scripts/serve/osgallery-https.service "$BOX_ROOT/serve/osgallery-https.service" scrub
# The HTTPS server's systemd supervisor: repo source must also match the INSTALLED
# unit (what actually runs + auto-starts on boot), like the streamhost/amiga units.
add_pair osgallery-https-unit scripts/serve/osgallery-https.service /etc/systemd/system/osgallery-https.service scrub
add_pair vm-idle-watch scripts/vm-idle-watch.sh "$BOX_ROOT/serve/vm-idle-watch.sh"
add_pair solaris-cdrv streamhost/guest-agents/solaris/cdrv.py /root/cdrv.py
add_pair solaris-gexec streamhost/guest-agents/solaris/gexec.py /root/gexec.py
add_pair irix-irixexec streamhost/guest-agents/irix/irixexec.py /root/irixexec.py
add_pair irix-mctl streamhost/guest-agents/irix/mctl.py /root/mctl.py
add_pair qmp-hmp scripts/qmp_hmp.py /root/qmp_hmp.py
add_pair shmshot scripts/shmshot.py /root/shmshot.py
add_pair mobile-netem scripts/dev/mobile-netem.sh /usr/local/bin/mobile-netem
add_pair amiga-coldboot-watch scripts/coldboot/amiga-coldboot-watch.sh /usr/local/bin/amiga-coldboot-watch.sh
add_pair streamhost-unit streamhost/deploy/streamhost@.service /etc/systemd/system/streamhost@.service
add_pair amiga-coldboot-unit streamhost/deploy/amiga-coldboot-watch.service /etc/systemd/system/amiga-coldboot-watch.service
add_pair sailfish-seriald-unit streamhost/deploy/seriald-sailfishos.service /etc/systemd/system/seriald-sailfishos.service
add_pair sailfish-seriald streamhost/tiles/sailfishos/seriald.py "$BOX_ROOT/tiles/sailfishos/seriald.py"

# The live labctl matrix is harvested into the committed reference sample.
add_pair tiles-json scripts/tiles.json.sample "$BOX_ROOT/tiles.json"

# build-deploy.sh's workspace/source mirror, expanded file-by-file.
add_pair streamhost/Cargo.toml streamhost/Cargo.toml "$BOX_ROOT/build/Cargo.toml"
add_pair streamhost/Cargo.lock streamhost/Cargo.lock "$BOX_ROOT/build/Cargo.lock"
add_pair streamhost/member-Cargo.toml streamhost/streamhost/Cargo.toml "$BOX_ROOT/build/streamhost/Cargo.toml"
git -C "$REPO" ls-files 'streamhost/streamhost/src/**' |
  sed 's#^streamhost/streamhost/src/##' | sort >"$tmpdir/src-repo"
ssh -o ConnectTimeout=15 "$LAB" \
  "find '$BOX_ROOT/build/streamhost/src' -type f -name '*.rs' -printf '%P\\n' | sort" \
  >"$tmpdir/src-box"
sort -u "$tmpdir/src-repo" "$tmpdir/src-box" >"$tmpdir/src-union"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  add_pair "src/$rel" "streamhost/streamhost/src/$rel" "$BOX_ROOT/build/streamhost/src/$rel"
done <"$tmpdir/src-union"

# Only verbatim, tracked launchers of LIVE tiles are box-authored mirror pairs.
# Generic launchers are checked by verify-emit.sh; the tracked soltest-*
# launchers are clone/experiment scaffolds that run out of /data/vms/soltest/,
# never out of $BOX_ROOT/tiles, so they have no box counterpart by design.
while IFS= read -r path; do
  rel="${path#streamhost/tiles/}"
  case "$rel" in soltest-*) continue ;; esac
  add_pair "launcher/$rel" "$path" "$BOX_ROOT/tiles/$rel"
done < <(git -C "$REPO" ls-files 'streamhost/tiles/*/qemu-streamhost.sh' | sort)

# Registry tree union: box-only and repo-only allowed files must be visible as
# MISSING rather than silently omitted. "Allowed source files" is the same
# filter on BOTH sides (README.md, *.json, *.in, minus registry/posters/) — the
# poster prose and its image-candidate research feed the SPA build only, and the
# gitignored local.env is operator-local; neither is part of the box mirror.
git -C "$REPO" ls-files 'registry/**' | sed 's#^registry/##' |
  grep -E '(^|/)README\.md$|\.json$|\.in$' | grep -v '^posters/' | sort >"$tmpdir/registry-repo"
ssh -o ConnectTimeout=15 "$LAB" \
  "find '$BOX_ROOT/build/registry' -path '$BOX_ROOT/build/registry/posters' -prune -o -type f \\( -name README.md -o -name '*.json' -o -name '*.in' \\) -printf '%P\\n' | sort" \
  >"$tmpdir/registry-box"
sort -u "$tmpdir/registry-repo" "$tmpdir/registry-box" >"$tmpdir/registry-union"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  add_pair "registry/$rel" "registry/$rel" "$BOX_ROOT/build/registry/$rel"
done <"$tmpdir/registry-union"

# --- one batched remote hash pass ------------------------------------------
# Paths are fixed by this script or restricted find output; file contents are
# never printed. The scrub program travels on stdin (line 1), so the operator's
# real values stay out of argv, out of local files, and out of the output.
# shellcheck disable=SC2016  # this is the REMOTE script; $vars must reach the box unexpanded
remote_script='
IFS= read -r SEDPROG
while IFS="	" read -r mode path; do
  if [ ! -f "$path" ]; then printf "MISSING\n"; continue; fi
  if [ "$mode" = scrub ] && [ -n "$SEDPROG" ]; then
    sed -e "$SEDPROG" -- "$path" | md5sum | awk "{print \$1}"
  else
    md5sum -- "$path" | awk "{print \$1}"
  fi
done
'
lines=()
for i in "${!LABELS[@]}"; do
  mode="${MODES[$i]}"
  [ "$mode" = scrub ] && [ "$scrub_ready" = 0 ] && mode=skip
  lines+=("$(printf '%s\t%s' "$mode" "${BOX_FILES[$i]}")")
done
mapfile -t BOX_MD5 < <(printf '%s\n' "$sed_prog" "${lines[@]}" | ssh -o ConnectTimeout=15 "$LAB" "$remote_script")

[ "${#BOX_MD5[@]}" -eq "${#BOX_FILES[@]}" ] || {
  printf 'verify-box-sync: incomplete remote hash response\n' >&2
  exit 2
}

# --- classify --------------------------------------------------------------
declare -a ROWS=()
match=0 unchecked=0
declare -A KIND_COUNT=()
for i in "${!LABELS[@]}"; do
  if [ ! -f "$REPO/${REPO_FILES[$i]}" ]; then
    repo_md5=MISSING
  elif [ "${MODES[$i]}" = scrub ]; then
    repo_md5="$(sed -e "$canon_prog" -- "$REPO/${REPO_FILES[$i]}" | md5sum | awk '{print $1}')"
  else
    repo_md5="$(md5sum -- "$REPO/${REPO_FILES[$i]}" | awk '{print $1}')"
  fi
  box_md5="${BOX_MD5[$i]}"
  if [ "${MODES[$i]}" = scrub ] && [ "$scrub_ready" = 0 ]; then
    status='UNCHECKED (no local.env)'
    unchecked=$((unchecked + 1))
  elif [ "$repo_md5" = MISSING ] && [ "$box_md5" = MISSING ]; then
    status=MISSING_BOTH
  elif [ "$repo_md5" = MISSING ]; then
    status=MISSING_IN_REPO
  elif [ "$box_md5" = MISSING ]; then
    status=MISSING_ON_BOX
  elif [ "$repo_md5" = "$box_md5" ]; then
    status=MATCH
    match=$((match + 1))
  else
    status=DIFFERS
  fi
  ROWS+=("$(printf '%s\t%s\t%s\t%s' "$status" "${LABELS[$i]}" "$repo_md5" "$box_md5")")
  case "$status" in MATCH | UNCHECKED*) ;; *) KIND_COUNT["$status"]=$((${KIND_COUNT["$status"]:-0} + 1)) ;; esac
done

drift=0
for k in "${!KIND_COUNT[@]}"; do drift=$((drift + KIND_COUNT[$k])); done
total="${#LABELS[@]}"

if [ "$table" = 1 ]; then
  printf '%s\n' "${ROWS[@]}"
  [ "$drift" -eq 0 ] && exit 0
  exit 1
fi

print_group() { # $1 status, $2 heading
  local n="${KIND_COUNT[$1]:-0}" row
  [ "$n" -gt 0 ] || return 0
  printf '\n%s (%d)\n  %s\n' "$1" "$n" "$2"
  for row in "${ROWS[@]}"; do
    case "$row" in "$1"$'\t'*) printf '    %s\n' "$(printf '%s' "$row" | cut -f2)" ;; esac
  done
}

if [ "$show_all" = 1 ]; then
  printf '%-46s %-34s %-34s %s\n' PAIR REPO_MD5 BOX_MD5 STATUS
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r st lb rm bm <<<"$row"
    printf '%-46s %-34s %-34s %s\n' "$lb" "$rm" "$bm" "$st"
  done
fi

print_group DIFFERS 'content differs — decide which side is authoritative, then sync that way'
print_group MISSING_ON_BOX 'in the repo, never mirrored to the box — deploy it, or drop the pair'
print_group MISSING_IN_REPO 'box-only (stale or scratch) — delete on the box, or adopt deliberately'
print_group MISSING_BOTH 'the pair definition itself is wrong or obsolete — fix the path or drop it'

if [ "$unchecked" -gt 0 ]; then
  printf '\nUNCHECKED (%d)\n  scrubbed pairs need registry/local.env to reverse the substitution;\n  copy registry/local.env.example and fill it in to check these.\n' "$unchecked"
fi

printf '\nsummary: %d MATCH, %d need attention, %d unchecked, %d pairs\n' \
  "$match" "$drift" "$unchecked" "$total"
[ "$drift" -eq 0 ] || printf 'remediation: scripts/dev/verify-box-sync.sh --all   (full table)\n'
[ "$drift" -eq 0 ]

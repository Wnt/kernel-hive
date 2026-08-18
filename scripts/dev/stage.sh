#!/usr/bin/env bash
# stage.sh — a per-session STAGING slot on the live origin, from THIS checkout.
#
#   https://<lab>:8443/staging/<KH_SESSION>/      the UI, built from this tree
#                                                 with vite base=/staging/<s>/,
#                                                 plus gallery-manifest.json and
#                                                 poster-docs.json rendered from
#                                                 THIS tree's registry
#
# WHY. Poster copy, lineup order, SPA changes and new registry entries went
# live on first deploy and were reviewed afterwards (2–3 redeploy loops for a
# wording trim), and "dark launches" were an overlay ledger on top of the live
# manifests that clobbered and got clobbered (docs/lab/research/
# workflow-friction-2026-08.md items 1 and 6). A staging slot is the same
# origin, same passkeys, same stations, same server — only the UI bundle and
# the two runtime documents come from the session's own tree. Review it from a
# phone; promote by landing the branch on main and running box-deploy.sh.
#
# Stations: a staged UI talks to the LIVE stations by id (/signal/<id>.json).
# A station that exists only in this tree's registry shows in the staged grid
# and reports offline until it is deployed — that is the point.
# `stage.sh station <id>` scaffolds a sandbox instance of a live station's dir
# for launcher/env experiments (see its help); it is a scaffold, not magic:
# every station family has its own device set and the scaffold says what it
# could not derive.
#
# usage:
#   stage.sh [ui] [--name N] [--no-build]   build + render + install; prints URL
#   stage.sh ls                             every staging slot, owner, age
#   stage.sh rm [N]                         remove the slot (default: this session)
#   stage.sh station <id> [--name N]        scaffold sandbox/<N>/stations/<id>/
# env: KH_SESSION (scripts/lib/kh-session.sh), LAB
# exit: 0 · 1 failed · 2 usage
set -uo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"
WEBROOT="$BOX_ROOT/serve/webroot"
SANDBOX="${KH_SANDBOX_ROOT:-/data/vms/sandbox}"
LABRUN="$SCRIPT_DIR/labrun"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/kh-session.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/local-env.sh" 2>/dev/null || true
HOST_SHOWN="${SH_HOST_IP:-192.0.2.10}"

die() {
  echo "stage.sh: $*" >&2
  exit 1
}
usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

cmd_ui() {
  local name="$KH_SESSION" build=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name)
        name="$2"
        shift
        ;;
      --no-build) build=0 ;;
      *) usage 2 ;;
    esac
    shift
  done
  [ "$name" != main ] || die "refusing to stage as 'main' — set KH_SESSION or use wt.sh"
  local base="/staging/$name/" out="$WEBROOT/staging/$name"

  # the slot is a claim: two sessions cannot both hold /staging/<name>/
  "$LABRUN" -- "$name" "$REPO" <<'EOF' || die "staging/$name is held by another session (kh-claim ls)"
export KH_SESSION="$1"
kh-claim take staging "$1" --purpose "stage.sh ui from $2"
EOF

  if [ "$build" = 1 ]; then
    echo "stage.sh: building UI with base $base"
    (cd "$REPO/spa" && VITE_BASE="$base" npm run build --silent) || die "npm run build failed"
  fi
  [ -f "$REPO/spa/dist/index.html" ] || die "no spa/dist — build first"
  python3 "$REPO/scripts/stations-registry.py" render --out "$REPO/build/registry" >/dev/null ||
    die "registry render failed (registry does not validate)"

  local pack="$REPO/build/staging-$name.tar"
  tar -C "$REPO/spa/dist" -cf "$pack" . || die "tar failed"
  tar -C "$REPO/build/registry" -rf "$pack" gallery-manifest.json poster-docs.json fleet-table.json || die "tar manifests failed"
  printf 'session=%s\nsha=%s\nbranch=%s\nwhen=%s\n' "$name" "$(git -C "$REPO" rev-parse --short HEAD)" \
    "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$REPO/build/.staged-rev"
  tar -C "$REPO/build" -rf "$pack" .staged-rev
  # install atomically: ship the pack, unpack beside the slot, swap
  local rpack="/run/kh-stage-$name.tar"
  scp -q "$pack" "$LAB:$rpack" || die "scp failed"
  "$LABRUN" -- "$out" "$rpack" <<'EOS' 2>&1 || die "install failed"
out="$1" pack="$2" tmp="$1.new.$$"
rm -rf "$tmp"; mkdir -p "$tmp" && tar -C "$tmp" -xf "$pack" && chmod -R a+rX "$tmp" &&
  { [ ! -e "$out" ] || rm -rf "$out.old"; [ ! -e "$out" ] || mv "$out" "$out.old"; } &&
  mv "$tmp" "$out" && rm -rf "$out.old" "$pack" && echo "installed $out"
EOS
  rm -f "$pack"
  echo "stage.sh: staged  https://$HOST_SHOWN:8443$base   ($(git -C "$REPO" rev-parse --short HEAD), $name)"
  echo "          promote: land the branch on main, then scripts/dev/box-deploy.sh --apply (+ serve-https-spa.sh deploy for the UI bundle)"
}

cmd_ls() {
  "$LABRUN" -- "$WEBROOT/staging" <<'EOF'
d="$1"; [ -d "$d" ] || { echo "no staging slots"; exit 0; }
printf '%-24s %-10s %-22s %s\n' SLOT SHA BRANCH WHEN
for s in "$d"/*/; do
  s="${s%/}"; [ -f "$s/.staged-rev" ] || continue
  . "$s/.staged-rev"
  printf '%-24s %-10s %-22s %s  %s\n' "$(basename "$s")" "$sha" "$branch" "$when" "$(kh-claim who staging "$(basename "$s")" 2>/dev/null)"
done
EOF
}

cmd_rm() {
  local name="${1:-$KH_SESSION}"
  "$LABRUN" -- "$WEBROOT/staging/$name" "$name" <<'EOF'
export KH_SESSION="$2"
rm -rf "$1" && kh-claim release staging "$2" --force >/dev/null 2>&1; echo "removed staging/$2"
EOF
}

# --- station scaffold ---------------------------------------------------------
# Copies the LIVE station dir's launcher + station.env into the session sandbox
# with the two things every clone needs rewritten: the station path and the
# station identity. Disks are NOT copied here (some are tens of GB and several
# families keep the checkpoint in a sidecar) — the scaffold prints the disk
# facts from `labctl facts` and the clone-guard rules, and stops. Launching is
# `clone-guard`-mediated and yours.
cmd_station() {
  local station="${1:-}" name="$KH_SESSION"
  [ -n "$station" ] || usage 2
  shift
  [ "${1:-}" = "--name" ] && name="$2"
  local dst="$SANDBOX/$name/stations/$station"
  "$LABRUN" -- "$station" "$name" "$dst" "$BOX_ROOT" <<'EOF'
station="$1" name="$2" dst="$3" root="$4"
export KH_SESSION="$name"
src="$root/stations/$station"
[ -d "$src" ] || { echo "no live station dir $src" >&2; exit 1; }
kh-claim take sandbox "$name" --purpose "stage.sh station $station" >/dev/null || exit 1
[ -e "$dst" ] && { echo "$dst exists — refuse to overwrite" >&2; exit 1; }
install -d -m 2775 -o 1000 -g 1000 "$dst"
for f in qemu-streamhost.sh x11-runtime.sh station.env tile.env; do
  [ -f "$src/$f" ] || continue
  sed -e "s#$src#$dst#g" -e "s#^SH_STATION=.*#SH_STATION=stg-$name-$station#" "$src/$f" >"$dst/$f"
  chmod --reference="$src/$f" "$dst/$f"
done
echo "scaffolded $dst  (SH_STATION=stg-$name-$station; paths rewritten $src -> $dst)"
echo "NOT copied: disks / checkpoints / sockets / ports. Facts:"
labctl facts "$station" 2>/dev/null | grep -Ei 'disk|backing|snapshot|golden|port|kind' | head -12 || true
echo "next: pick fresh ports + VMID in $dst/station.env, copy the disk(s) named above (same device set for loadvm golden),"
echo "      launch under clone-guard, prove it with labctl shot. Kill only through clone-guard."
EOF
}

case "${1:-ui}" in
  ui)
    shift
    cmd_ui "$@"
    ;;
  --name | --no-build) cmd_ui "$@" ;;
  ls) cmd_ls ;;
  rm)
    shift
    cmd_rm "$@"
    ;;
  station)
    shift
    cmd_station "$@"
    ;;
  -h | --help | help) usage 0 ;;
  *) usage 2 ;;
esac

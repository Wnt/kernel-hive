#!/usr/bin/env bash
# verify-box-sync.sh — MD5-gate every documented repo/live box mirror.
set -euo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BOX_SYNC_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"

declare -a LABELS=() REPO_FILES=() BOX_FILES=()
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

add_pair() {
  case "$1$2$3" in
    *uptoken* | *unifitoken* | *credentials.md* | *credentials.ts* | */pki/* | *.key*)
      printf 'verify-box-sync: refusing secret-like path\n' >&2
      exit 2
      ;;
  esac
  LABELS+=("$1") REPO_FILES+=("$2") BOX_FILES+=("$3")
}

# scripts/README.md "Box-sync pairs" (expanded to one byte pair per row).
add_pair labctl scripts/labctl /usr/local/bin/labctl
add_pair clone-guard scripts/lib/clone-guard.sh /usr/local/bin/clone-guard
add_pair xvfb-alloc scripts/lib/xvfb-alloc.sh /usr/local/bin/xvfb-alloc
add_pair gen-tiles-json scripts/gen_tiles_json.py /root/gen_tiles_json.py
for name in clientcmd.sh gen-local-ca.sh osgallery-https-server.py reset-tile.sh restart-https.sh install-https-service.sh osgallery-https.service tiles.json golden-manifest.json; do
  add_pair "serve/$name" "scripts/serve/$name" "$BOX_ROOT/serve/$name"
done
# The HTTPS server's systemd supervisor: repo source must also match the INSTALLED
# unit (what actually runs + auto-starts on boot), like the streamhost/amiga units.
add_pair osgallery-https-unit scripts/serve/osgallery-https.service /etc/systemd/system/osgallery-https.service
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
for tile in freedos msdoswin1 qnx; do
  add_pair "relfix/$tile" streamhost/deploy/relfix/relfix.conf "/etc/systemd/system/streamhost@$tile.service.d/relfix.conf"
done
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

# Only verbatim, tracked launchers are box-authored mirror pairs. Generic
# launchers are checked by verify-emit.sh instead.
while IFS= read -r path; do
  rel="${path#streamhost/tiles/}"
  add_pair "launcher/$rel" "$path" "$BOX_ROOT/tiles/$rel"
done < <(git -C "$REPO" ls-files 'streamhost/tiles/*/qemu-streamhost.sh' | sort)

# Registry tree union: box-only and repo-only allowed files must be visible as
# MISSING/DRIFT rather than silently omitted.
git -C "$REPO" ls-files 'registry/**' | sed 's#^registry/##' | sort >"$tmpdir/registry-repo"
ssh -o ConnectTimeout=15 "$LAB" \
  "find '$BOX_ROOT/build/registry' -type f \\( -name README.md -o -name '*.json' -o -name '*.in' \\) -printf '%P\\n' | sort" \
  >"$tmpdir/registry-box"
sort -u "$tmpdir/registry-repo" "$tmpdir/registry-box" >"$tmpdir/registry-union"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  add_pair "registry/$rel" "registry/$rel" "$BOX_ROOT/build/registry/$rel"
done <"$tmpdir/registry-union"

# Batch all remote hashes through one read-only SSH session. Paths are fixed by
# this script or restricted find output; file contents are never printed.
printf '%s\n' "${BOX_FILES[@]}" >"$tmpdir/box-paths"
mapfile -t BOX_MD5 < <(ssh -o ConnectTimeout=15 "$LAB" '
while IFS= read -r path; do
  if [ -f "$path" ]; then md5sum -- "$path" | awk "{print \$1}"
  else printf "MISSING\n"
  fi
done
' <"$tmpdir/box-paths")

[ "${#BOX_MD5[@]}" -eq "${#BOX_FILES[@]}" ] || {
  printf 'verify-box-sync: incomplete remote hash response\n' >&2
  exit 2
}

printf '%-48s %-32s %-32s %s\n' PAIR REPO_MD5 BOX_MD5 STATUS
printf '%-48s %-32s %-32s %s\n' '------------------------------------------------' '--------------------------------' '--------------------------------' '------'
drift=0 match=0
for i in "${!LABELS[@]}"; do
  if [ -f "$REPO/${REPO_FILES[$i]}" ]; then
    repo_md5="$(md5sum -- "$REPO/${REPO_FILES[$i]}" | awk '{print $1}')"
  else
    repo_md5=MISSING
  fi
  box_md5="${BOX_MD5[$i]}"
  if [ "$repo_md5" = "$box_md5" ] && [ "$repo_md5" != MISSING ]; then
    status=MATCH
    match=$((match + 1))
  else
    status=DRIFT
    drift=$((drift + 1))
  fi
  printf '%-48s %-32s %-32s %s\n' "${LABELS[$i]}" "$repo_md5" "$box_md5" "$status"
done
printf '\nsummary: %d MATCH, %d DRIFT, %d pairs\n' "$match" "$drift" "$((match + drift))"
[ "$drift" -eq 0 ]

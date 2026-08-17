#!/usr/bin/env bash
# Track A phase 1: acquire the IRIX 6.5.22 app/demo media named by
# https://sgi.neocities.org/installguide from jrra.zone (public SGI CD archive).
# Namespaced: everything lands in /data/vms/sandbox/irix-apps/media.
set -uo pipefail

MEDIA="${IRIX_APPS_MEDIA:-/data/vms/sandbox/irix-apps/media}"
BASE="https://jrra.zone/sgi/cds"
mkdir -p "$MEDIA"

# local-name<TAB>remote-name
MAP=$(
  cat <<'EOF'
found1.iso	IRIX 6.5 Foundation 1.iso
found2.iso	IRIX 6.5 Foundation 2.iso
ovl1.iso	IRIX 6.5.22 Installation Tools and Overlays (1 of 3).iso
ovl2.iso	IRIX 6.5.22 Overlays (2 of 3).iso
ovl3.iso	IRIX 6.5.22 Overlays (3 of 3).iso
apps2003.iso	IRIX 6.5 Applications November 2003.iso
nfs3.iso	ONC3 NFS Version 3.iso
demos1.iso	Silicon Graphics General and Platform Demos 6.5.12 (1 of 2).iso
demos2.iso	Silicon Graphics General and Platform Demos 6.5.12 (2 of 2).iso
EOF
)

urlenc() { python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

rc=0
while IFS=$'\t' read -r local remote; do
  [ -n "$local" ] || continue
  out="$MEDIA/$local"
  url="$BASE/$(urlenc "$remote")"
  echo "== $local <- $remote"
  if ! curl -fL --retry 5 --retry-delay 5 -C - --connect-timeout 30 -o "$out" "$url"; then
    echo "FAILED: $local ($url)" >&2
    rc=1
    continue
  fi
  # SGI install CDs are EFS volumes behind an SGI disk label, NOT ISO9660:
  # sanity-check the 0x0BE5A941 volume-header magic instead.
  magic=$(od -An -tx4 -N4 "$out" | tr -d ' ')
  [ "$magic" = "0be5a941" ] || {
    echo "NOT-AN-SGI-CD: $local (magic $magic)" >&2
    rc=1
  }
done <<<"$MAP"

(cd "$MEDIA" && sha256sum ./*.iso >SHA256SUMS && ls -l)
exit "$rc"

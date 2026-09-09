#!/bin/bash
# tiles/medley.sh — stage Interlisp Medley for the host-native `medley` station.
#
# There is no guest disk to build: Medley is a Lisp environment whose "image"
# is a sysout file, and maiko is a Linux binary that renders it into an X
# window. The builder pins one upstream release, verifies it byte-for-byte,
# unpacks it into the station's asset tree, and proves on a framebuffer that
# the Exec comes up under a throwaway Xvfb.
#
# Upstream: github.com/Interlisp/medley (MIT). The full linux x86_64 tarball
# bundles medley/ (loadups, greetfiles, library, fonts) and maiko/ (lde, ldex).
# Run FROM CT950 (fetches over the WAN); the boot proof runs on labhost via
# labrun because CT950 has no Xvfb.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABRUN="$HERE/../../dev/labrun"
OS_ID="medley"
REL="medley-260826-3a14c9aa_260319-9259716e"
TGZ="medley-full-linux-x86_64-${REL#medley-}.tgz"
URL="https://github.com/Interlisp/medley/releases/download/${REL}/${TGZ}"
SHA="9e163aaf87a30f0e14e721826172d22c680153bab597c57ef20f39bea3736f76"
SIZE=185512952
ASSETS="${MEDLEY_ASSETS:-/data/vms/streamhost/assets/medley}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$WORK"
if [ ! -f "$WORK/$TGZ" ] || [ "$(stat -c %s "$WORK/$TGZ")" != "$SIZE" ]; then
  log "fetching $URL"
  curl -fsSL -o "$WORK/$TGZ.part" "$URL"
  mv "$WORK/$TGZ.part" "$WORK/$TGZ"
fi
echo "$SHA  $WORK/$TGZ" | sha256sum -c - >/dev/null || die "sha256 mismatch on $TGZ"
log "verified $TGZ ($SIZE bytes)"

# Atomic stage on labhost (the asset tree is root-owned there and a different
# mount inside CT950): unpack beside, then swap the trees in. Then the
# framebuffer proof: boot the sysout on a throwaway Xvfb and require the
# Medley window to be mapped within 20 s. The display is allocated, never
# picked (scripts/lib/xvfb-alloc.sh); everything is killed by pidfile.
"$LABRUN" <<EOF
umask 022
set -u
STAGE="$ASSETS.staging.\$\$"
rm -rf "\$STAGE"; mkdir -p "\$STAGE"
tar xzf "$WORK/$TGZ" -C "\$STAGE"
[ -x "\$STAGE/maiko/linux.x86_64/ldex" ] || { echo "no ldex in the tarball" >&2; exit 1; }
[ -f "\$STAGE/medley/loadups/full.sysout" ] || { echo "no full.sysout in the tarball" >&2; exit 1; }
mkdir -p "$ASSETS"
rm -rf "$ASSETS/medley" "$ASSETS/maiko" "$ASSETS/notecards"
mv "\$STAGE/medley" "\$STAGE/maiko" "$ASSETS/"
[ -d "\$STAGE/notecards" ] && mv "\$STAGE/notecards" "$ASSETS/"
rm -rf "\$STAGE"
printf '%s  %s\n' "$SHA" "$TGZ" > "$ASSETS/MANIFEST.sha256"
chmod -R a+rX "$ASSETS"
echo "medley: staged $ASSETS/{medley,maiko}"
P=/tmp/medley-build-proof.\$\$
mkdir -p "\$P"; cd "\$P"
source /usr/local/bin/xvfb-alloc
xvfb_alloc --screen 1024x768x24 --pidfile "\$P/xvfb.pid"
export DISPLAY="\$XVFB_DISPLAY" MEDLEYDIR="$ASSETS/medley" HOME="\$P" LOGINDIR="\$P"
export LDEDESTSYSOUT="\$P/lisp.virtualmem" LDEINIT="$ASSETS/medley/greetfiles/MEDLEYDIR-INIT" LDEKBDTYPE=X LDESRCESYSOUT="$ASSETS/medley/loadups/full.sysout"
"$ASSETS/maiko/linux.x86_64/ldex" -display "\$DISPLAY" -noscroll -g 1024x768 -sc 1024x768 -title "Medley Interlisp" -m 256 \
  "$ASSETS/medley/loadups/full.sysout" >"\$P/maiko.log" 2>&1 &
echo \$! > "\$P/maiko.pid"
ok=0
for i in \$(seq 1 40); do
  sleep 0.5
  if xwininfo -root -tree -display "\$DISPLAY" 2>/dev/null | grep -q "Medley Interlisp"; then ok=1; break; fi
done
sleep 2
xwd -root -silent -display "\$DISPLAY" > "\$P/frame.xwd" && convert "\$P/frame.xwd" "$WORK/proof.png"
kill -9 "\$(cat "\$P/maiko.pid")" 2>/dev/null || true
xvfb_release
rm -rf "\$P"
[ "\$ok" = 1 ] || { echo "medley: no Medley window within 20 s" >&2; exit 1; }
echo "medley: Medley window mapped; frame at $WORK/proof.png"
EOF
log "done — proof frame $WORK/proof.png"

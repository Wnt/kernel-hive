#!/bin/bash
# tiles/mvs38.sh — build the `mvs38` station: IBM MVS 3.8j under Hercules.
#
# There is no QEMU guest, no compiler and no checkpoint here. Like
# medley/lisa/perq/vision/vax43bsd this is a host application in a container and
# reset = relaunch, so the builder's whole job is to produce two inert artifacts:
#
#   tk5/      the TK5 turnkey distribution of MVS 3.8j, unpacked and EXECUTABLE
#   rootfs/   the Debian tree the station container runs inside
#
# Nothing is built from source. TK5 ships its own SDL Hyperion Hercules for
# linux/64 and the MVS system is a set of pre-built DASD volumes, so the
# upstream zip IS the artifact and is pinned by byte size and SHA-256 below.
#
# Run FROM CT950 (it fetches over the WAN); every labhost step goes through
# scripts/dev/labrun. See docs/lab/MVS38-WAVE.md for the measured facts, the
# device set, and what is still OPEN.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABRUN="$HERE/../../dev/labrun"
OS_ID="mvs38"

ASSETS="${MVS38_ASSETS:-/data/vms/streamhost/assets/$OS_ID}"
STAGING="${MVS38_STAGING:-/data/assets-staging/$OS_ID}"
WORK="${WORK:-/data/vms/build-$OS_ID}"
ROOTFS="${MVS38_ROOTFS:-$ASSETS/rootfs}"
# 32*65536. Must be clear of the CT subuid range (100000+) and of every other
# contained station: medley 1966080, indyr4400 2031616, its 2424832,
# vax43bsd 2490368. Two nspawn stations sharing one uid range would give away
# the isolation the HOST-APP-CONTAINER-CONTRACT exists to provide.
UIDBASE="${MVS38_UIDBASE:-2097152}"

# TK5 by Rob Prins. `mvstk5-update5.zip` is NOT needed: the base archive's own
# banner already reads "TK5 ... Update 5", i.e. the base zip IS update 5.
TK5_URL="${TK5_URL:-https://www.prince-webdesign.nl/images/downloads/mvs-tk5.zip}"
TK5_ZIP="mvs-tk5.zip"
TK5_BYTES=498312872
TK5_SHA=710d002843631322810a276dd42c793fda458548dc64d86e2914a62db7425f84

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }

usage() {
  cat >&2 <<EOF
usage: $0 [--media] [--tk5] [--rootfs] [--secret] [--all]
  --media   fetch and hash the pinned TK5 zip into $STAGING
  --tk5     unpack it into $ASSETS/tk5 and restore the exec bits
  --rootfs  debootstrap the container tree and shift it to uid $UIDBASE
  --secret  write \$MVS38_TSO_PASS to $ASSETS/tso.pass (box-local, never committed)
  --all     all of the above, in order (default)
EOF
  exit 2
}

do_media=0 do_tk5=0 do_rootfs=0 do_secret=0
if [ $# -eq 0 ]; then
  do_media=1 do_tk5=1 do_rootfs=1 do_secret=1
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --media) do_media=1 ;;
    --tk5) do_tk5=1 ;;
    --rootfs) do_rootfs=1 ;;
    --secret) do_secret=1 ;;
    --all) do_media=1 do_tk5=1 do_rootfs=1 do_secret=1 ;;
    *) usage ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# 1. media — the pinned upstream zip
# --------------------------------------------------------------------------
if [ "$do_media" = 1 ]; then
  log "staging TK5 from $TK5_URL"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
mkdir -p "$STAGING"
cd "$STAGING"
[ -s "$TK5_ZIP" ] || curl -fsSL -o "$TK5_ZIP" "$TK5_URL"
got="\$(stat -c %s "$TK5_ZIP")"
[ "\$got" = "$TK5_BYTES" ] || { echo "$TK5_ZIP: \$got bytes, expected $TK5_BYTES" >&2; exit 1; }
echo "$TK5_SHA  $TK5_ZIP" | sha256sum -c - >/dev/null
mkdir -p "$ASSETS"
echo "$TK5_SHA  $TK5_ZIP" > "$ASSETS/MANIFEST.sha256"
echo "TK5 staged and pinned in $STAGING"
EOF
fi

# --------------------------------------------------------------------------
# 2. the TK5 tree
# --------------------------------------------------------------------------
if [ "$do_tk5" = 1 ]; then
  log "unpacking TK5 into $ASSETS/tk5 (and restoring the exec bits it does not carry)"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
U="$WORK/unzip"
rm -rf "\$U"; mkdir -p "\$U"
cd "\$U"
unzip -q "$STAGING/$TK5_ZIP"
cd mvs-tk5

# THE TRAP THAT COST THIS STATION AN HOUR (docs/lab/MVS38-WAVE.md): the TK5 zip
# stores NO exec bits. After unzip, hercules and every TK5 shell script is mode
# 0644 and the first launch dies with
#   failed to run command 'hercules': Permission denied
chmod -R a+rX .
chmod +x hercules/linux/64/bin/* hercules/linux/64/lib/hercules/* \
         mvs mvs_ipl start_herc scripts/* unattended/*
for f in hercules/linux/64/bin/hercules mvs_ipl; do
  [ -x "\$f" ] || { echo "\$f is still not executable" >&2; exit 1; }
done
[ -f conf/tk5.cnf ] || { echo "no conf/tk5.cnf in the unpacked tree" >&2; exit 1; }
[ -f dasd/tk5res.390 ] || { echo "no MVSRES volume in the unpacked tree" >&2; exit 1; }

# The bundled Hercules needs its own lib path; Debian's hercules 3.13 will not
# run this configuration. Prove the binary we just chmod'd actually runs.
PATH="\$PWD/hercules/linux/64/bin:\$PATH" \
LD_LIBRARY_PATH="\$PWD/hercules/linux/64/lib:\$PWD/hercules/linux/64/lib/hercules" \
  hercules --version 2>&1 | head -2

# NEVER stage dasd/ out from under a running Hercules — a mid-write snapshot of
# the volumes looks fine and IPLs into a salvage. This always comes from a fresh
# unzip, and the swap into place is atomic.
rm -rf "$ASSETS/tk5.staging"
cp -a . "$ASSETS/tk5.staging"
chown -R root:root "$ASSETS/tk5.staging"
rm -rf "$ASSETS/tk5"
mv "$ASSETS/tk5.staging" "$ASSETS/tk5"
rm -rf "\$U"
echo "TK5 tree at $ASSETS/tk5 (\$(du -sh "$ASSETS/tk5" | cut -f1))"
EOF
fi

# --------------------------------------------------------------------------
# 3. container rootfs
# --------------------------------------------------------------------------
if [ "$do_rootfs" = 1 ]; then
  log "building the container rootfs at $ROOTFS (uid base $UIDBASE)"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
R="$ROOTFS"
if [ -x "\$R/usr/bin/x3270" ] \
   && [ -f "\$R/usr/share/fonts/X11/misc/3270gt24.pcf.gz" ] \
   && [ "\$(stat -c %u "\$R")" = "$UIDBASE" ]; then
  echo "container rootfs present at \$R"; exit 0
fi
rm -rf "\$R.staging"
# xfonts-x3270-misc is listed EXPLICITLY: it is only a Recommends of x3270 and
# debootstrap --variant=minbase installs no Recommends, so without it the tree
# looks complete and x3270 has no 3270 font at all (docs/lab/MVS38-WAVE.md).
debootstrap --variant=minbase \
  --include=xvfb,x3270,xfonts-x3270-misc,xterm,xfonts-base,x11-utils,xauth,netcat-openbsd,procps,util-linux,iproute2,libbsd0,fonts-dejavu-core \
  trixie "\$R.staging" http://deb.debian.org/debian >"$WORK/debootstrap.log" 2>&1 \
  || { tail -20 "$WORK/debootstrap.log" >&2; exit 1; }
for b in Xvfb x3270 nc; do
  [ -x "\$R.staging/usr/bin/\$b" ] || { echo "no \$b in the container tree" >&2; exit 1; }
done
n="\$(ls "\$R.staging/usr/share/fonts/X11/misc" | grep -c '^3270')"
[ "\$n" -ge 17 ] || { echo "only \$n 3270 fonts in the container tree — xfonts-x3270-misc missing" >&2; exit 1; }
systemd-nspawn --quiet --register=no -D "\$R.staging" \
  --private-users=$UIDBASE:65536 --private-users-ownership=chown /bin/true
rm -rf "\$R"; mv "\$R.staging" "\$R"
echo "container rootfs built at \$R (\$(du -sh "\$R" | cut -f1), uid \$(stat -c %u "\$R"))"
EOF
fi

# --------------------------------------------------------------------------
# 4. the TSO password — box-local, never in the repository
# --------------------------------------------------------------------------
# The station's launcher logs the exhibit on to TSO so it rests on the ISPF
# primary option menu. The password for that userid is a real credential and
# therefore lives ONLY on the box, in $ASSETS/tso.pass. It is the stock password
# TK5 ships for MVS38_TSO_USER and is documented in TK5's own users manual,
# doc/MVS_TK4-_v100_Users_Manual.pdf inside the distribution — read it there;
# this repository does not carry it. Pass it in the environment:
#
#   MVS38_TSO_PASS=... scripts/build-guests/tiles/mvs38.sh --secret
#
# Without it the station still starts and simply rests on the VTAM screen.
if [ "$do_secret" = 1 ]; then
  if [ -z "${MVS38_TSO_PASS:-}" ]; then
    log "no \$MVS38_TSO_PASS in the environment — skipping $ASSETS/tso.pass;"
    log "the station will rest on the VTAM screen, not the ISPF menu"
  else
    log "writing the TSO password to $ASSETS/tso.pass (0600, box-local)"
    # base64 because labrun's own script arrives on stdin, so the value cannot
    # be piped in alongside it, and because it keeps the secret off any shell
    # argument list.
    b64="$(printf '%s' "$MVS38_TSO_PASS" | base64 -w0)"
    "$LABRUN" <<EOF
set -euo pipefail
mkdir -p "$ASSETS"
umask 077
printf '%s' '$b64' | base64 -d > "$ASSETS/tso.pass"
chmod 0600 "$ASSETS/tso.pass"
echo "wrote \$(stat -c %s "$ASSETS/tso.pass") bytes to $ASSETS/tso.pass"
EOF
  fi
fi

log "done — see docs/lab/MVS38-WAVE.md"

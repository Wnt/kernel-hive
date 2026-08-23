#!/bin/bash
# rhapsody-install-browser.sh -- put a period-correct graphical web browser
# (OmniWeb 3.0, July 1999) into the `rhapsody` guest and make it discoverable
# from the Platinum desktop.
#
# WHY THIS EXISTS. Rhapsody 5.1 DR2 ships NO web browser: /Local/Applications is
# empty and /System/Applications holds only Clock, Grab, HelpViewer, MailViewer,
# Preferences, PrintManager, Preview and TextEdit. The registry's
# `periodBrowser: "OmniWeb 3"` was aspiration, not fact, until this script.
#
# WHAT GOES IN. OmniWeb 3.0 final for Mac OS X Server / Rhapsody, Intel -- a
# fat Mach-O (i486 + ppc) that carries its own 11 Omni frameworks and 10
# plugins inside the bundle, so DR2's system frameworks are not a factor, and
# ships a free 1-user license. It is NOT the widely mirrored 3.0b8b, which is
# an "Expiring Beta Release" that died on 1999-01-31 and needs the guest clock
# rolled back. See docs/lab/retronet/WEB-BROWSER-rhapsody.md for provenance.
#
# HOW THE BITS GET IN. The guest has no removable-media path we can author from
# Linux (no ISO tooling on the box, and DR2 opens no raw node for an ATAPI CD),
# so the payload rides in as a RAW second IDE disk: the .gnutar.gz written at
# offset 0 of an 8 MiB image, attached as `-drive ...,if=ide,index=1`, and read
# in the guest with `dd if=/dev/rhd1a | gzip -dc | gnutar xf -`. No filesystem,
# no disklabel, no host dependencies. THE PAYLOAD DISK IS A BRING-UP DEVICE
# ONLY -- the production launcher's device set is unchanged, and the coordinator
# detaches it before cold-baking the golden.
#
# TWO TRAPS THIS SCRIPT EXISTS TO AVOID:
#   * Workspace CANNOT launch an app through a symlink -- it reports "Couldn't
#     start up this application because it is damaged". The visitor-facing icon
#     in the guest's home must be a REAL bundle copy (9.5 MB), not a link.
#   * The root getty is tcsh and serialexec sends ONE line, so every guest
#     command here is single-line. A heredoc fed down this channel is parsed
#     line-by-line by tcsh and silently mangles the file it was meant to write.
#
# Idempotent: re-running on an already-installed guest re-asserts the
# configuration and still runs every check.
#
#   rhapsody-install-browser.sh image   <out.img> [payload.gnutar.gz]
#   rhapsody-install-browser.sh install <rig-dir> [--homepage URL] [--no-home-icon]
#   rhapsody-install-browser.sh verify  <rig-dir> [--homepage URL]
#
# <rig-dir> holds serial.sock + serial-exec.passwd (a bring-up rig, or the
# station dir /data/vms/streamhost/stations/rhapsody).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABCTL_D="$HERE/../labctl.d"

# Pinned upstream payload. Provenance + why this build: see the doc above.
OMNIWEB_URL="http://apps.rhapsodyos.org/rhapsody/OmniGroup_Apps/OmniWeb/OmniWeb-3.0-MXS-IP.gnutar.gz"
OMNIWEB_SHA256="30ffc4294c487fd175f8f66205b7f537634d054472da37c18ac948cf8e2a2fba"
OMNIWEB_BYTES=3170339
IMG_BYTES=8388608 # 8 MiB raw payload disk; the gz sits at offset 0

APP_DIR="/Local/Applications/OmniWeb.app"
GUEST_HOME="/Local/Users/guest"
HOME_APP="$GUEST_HOME/OmniWeb.app"
PAYLOAD_DEV="/dev/rhd1a"
HOMEPAGE="http://spacejam.com/index.html"
HOME_ICON=1

die() {
  echo "rhapsody-browser: $*" >&2
  exit 1
}

# One single-line command in the guest, as root, over the serial getty.
gx() {
  python3 - "$RIG" "$1" <<'PY'
import sys

import serialexec  # on PYTHONPATH: scripts/labctl.d

rc, out, diag = serialexec.run(sys.argv[1], "root", sys.argv[2], timeout=900.0)
sys.stdout.write(out)
if diag:
    sys.stderr.write("serial: %s\n" % diag)
sys.exit(rc if rc is not None else 255)
PY
}

PASS=0
FAILED=0
ok() {
  PASS=$((PASS + 1))
  echo "  ok      $*"
}
bad() {
  FAILED=$((FAILED + 1))
  echo "  FAIL    $*"
}
# check <label> <guest test command>
check() {
  if gx "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}

# ------------------------------------------------------------------ image ---
do_image() {
  local out="$1" src="${2:-}"
  [ -n "$out" ] || die "image: need an output path"
  if [ -z "$src" ]; then
    src="$(dirname "$out")/OmniWeb-3.0-MXS-IP.gnutar.gz"
    [ -f "$src" ] || {
      echo "rhapsody-browser: fetching $OMNIWEB_URL"
      curl -fsSL -o "$src" "$OMNIWEB_URL"
    }
  fi
  [ -f "$src" ] || die "image: payload not found: $src"
  local got size
  got="$(sha256sum "$src" | cut -d' ' -f1)"
  size="$(stat -c%s "$src")"
  [ "$got" = "$OMNIWEB_SHA256" ] || die "image: sha256 mismatch on $src (got $got)"
  [ "$size" = "$OMNIWEB_BYTES" ] || die "image: size mismatch on $src (got $size)"
  [ "$size" -lt "$IMG_BYTES" ] || die "image: payload larger than the $IMG_BYTES-byte disk"
  rm -f "$out"
  truncate -s "$IMG_BYTES" "$out"
  dd if="$src" of="$out" conv=notrunc status=none
  chmod 666 "$out"
  echo "rhapsody-browser: payload disk $out ($IMG_BYTES bytes, gz at offset 0, sha256 verified)"
  echo "  attach as: -drive file=$out,format=raw,if=ide,index=1   (bring-up only)"
}

# ---------------------------------------------------------------- install ---
do_install() {
  echo "rhapsody-browser: installing OmniWeb 3.0 into $RIG"

  gx "test -r $PAYLOAD_DEV" >/dev/null 2>&1 ||
    die "the guest cannot read $PAYLOAD_DEV -- is the payload disk attached at if=ide,index=1?"
  gx "dd if=$PAYLOAD_DEV bs=512 count=1 2>/dev/null | od -c | head -1 | grep -q '037 213'" >/dev/null 2>&1 ||
    die "$PAYLOAD_DEV does not start with the gzip magic -- wrong disk?"

  # Extract only when the bundle is not already in place: re-running is a no-op.
  if gx "test -x $APP_DIR/Resources/OmniWeb.app/OmniWeb" >/dev/null 2>&1; then
    echo "  (bundle already present -- not re-extracting)"
  else
    echo "  extracting $APP_DIR"
    gx "cd /Local/Applications && rm -rf OmniWeb.app && dd if=$PAYLOAD_DEV bs=8192 count=$((IMG_BYTES / 8192)) 2>/dev/null | gzip -dc 2>/dev/null | gnutar xf -" >/dev/null
  fi
  gx "chown -R root:wheel $APP_DIR" >/dev/null

  # The visitor-facing icon. A SYMLINK HERE DOES NOT WORK (see header): the
  # home window must hold a real bundle, so copy it with gnutar.
  if [ "$HOME_ICON" = 1 ]; then
    if gx "test -x $HOME_APP/Resources/OmniWeb.app/OmniWeb -a ! -h $HOME_APP" >/dev/null 2>&1; then
      echo "  (home-window copy already present)"
    else
      echo "  placing the home-window copy $HOME_APP"
      gx "cd $GUEST_HOME && rm -rf OmniWeb.app && (cd /Local/Applications && gnutar cf - OmniWeb.app) | gnutar xf -" >/dev/null
    fi
    gx "chown -R guest:staff $HOME_APP" >/dev/null
  else
    gx "rm -rf $HOME_APP" >/dev/null
  fi

  # Preferences, written into the guest user's NeXT defaults database.
  # HomePage/ShowHomePage are OmniWeb's own keys; LaunchPaths is the Workspace
  # key that autolaunches the app at login (hidden -- see the doc).
  local launcher="$APP_DIR"
  [ "$HOME_ICON" = 1 ] && launcher="$HOME_APP"
  gx "su guest -c 'defaults write OmniWeb HomePage $HOMEPAGE'" >/dev/null
  gx "su guest -c 'defaults write OmniWeb ShowHomePage YES'" >/dev/null
  gx "su guest -c 'defaults write Workspace LaunchPaths \"($launcher)\"'" >/dev/null
  echo "  home page: $HOMEPAGE   (gateway :80 origin door, no proxy)"
  do_verify
}

# ----------------------------------------------------------------- verify ---
do_verify() {
  local launcher="$APP_DIR"
  [ "$HOME_ICON" = 1 ] && launcher="$HOME_APP"
  echo "rhapsody-browser: verifying"

  check "payload    $PAYLOAD_DEV readable" "test -r $PAYLOAD_DEV"
  check "bundle     $APP_DIR present" "test -d $APP_DIR"
  check "bundle     outer launcher executable" "test -x $APP_DIR/OmniWeb"
  check "bundle     inner browser executable" "test -x $APP_DIR/Resources/OmniWeb.app/OmniWeb"
  check "bundle     i386 slice" \
    "file $APP_DIR/Resources/OmniWeb.app/OmniWeb | grep -q i386"
  check "bundle     free 1-user license shipped" \
    "test -f $APP_DIR/Resources/OmniWeb.app/Resources/OmniWeb-FreeSingleUser.omnilicense"
  check "bundle     not the expiring beta" \
    "test -z \"\$(strings $APP_DIR/Resources/OmniWeb.app/OmniWeb | grep 'Expiring Beta')\""
  check "bundle     private frameworks bundled" \
    "test -d $APP_DIR/Resources/OWF.framework"
  check "bundle     size sane (>9000 KB)" \
    "test \"\$(du -sk $APP_DIR | awk '{print \$1}')\" -gt 9000"

  if [ "$HOME_ICON" = 1 ]; then
    check "desktop    home-window copy present" "test -d $HOME_APP"
    # The trap: a symlink here launches as "damaged". Assert a real directory.
    check "desktop    home copy is a real bundle, not a symlink" "test ! -h $HOME_APP"
    check "desktop    home copy executable" "test -x $HOME_APP/Resources/OmniWeb.app/OmniWeb"
    check "desktop    home copy owned by guest" \
      "test \"\$(ls -ld $HOME_APP | awk '{print \$3}')\" = guest"
  fi

  check "prefs      HomePage = $HOMEPAGE" \
    "su guest -c 'defaults read OmniWeb HomePage' | grep -q '$HOMEPAGE'"
  check "prefs      ShowHomePage = YES" \
    "su guest -c 'defaults read OmniWeb ShowHomePage' | grep -q YES"
  check "prefs      Workspace autolaunches the browser" \
    "su guest -c 'defaults read Workspace LaunchPaths' | grep -q OmniWeb.app"
  check "disk       >50 MB free on /" \
    "test \"\$(df -k / | tail -1 | awk '{print \$4}')\" -gt 51200"

  echo "rhapsody-browser: $PASS ok, $FAILED failed"
  [ "$FAILED" = 0 ] || exit 1
}

MODE="${1:-}"
shift || true
case "$MODE" in
  image)
    do_image "${1:-}" "${2:-}"
    exit 0
    ;;
  install | verify) ;;
  *)
    sed -n '/^#   rhapsody-install-browser/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 2
    ;;
esac

RIG="${1:-}"
shift || true
[ -n "$RIG" ] || die "need a <rig-dir> (holding serial.sock and serial-exec.passwd)"
[ -S "$RIG/serial.sock" ] || die "no serial.sock in $RIG -- is the rig running?"
while [ $# -gt 0 ]; do
  case "$1" in
    --homepage)
      HOMEPAGE="$2"
      shift 2
      ;;
    --dev)
      PAYLOAD_DEV="$2"
      shift 2
      ;;
    --home-icon)
      HOME_ICON=1
      shift
      ;;
    --no-home-icon)
      HOME_ICON=0
      shift
      ;;
    *) die "unknown option: $1" ;;
  esac
done
export PYTHONPATH="$LABCTL_D${PYTHONPATH:+:$PYTHONPATH}"

case "$MODE" in
  install) do_install ;;
  verify) do_verify ;;
esac

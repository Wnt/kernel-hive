#!/bin/sh
# Stage this source directory through SLIRP to a Solaris clone.
set -eu

test "$#" -eq 1 || {
  echo "usage: $0 <guest-exec-hostfwd-port>" >&2
  exit 2
}

GEXEC=${GEXEC:-/root/gexec.py}
HTTP_PORT=${HTTP_PORT:-58080}
GUEST_DIR=${GUEST_DIR:-/var/tmp/galleryhid}
SOURCE_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TMPDIR_STAGE=$(mktemp -d /tmp/galleryhid-stage.XXXXXX)
SERVER_PID=

cleanup() {
  if test -n "$SERVER_PID"; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_STAGE"
}
trap cleanup EXIT HUP INT TERM

tar -C "$SOURCE_DIR" -czf "$TMPDIR_STAGE/galleryhid-src.tar.gz" .
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 \
  --directory "$TMPDIR_STAGE" >"$TMPDIR_STAGE/http.log" 2>&1 &
SERVER_PID=$!

ready=false
n=0
while test "$n" -lt 20; do
  if python3 -c "import urllib.request; urllib.request.urlopen(\
'http://127.0.0.1:${HTTP_PORT}/galleryhid-src.tar.gz').read(1)" \
    >/dev/null 2>&1; then
    ready=true
    break
  fi
  n=$((n + 1))
  sleep 0.1
done
test "$ready" = true || {
  echo "temporary HTTP server did not become ready" >&2
  exit 1
}

"$GEXEC" "$1" "/usr/bin/python -c \"import urllib; urllib.urlretrieve(\
'http://10.0.2.2:${HTTP_PORT}/galleryhid-src.tar.gz', \
'${GUEST_DIR}-src.tar.gz')\""
"$GEXEC" "$1" "rm -rf ${GUEST_DIR}; mkdir ${GUEST_DIR}; \
cd ${GUEST_DIR}; gzip -dc ${GUEST_DIR}-src.tar.gz | tar xf -; \
chmod 755 build.sh install.sh; echo staged=${GUEST_DIR}"

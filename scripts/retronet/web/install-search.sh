#!/usr/bin/env bash
# install-search.sh — deploy the retronet period search engine INTO the gateway
# CT (951). Idempotent; run as root on labhost. Nothing here reaches the network:
# it pushes files into the CT with `pct push` and drives systemd with `pct exec`.
#
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-search.sh --apply'
#
# Steps (each skipped/converged when already satisfied):
#   1. code    -> /opt/retronet-search/{search,rn_index,rn_render}.py in the CT
#   2. config  -> /etc/retronet/search.env (rendered from the knobs below)
#   3. corpus  -> ensure /data/retronet/corpus exists and is world-readable
#                 (the DynamicUser service only READS it; W2 fills it)
#   4. units   -> retronet-search.service + the reindex .service/.timer; enable
#   5. verify  -> the index builds over the CT's real corpus and the service
#                 answers /health, /search and /dir with period HTML
#
# The corpus itself is never in this repo (it is copyright, box-only); a tiny
# synthetic fixture under fixtures/ is used by `search.py selftest` only.
#
# Contract + as-built: docs/lab/retronet/WEB-PLANE-PLAN.md, docs/lab/retronet/WEB-SEARCH.md
set -euo pipefail

RN_VMID="${RN_VMID:-${RN_SEARCH_CT:-951}}"
RN_SEARCH_HOST="${RN_SEARCH_HOST:-127.0.0.1}"
RN_SEARCH_PORT="${RN_SEARCH_PORT:-8090}"
RN_SEARCH_CORPUS="${RN_SEARCH_CORPUS:-/data/retronet/corpus}"
RN_SEARCH_SITES="${RN_SEARCH_SITES:-$RN_SEARCH_CORPUS/sites.json}"
RN_SEARCH_PER_PAGE="${RN_SEARCH_PER_PAGE:-10}"
RN_SEARCH_SNIPPET="${RN_SEARCH_SNIPPET:-160}"
RN_SEARCH_SMOKE_Q="${RN_SEARCH_SMOKE_Q:-web}"

CODE_DIR=/opt/retronet-search
SRC="$(cd "$(dirname "$0")" && pwd)"
APPLY=0

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --ct=*) RN_VMID="${a#--ct=}" ;;
    -h | --help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "install-search.sh: unknown arg $a" >&2
      exit 2
      ;;
  esac
done

say() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() {
  printf 'install-search.sh: %s\n' "$*" >&2
  exit 1
}
do_or_plan() {
  if [ "$APPLY" = 1 ]; then "$@"; else say "PLAN: $*"; fi
}

command -v pct >/dev/null 2>&1 || die "no pct — this runs ON labhost (ssh lab '...')"
[ "$(id -u)" = 0 ] || die "must run as root on labhost"
pct status "$RN_VMID" >/dev/null 2>&1 || die "CT $RN_VMID does not exist (provision the gateway first)"

ctexec() { pct exec "$RN_VMID" -- "$@"; }

# `pct push` prints an error but still exits 0 for a missing source, so set -e
# will not catch it — check the source exists first.
ct_push() {
  local src="$1" dest="$2" perms="$3"
  [ -f "$src" ] || die "missing source file: $src"
  pct push "$RN_VMID" "$src" "$dest" --perms "$perms"
}

step "code -> CT $RN_VMID:$CODE_DIR"
do_or_plan ctexec mkdir -p "$CODE_DIR"
for f in search.py rn_index.py rn_render.py; do
  [ -f "$SRC/$f" ] || die "missing $SRC/$f"
  do_or_plan ct_push "$SRC/$f" "$CODE_DIR/$f" 0644
done

step "/etc/retronet/search.env"
if [ "$APPLY" = 1 ]; then
  ctexec mkdir -p /etc/retronet
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# retronet-search knobs — RENDERED by install-search.sh. Re-run the installer to
# change these; a hand-edit here is overwritten. See docs/lab/retronet/WEB-SEARCH.md.
RN_SEARCH_HOST=$RN_SEARCH_HOST
RN_SEARCH_PORT=$RN_SEARCH_PORT
RN_SEARCH_CORPUS=$RN_SEARCH_CORPUS
RN_SEARCH_SITES=$RN_SEARCH_SITES
RN_SEARCH_PER_PAGE=$RN_SEARCH_PER_PAGE
RN_SEARCH_SNIPPET=$RN_SEARCH_SNIPPET
EOF
  ct_push "$tmp" /etc/retronet/search.env 0644
  rm -f "$tmp"
  say "wrote /etc/retronet/search.env (port $RN_SEARCH_PORT, corpus $RN_SEARCH_CORPUS)"
else
  say "PLAN: render /etc/retronet/search.env (port $RN_SEARCH_PORT, corpus $RN_SEARCH_CORPUS)"
fi

step "corpus dir (read-only to the service; W2 fills it)"
# DynamicUser= runs as a transient uid, so the corpus must be world-traversable
# or the index silently comes back empty. `pct push` lands 0644 files, mkdir
# leaves 0755 dirs, and the era-press crawl writes under umask 022 — so this is
# already true for the content. Once the crawl has filled the corpus, that
# content is owned by CT 950's uid 1000 on the shared bind-mount, which root in
# THIS unprivileged CT cannot chmod ("Operation not permitted") and need not.
# So make the path traversable best-effort and never abort the install on it.
do_or_plan ctexec mkdir -p "$RN_SEARCH_CORPUS"
do_or_plan ctexec sh -c "chmod -R a+rX /data/retronet '$RN_SEARCH_CORPUS' 2>/dev/null || true"

step "units"
for u in retronet-search.service retronet-search-reindex.service retronet-search-reindex.timer; do
  do_or_plan ct_push "$SRC/$u" "/etc/systemd/system/$u" 0644
done
do_or_plan ctexec systemctl daemon-reload
do_or_plan ctexec systemctl enable --now retronet-search.service
do_or_plan ctexec systemctl enable --now retronet-search-reindex.timer

if [ "$APPLY" != 1 ]; then
  step "verify (skipped in plan mode — pass --apply)"
  exit 0
fi

step "verify"
# Wait for the listener, then prove index + the three routes from INSIDE the CT
# (the service binds loopback; nothing off the CT can reach it, and the CT has
# no curl — a stdlib urllib probe is the honest check).
probe="$(mktemp)"
cat >"$probe" <<'PY'
import sys, urllib.request, urllib.parse
host, port, q = sys.argv[1], sys.argv[2], sys.argv[3]
base = f"http://{host}:{port}"


def get(path):
    with urllib.request.urlopen(base + path, timeout=5) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


ok = True
st, ct, body = get("/health")
print(f"  /health          -> {st} {body.decode('latin-1').strip()}")
ok &= st == 200 and body.startswith(b"OK")
st, ct, body = get("/search?q=" + urllib.parse.quote(q))
hits = body.count(b'color="#008000">http://')
print(f"  /search?q={q:<8} -> {st} {ct.split(';')[0]}  ({hits} hit link(s), {len(body)} bytes)")
ok &= st == 200 and b"charset=iso-8859-1" in ct.encode() and b"<!DOCTYPE" in body and b"<script" not in body.lower()
st, ct, body = get("/dir")
print(f"  /dir             -> {st} {ct.split(';')[0]}  ({len(body)} bytes, Yahoo={b'Yahoo' in body})")
ok &= st == 200 and b"charset=iso-8859-1" in ct.encode() and b"<script" not in body.lower()
sys.exit(0 if ok else 1)
PY
ct_push "$probe" /tmp/rn-search-probe.py 0644
rm -f "$probe"

for _ in $(seq 1 30); do
  ctexec python3 -c "import socket,sys
s=socket.socket(); s.settimeout(0.5)
sys.exit(0) if not s.connect_ex(('$RN_SEARCH_HOST', $RN_SEARCH_PORT)) else sys.exit(1)" >/dev/null 2>&1 && break
done

say "index over the CT's real corpus:"
ctexec python3 "$CODE_DIR/search.py" index | sed 's/^/    /' || die "index build failed in CT"
ctexec python3 /tmp/rn-search-probe.py "$RN_SEARCH_HOST" "$RN_SEARCH_PORT" "$RN_SEARCH_SMOKE_Q" ||
  die "HTTP smoke failed — journalctl -u retronet-search in CT $RN_VMID"
ctexec rm -f /tmp/rn-search-probe.py
printf '\n'
ctexec systemctl --no-pager --lines=3 status retronet-search.service || true
say "search up on $RN_SEARCH_HOST:$RN_SEARCH_PORT in CT $RN_VMID"

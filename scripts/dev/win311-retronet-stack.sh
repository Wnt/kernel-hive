#!/bin/bash
# win311-retronet-stack.sh — offline in-guest prep for win311's retronet join.
#
#   win311-retronet-stack.sh prep <win311-golden.qcow2>   # edit (idempotent)
#   win311-retronet-stack.sh show <win311-golden.qcow2>   # read-only state dump
#
# The WfW 3.11 image already carries everything the retronet needs — the
# RTL8029 NDIS3 driver (PCIND$, QEMU's ne2k_pci IS an RTL8029), MS TCP/IP-32
# bound to it with DHCP enabled (SYSTEM.INI [RTL80290] IPAddress=0.0.0.0,
# vdhcp.386 loaded), and a shelf of period browsers (Netscape 4.08 16-bit,
# Navigator Gold 3, IE3, IE5, NCSA Mosaic). Nothing is installed here. What
# this script fixes is the residue of the image's donor-PC life on a
# 192.168.178.0/24 home LAN, and the browser home pages:
#
#   1. SYSTEM.INI [RTL80290] DefaultGateway=192.168.178.1  ->  (empty).
#      Containment Lock 1 belt: the DHCP reservation already withholds the
#      router option, but a static in-guest gateway would re-create a default
#      route the addressing plane deliberately never hands out.
#   2. SYSTEM.INI [DNS] DNSServers=192.168.178.1 -> 10.99.0.2, DomainName=lan
#      -> retronet.lab. TCP/IP-32's resolver prefers the static [DNS] entries
#      over the lease, so they must point at the gateway's wildcard DNS.
#   3. Home pages onto corpus-archived sites (era browsers need real pages, and
#      the wildcard DNS makes any name resolve — but only archived hosts render):
#        Netscape 4.08 (the exhibit): browser.startup.homepage
#          http://home.netscape.com/  in C:\Netscape\Users\jj\prefs.js
#        Navigator Gold 3 (C:\NETSCAPE\NETSCAPE.INI [Main] Home Page) — same.
#        IE3 (C:\WINDOWS\IEXPLORE.INI [Main] Home Page) http://home.microsoft.com/
#      NCSA Mosaic is left alone: it sends no Host: header, so the seamless
#      no-proxy web cannot serve it (same class of fault as os2warp's
#      WebExplorer — see docs/lab/retronet/WEB-STATION-os2warp.md).
#
# Every write preserves CRLF (Windows INI parsing is line-ending sensitive) and
# is verified back. All mounting inside chroot-guard run-private.
set -euo pipefail
MODE="${1:-}"
DISK="${2:-}"
[ -n "$MODE" ] && [ -n "$DISK" ] || {
  sed -n '2,8p' "$0" >&2
  exit 2
}
[ -f "$DISK" ] || {
  echo "no such disk: $DISK" >&2
  exit 2
}
export STACK_MODE="$MODE" STACK_DISK="$DISK"
exec chroot-guard run-private bash -s <<'INNER'
set -euo pipefail
ND=""
for i in 4 5 6 7 8 9 10 11; do
  RO=""; [ "$STACK_MODE" = show ] && RO="--read-only"
  if qemu-nbd $RO --connect="/dev/nbd$i" "$STACK_DISK" >/dev/null 2>&1; then
    ND="/dev/nbd$i"
    break
  fi
done
[ -n "$ND" ] || {
  echo "no free nbd device" >&2
  exit 1
}
cleanup() {
  cd /
  umount "$M" 2>/dev/null || true
  qemu-nbd --disconnect "$ND" >/dev/null 2>&1 || true
}
trap cleanup EXIT
sleep 1
M="$(mktemp -d)"
if [ "$STACK_MODE" = show ]; then
  mount -o ro "${ND}p1" "$M"
else
  mount "${ND}p1" "$M"
fi

PYRC=0
python3 - "$M" "$STACK_MODE" <<'PY' || PYRC=$?
import sys, os, re
root, mode = sys.argv[1], sys.argv[2]
checks = []


def edit(path, subs, required=True):
    """CRLF-preserving literal substitutions; records a check per sub."""
    p = os.path.join(root, path)
    if not os.path.exists(p):
        checks.append((not required, f"{path}: absent"))
        return
    b = open(p, "rb").read()
    for old, new in subs:
        if new in b and old not in b:
            checks.append((True, f"{path}: already `{new.decode()}`"))
            continue
        if old not in b:
            checks.append((False, f"{path}: pattern missing: {old.decode()!r}"))
            continue
        if mode == "prep":
            b = b.replace(old, new)
            checks.append((True, f"{path}: {old.decode()!r} -> {new.decode()!r}"))
        else:
            checks.append((False, f"{path}: still {old.decode()!r}"))
    if mode == "prep":
        open(p, "wb").write(b)


edit(
    "WINDOWS/SYSTEM.INI",
    [
        (b"DefaultGateway=192.168.178.1", b"DefaultGateway="),
        (b"DNSServers=192.168.178.1", b"DNSServers=10.99.0.2"),
        (b"DomainName=lan", b"DomainName=retronet.lab"),
    ],
)
edit(
    "NETSCAPE/NETSCAPE.INI",
    [],
    required=False,
)
# Navigator Gold 3: [Main] Home Page. The value varies per donor history, so
# rewrite whatever is there by regex rather than a literal.
p = os.path.join(root, "NETSCAPE/NETSCAPE.INI")
if os.path.exists(p):
    b = open(p, "rb").read()
    nb = re.sub(
        rb"(?mi)^Home Page=.*?(\r?)$",
        rb"Home Page=http://home.netscape.com/\1",
        b,
    )
    if mode == "prep" and nb != b:
        open(p, "wb").write(nb)
    ok = b"Home Page=http://home.netscape.com/" in (nb if mode == "prep" else b)
    checks.append((ok, "NETSCAPE/NETSCAPE.INI: Home Page -> home.netscape.com"))
p = os.path.join(root, "WINDOWS/IEXPLORE.INI")
if os.path.exists(p):
    b = open(p, "rb").read()
    nb = re.sub(
        rb"(?mi)^Home Page=.*?(\r?)$",
        rb"Home Page=http://home.microsoft.com/\1",
        b,
        count=1,
    )
    if mode == "prep" and nb != b:
        open(p, "wb").write(nb)
    ok = b"Home Page=http://home.microsoft.com/" in (nb if mode == "prep" else b)
    checks.append((ok, "WINDOWS/IEXPLORE.INI: Home Page -> home.microsoft.com"))
# Netscape 4.08 (the exhibit): prefs.js of the one profile.
p = os.path.join(root, "Netscape/Users/jj/prefs.js")
for cand in ("Netscape/Users/jj/prefs.js", "NETSCAPE.1/USERS/JJ/PREFS.JS"):
    q = os.path.join(root, cand)
    if os.path.exists(q):
        p = q
        break
if os.path.exists(p):
    b = open(p, "rb").read()
    want = b'user_pref("browser.startup.homepage", "http://home.netscape.com/");'
    if re.search(rb'user_pref\("browser\.startup\.homepage",', b):
        nb = re.sub(
            rb'user_pref\("browser\.startup\.homepage",[^\r\n]*\);',
            want,
            b,
        )
    else:
        nb = b.rstrip(b"\r\n") + b"\r\n" + want + b"\r\n"
    if mode == "prep" and nb != b:
        open(p, "wb").write(nb)
    ok = want in (nb if mode == "prep" else b)
    checks.append((ok, f"{p[len(root):]}: homepage -> home.netscape.com"))
    # no proxy: network.proxy.type must not force a proxy (absent = direct).
    bad = re.search(rb'user_pref\("network\.proxy\.type", [12]\)', b)
    checks.append((not bad, f"{p[len(root):]}: no proxy pref forced"))
else:
    checks.append((False, "prefs.js: profile not found"))

fails = 0
for ok, msg in checks:
    print(("PASS  " if ok else "FAIL  ") + msg)
    fails += 0 if ok else 1
sys.exit(1 if fails else 0)
PY
sync
exit $PYRC
INNER

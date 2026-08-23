#!/bin/bash
# os2-retronet-stack.sh — give the os2warp guest a WORKING IBM TCP/IP stack on
# the retronet, by offline (qemu-nbd) surgery on its FAT16 C: drive.
#
# WHY THIS EXISTS. The Warp 4.52 (MCP2) in-place upgrade's *networking* install
# died with error 1608. It had already copied every binary onto C: — \IBMCOM
# (PROTMAN.OS2, LANMSGDD.OS2, MACS\PCNTND.OS2, PROTOCOL\NETBIND.EXE), \MPTN
# (PROTOCOL\{SOCKETS,AFOS2,AFINET}.SYS, BIN\{DHCPCD,DHCPSTRT,IFCONFIG,
# PING}.EXE, ETC\DHCPCD.CFG) — but never ran the *configuration* step. The
# wreckage it left is what made the stack look absent:
#
#   1. \IBMCOM\PROTOCOL.INI binds TCPIP_nif to NONETADP_nif — the NULL adapter
#      (NULLNDS$). No real NIC was ever bound to TCP/IP. This is the actual
#      root cause; every other symptom is downstream of it.
#   2. CONFIG.SYS referenced \MPTN\PROTOCOL\SOCKETSK.SYS and AFINETK.SYS — the
#      WSeB "kernel" variants, which the failed install left behind in its
#      staging dir C:\TMPT\PROTOCOL and never placed. An earlier gallery pass
#      REMmed those lines to stop the SYS1718 boot prompts. The ordinary client
#      variants SOCKETS.SYS / AFINET.SYS were on disk in \MPTN\PROTOCOL the
#      whole time; we point the DEVICE= lines at those.
#   3. The MAC driver itself, \IBMCOM\MACS\PCNTND.OS2, was never in CONFIG.SYS,
#      so even a corrected PROTOCOL.INI would have had nothing to bind to. Nor
#      was IFNDIS.SYS, the NDIS interface that gives AFINET its lan0.
#
# IFNDIS.SYS IS REQUIRED HERE, and that contradicts IBM's own documentation.
# MPTS 6.01's readme.mpt 1.11 states this level "no longer uses IFNDIS.SYS and
# the installation process removes this file", and the CD ships no copy of it.
# But this image's \MPTN\PROTOCOL does carry one, and it is load-bearing:
# measured on the bring-up rig, dropping the DEVICE= line makes DHCPCD.EXE trap
# at boot with "DHCPSTRT: DHCP client did not get parameters" (no lan0 for
# `dhcpstrt -i lan0` to bind), while the otherwise identical config WITH the
# line leases 10.99.0.19 and writes RESOLV2. Framebuffer + DHCP-server log both
# ways. Do not "fix" this line back out on the strength of the readme.
#   4. The NDIS load ORDER was wrong: CALL=NETBIND.EXE ran ~11 lines BEFORE the
#      MAC/protocol DEVICE= lines it is supposed to bind. We rebuild the whole
#      network block in the correct order.
#   5. \MPTN\BIN\SETUP.CMD — which MPTSTART.CMD already CALLs when present, and
#      which is where the interface is actually configured — was left as the
#      zero-byte template SETUP.$T$. We author it to start the DHCP client.
#
# Nothing is installed from the CD: every file needed was already on C:. The CD
# (mcp2-refresh-install-en.iso) was used only to READ pcntnd.nif/tcpip.nif and
# confirm section and parameter names.
#
# HARD CONSTRAINT: CONFIG.SYS must stay CRLF. Writing it LF-only from Linux
# makes OS/2 mis-parse every line -> SYS02068 "unable to operate your hard
# disk". Every write below goes through crlf() and is verified after.
#
# DO NOT touch the video config. The guest is pinned to IBM GENGRADD at
# 1024x768x64k (SET C1=GENGRADD,SBFILTER,VGAGRADD); any PMI-based alternative
# traps c0000005. This script never writes a VIDEO_DEVICES/C1/BVH line.
#
# Idempotent: re-running on an already-prepped image is a no-op that still
# verifies. All mounting goes through chroot-guard run-private.
#
#   os2-retronet-stack.sh prep <disk.qcow2>    apply the stack fixes
#   os2-retronet-stack.sh show <disk.qcow2>    print the current network config
set -euo pipefail

MODE="${1:-}"
DISK="${2:-}"
[ -n "$MODE" ] && [ -n "$DISK" ] || {
  sed -n '2,50p' "$0" >&2
  exit 2
}
[ -f "$DISK" ] || {
  echo "os2-stack: no such disk: $DISK" >&2
  exit 1
}
[ "$(id -u)" = 0 ] || {
  echo "os2-stack: must run as root" >&2
  exit 1
}

export OS2_STACK_DISK="$DISK"
export OS2_STACK_MODE="$MODE"
# The single source for the guest's desktop inventory. Both
# scripts/build-guests/tiles/os2warp.sh and scripts/dev/os2-gengradd-hires.sh
# install this same file as C:\STARTUP.CMD, CRLF-ifying it on the way in; we do
# the same so a retronet prep never leaves a stale on-image copy behind.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OS2_STACK_STARTUP="${OS2_STACK_STARTUP:-$SCRIPT_DIR/../build-guests/assets/os2warp/create-desktop-objects.cmd}"
[ -f "$OS2_STACK_STARTUP" ] || {
  echo "os2-stack: desktop object source missing: $OS2_STACK_STARTUP" >&2
  exit 1
}
export OS2_STACK_STARTUP

# All mount work happens inside a PRIVATE mount namespace: an escaping umount is
# structurally impossible there, and the kernel tears every mount down when the
# last process exits. See chroot-guard's header for the two incidents that make
# this non-optional.
exec chroot-guard run-private bash -s <<'INNER'
set -euo pipefail
DISK="$OS2_STACK_DISK"
MODE="$OS2_STACK_MODE"

modprobe nbd max_part=8 2>/dev/null || true

# Claim a free nbd device by trying to connect: /sys/block/nbd*/pid is a
# check-then-use race, and qemu-nbd --connect fails loudly if the device is
# taken, which is exactly the "the claim IS the proof" property we want.
ND=""
for i in $(seq 9 15); do
  if qemu-nbd --connect="/dev/nbd$i" "$DISK" >/dev/null 2>&1; then
    ND="/dev/nbd$i"
    break
  fi
done
[ -n "$ND" ] || {
  echo "os2-stack: no free nbd device" >&2
  exit 1
}
cleanup() {
  cd /
  umount /mnt/os2c 2>/dev/null || true
  qemu-nbd --disconnect "$ND" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 20); do [ -b "${ND}p1" ] && break; sleep 0.5; done
mkdir -p /mnt/os2c
mount -t vfat "${ND}p1" /mnt/os2c
C=/mnt/os2c

if [ "$MODE" = show ]; then
  echo "===== CONFIG.SYS network block ====="
  tr -d '\r' <"$C/CONFIG.SYS" | grep -nE 'IBMCOM|MPTN|NETBIND|LANMSG|SOCKETS|AFOS2|AFINET|PCNTND|MPTSTART|CNTRL' || true
  echo "===== PROTOCOL.INI bindings ====="
  tr -d '\r' <"$C/IBMCOM/PROTOCOL.INI" | grep -nE '_nif|Bindings|DriverName|IBMLXCFG' || true
  echo "===== SETUP.CMD ====="
  [ -f "$C/MPTN/BIN/SETUP.CMD" ] && tr -d '\r' <"$C/MPTN/BIN/SETUP.CMD" || echo "(absent)"
  exit 0
fi

# ---------------------------------------------------------------- helpers ---
# Write a file with CRLF line endings, from LF-separated stdin. This is the ONLY
# writer used below; see the CRLF constraint in the header.
crlf() { sed 's/$/\r/' >"$1"; }

# Backups go in a SUBDIRECTORY, never beside the original. C:\ is FAT16 and its
# root directory is a fixed-size table that is already FULL (431 EA*.CHK chkdsk
# husks from earlier passes occupy it), so creating ANY new file in the root
# fails with ENOSPC even though the volume has ~1.5 GB free. Pre-existing debt,
# noted in docs/guests/os2warp.md; this script just does not add to it.
BKDIR="$C/GALLERY/RNBAK"
backup_once() {
  mkdir -p "$BKDIR"
  local b="$BKDIR/$(basename "$1")"
  [ -f "$b" ] || cp -p "$1" "$b"
  echo "$b"
}

# ------------------------------------------------------- 1. PROTOCOL.INI ---
# Bind IBM TCP/IP to the AMD PCNet NDIS driver instead of the NULL adapter.
# Section/parameter names verified against the CD's cid/nifs/macs/pcntnd.nif
# (DRIVERNAME = PCNTND$, FILE NAME = PCNTND.OS2) and cid/nifs/protocol/tcpip.nif
backup_once "$C/IBMCOM/PROTOCOL.INI" >/dev/null
# Written WHOLESALE rather than patched: the file MPTS left behind bound TCP/IP
# to NONETADP_nif (the NULL adapter NULLNDS$) and carried NETBEUI / NETBIOS /
# ODI2NDI sections for drivers this station does not want. A deterministic
# rewrite is idempotent and leaves no stale binding to reason about.
#
# IP ONLY, on purpose. NetBEUI/NetBIOS are NOT configured: the retronet carries
# IP, and keeping NetBIOS off the wire is a real containment win on a bridged
# 2001-vintage guest. ODI2NDI (the NetWare ODI<->NDIS shim) is dropped too --
# it is what made the cold boot stop on "SYS1718: cannot find the file NWCONFIG"
# and nothing here needs it.
#
# Section and parameter names verified against the CD: cid/nifs/macs/pcntnd.nif
# (Drivername = PCNTND$, FILE Name = PCNTND.OS2) and cid/nifs/protocol/tcpip.nif
# (DRIVERNAME = TCPIP$). The [IBMLXCFG] labels are arbitrary -- MPTS's own sample
# response files use the same <name>_nif convention.
crlf "$C/IBMCOM/PROTOCOL.INI" <<'EOF'
[PROT_MAN]

   DriverName = PROTMAN$

[IBMLXCFG]

   TCPIP_nif = TCPIP.NIF
   PCNTND_nif = PCNTND.NIF

[TCPIP_nif]

   DriverName = TCPIP$
   Bindings = PCNTND_nif

[PCNTND_nif]

   DriverName = PCNTND$
EOF

# ---------------------------------------------------------- 2. CONFIG.SYS ---
# Rebuild the network block in correct NDIS order. Every DEVICE= below points at
# a file verified present on this image; nothing is REMmed-because-missing any
# more. The block is emitted at the position of the FIRST network line removed,
# so the rest of CONFIG.SYS keeps its order (notably the video SET lines, which
# are never touched).
CFG_BAK="$(backup_once "$C/CONFIG.SYS")"
tr -d '\r' <"$CFG_BAK" >/tmp/cfg.lf

python3 - <<'PY'
import re

NET_BLOCK = """SET NLSPATH=C:\\MPTN\\MSG\\NLS\\%N;C:\\TCPIP\\MSG\\ENUS850\\%N;C:\\TCPIP\\MSG\\%N;
SET ETC=C:\\MPTN\\ETC
REM NLSPATH also carries C:\\TCPIP\\MSG\\ENUS850 so WebExplorer finds its own
REM EXPLORE.CAT; without it EXPLORE.EXE starts and then dies on
REM "Message catalog not found ... Did you reboot after installing?".
REM --- retronet: NDIS transport, in load order (MAC, protocols, then NETBIND) ---
DEVICE=C:\\IBMCOM\\MACS\\PCNTND.OS2
DEVICE=C:\\MPTN\\PROTOCOL\\SOCKETS.SYS
DEVICE=C:\\MPTN\\PROTOCOL\\AFOS2.SYS
DEVICE=C:\\MPTN\\PROTOCOL\\AFINET.SYS
DEVICE=C:\\MPTN\\PROTOCOL\\IFNDIS.SYS
CALL=C:\\IBMCOM\\PROTOCOL\\NETBIND.EXE
RUN=C:\\IBMCOM\\LANMSGEX.EXE
RUN=C:\\MPTN\\BIN\\CNTRL.EXE
CALL=C:\\OS2\\CMD.EXE /Q /C C:\\MPTN\\BIN\\MPTSTART.CMD >NUL
REM --- end retronet block ---"""

# Lines the rebuilt block replaces. Matched on content, not line number, so the
# script stays idempotent and survives unrelated CONFIG.SYS edits.
DROP = re.compile(
    r'^(SET NLSPATH=C:\\MPTN|SET ETC=C:\\MPTN|'
    r'REM --- retronet|REM --- end retronet|'
    r'(REM (MISSING |GALLERY-QUIET )?)?(DEVICE|CALL|RUN)='
    r'C:\\(IBMCOM|MPTN)\\|'
    r'CALL=C:\\OS2\\CMD\.EXE /Q /C C:\\MPTN\\BIN\\MPTSTART)',
    re.I)

# These two IBMCOM DEVICE= lines load BEFORE the block (they are the base
# NDIS/message plumbing MPTS puts near the top) and must stay where they are.
KEEP = re.compile(r'^DEVICE=C:\\IBMCOM\\(LANMSGDD|PROTMAN)\.OS2', re.I)

# The failed networking install also never extended the search paths, so the
# TCP/IP applications could not find their own DLLs. IBM WebExplorer
# (C:\TCPIP\BIN\EXPLORE.EXE) died at launch with "SYS1804: The system cannot
# find the file SETLOC1" purely because C:\IBMI18N\DLL (which holds
# SETLOC1.DLL) and C:\TCPIP\DLL were absent from LIBPATH. Append what is
# missing, preserving each line's existing order and its trailing ';'.
PATH_ADDS = {
    'LIBPATH=':    ['C:\\TCPIP\\DLL', 'C:\\IBMI18N\\DLL'],
    'SET PATH=':   ['C:\\TCPIP\\BIN'],
    'SET DPATH=':  ['C:\\TCPIP\\ETC'],
    'SET HELP=':   ['C:\\TCPIP\\HELP'],
}


def extend_path(ln):
    for prefix, adds in PATH_ADDS.items():
        if not ln.upper().startswith(prefix.upper()):
            continue
        head, _, tail = ln.partition('=')
        parts = [p for p in tail.split(';') if p != '']
        have = {p.upper() for p in parts}
        for a in adds:
            if a.upper() not in have:
                parts.append(a)
        return head + '=' + ';'.join(parts) + ';'
    return ln


src = open('/tmp/cfg.lf').read().split('\n')
out, placed = [], False
for ln in src:
    if KEEP.match(ln):
        out.append(ln)
        continue
    if DROP.match(ln):
        if not placed:
            out.extend(NET_BLOCK.split('\n'))
            placed = True
        continue          # drop the old, scattered line
    out.append(extend_path(ln))
assert placed, "network block anchor not found in CONFIG.SYS"
open('/tmp/cfg.new', 'w').write('\n'.join(out))
PY
crlf "$C/CONFIG.SYS" </tmp/cfg.new

# ------------------------------------------------------------ 3. SETUP.CMD ---
# MPTSTART.CMD (already CALLed from CONFIG.SYS) runs this when it exists. It is
# where the interface gets configured. DHCP only: the reservation on the gateway
# CT supplies address + DNS and deliberately withholds option 3 (router), so the
# guest ends up with NO default route -- containment Lock 1 comes from the
# addressing itself. Nothing here adds a route.
backup_once "$C/MPTN/BIN/MPTSTART.CMD" >/dev/null
crlf "$C/MPTN/BIN/SETUP.CMD" <<'EOF'
@ECHO OFF
REM Generated by scripts/dev/os2-retronet-stack.sh -- retronet web plane.
REM Loopback first, then take lan0's address AND its DNS from the retronet
REM gateway CT (10.99.0.2) by DHCP. -d is the seconds DHCPSTRT waits for a
REM lease before returning; the boot continues either way.
ifconfig lo 127.0.0.1
dhcpstrt -i lan0 -d 45
EOF

# ------------------------------------------------------ 3b. EXPLORE.INI ---
# IBM WebExplorer's own configuration. TWO INDEPENDENT FAULTS were fixed here;
# both are needed, and each alone still leaves a blank browser.
#
#   a) NO PROXY -> HTTP 400. WebExplorer 1.2 is a 1996 browser that predates
#      HTTP/1.1 virtual hosting: it sends `GET /path HTTP/1.0` with NO `Host:`
#      header (confirmed on the wire with tcpdump on os2rn0). The retronet
#      gateway's :80 origin door picks the corpus site BY the Host header, so
#      with none it can only answer `HTTP/1.0 400 Bad Request`. The seamless
#      "no proxy, wildcard DNS -> :80 origin" path that the Windows stations use
#      is therefore structurally unreachable for this browser. Instead we point
#      it at the gateway's CLASSIC PROXY DOOR on 10.99.0.2:3128, where it sends
#      absolute-form `GET http://host/path HTTP/1.0` and the host travels in the
#      request line. This is docs/lab/retronet/WEB-PROXY.md's "the original web
#      door", and a proxy-configured OS/2 desktop is period-correct anyway.
#
#   b) NO [viewers] SECTION -> "There is no viewer registered for this type of
#      file". The EXPLORE.INI the failed install left was a 68-byte stub with
#      only an [advanced] section, so not even text/html had an internal viewer
#      registered and EVERY response opened the save-to-disk dialog. The
#      [viewers] block below is exactly what WebExplorer itself writes on a
#      clean exit; it is reproduced verbatim so a rebuilt image needs no GUI pass.
#
# HomePage + AutoLoad make the desktop icon land straight on a corpus page.
backup_once "$C/MPTN/ETC/EXPLORE.INI" >/dev/null
crlf "$C/MPTN/ETC/EXPLORE.INI" <<'EOF'
; Web Explorer INI file
; (edit this file with care)
; Retronet web plane -- see docs/lab/retronet/WEB-STATION-os2warp.md.
; Regenerated by scripts/dev/os2-retronet-stack.sh; hand edits will be lost.

[screen]
xleft=40
ybottom=30
width=944
height=700
fontfamily=Helvetica
fontsize=Normal
textcolor=black
linkcolor=blue
visitcolor=darkpink
backcolor=palegray

[cache]
CacheOn=Yes
CacheMem=Yes
cachedocs=16
cacheimages=32

[options]
SaveToDisk=No
InlineImages=Yes
UnderlineLinks=No
InternalViewer=Yes
CustomAnimations=Yes
ShowURL=Yes
Streaming=Yes
FastLoad=Yes
Smeared=No
Keyring=C:\MPTN\ETC\explore.kyr
NewsGRPFile=C:\MPTN\ETC\news.grp
NewsCFGFile=C:\MPTN\ETC\news.cfg
NewsSIGFile=C:\MPTN\ETC\news.sig

[network]
HomePage=http://spacejam.com/index.html
AutoLoad=Yes
Email=
Proxy=http://10.99.0.2:3128/
EnableProxy=Yes
News=
Socks=
EnableSocks=No
Alerts=0

[advanced]
; advanced user settings - edit with care!
;
; mailcap= specifies full path to user mailcap file
; format is:  mime/type; program_name params %s
; example:    image/jpeg; jview -r %s
; no wildcards allowed, no piping, no unix commands
mailcap=C:\MPTN\ETC\mailcap
; extmap= specifies full path to user extension map file
; format is:  mime/type     extension_list
; example:    image/jpeg    jpg jpeg jpe
extmap=C:\MPTN\ETC\extmap

[viewers]
; DO NOT edit this section 
; data tags (e.g. viewer=gif) do not represent file extensions
; use mailcap in advanced section above to add NEW mime types
viewer=editor, e.exe
viewer=gif, ib.exe
viewer=jpeg, ib.exe
viewer=tiff, ib.exe
viewer=bmp, ib.exe
viewer=xbitmap, ib.exe
viewer=mpeg, vb.exe
viewer=quicktime, vb.exe
viewer=avi, vb.exe
viewer=avs, vb.exe
viewer=au, ab.exe
viewer=aif, ab.exe
viewer=wav, ab.exe
viewer=inf, view.exe

[quicklist]
EOF

# ------------------------------------------------------- 3c. STARTUP.CMD ---
# Reinstall the desktop inventory from its single source, so the WebExplorer
# object lands where create-desktop-objects.cmd now says (it used to be placed
# on top of the system "Programs" folder, where a click opened Programs instead
# of the browser). CRLF-ified on the way in, exactly like the two builders do.
backup_once "$C/STARTUP.CMD" >/dev/null
crlf "$C/STARTUP.CMD" <"$OS2_STACK_STARTUP"

# --------------------------------------------------------- 4. DHCPCD.CFG ---
# Stock IBM client config already requests option 1/3/6/15/28/33 with
# "clientid MAC" on "interface lan0" -- exactly what we need (option 6 is the
# DNS server that makes the seamless web work). Left as shipped; recorded here
# so a future reader knows it was reviewed, not overlooked.

# ------------------------------------------------------------- 5. verify ---
fail=0
say() { echo "  $*"; }
echo "os2-stack: verifying"

# CRLF is the constraint that has broken this guest before -- assert it.
for f in "$C/CONFIG.SYS" "$C/IBMCOM/PROTOCOL.INI" "$C/MPTN/BIN/SETUP.CMD"; do
  if LC_ALL=C grep -qU $'\r$' "$f" && ! LC_ALL=C grep -qU $'[^\r]$' "$f"; then
    say "CRLF OK   $f"
  else
    say "CRLF FAIL $f"
    fail=1
  fi
done

# Every DEVICE=/CALL= target in the network block must actually exist on C:.
while read -r p; do
  win="${p#C:}"
  unix="$C${win//\\//}"
  if [ -e "$unix" ]; then say "exists    $p"; else
    say "MISSING   $p"
    fail=1
  fi
done < <(tr -d '\r' <"$C/CONFIG.SYS" | sed -n 's/^\(DEVICE\|CALL\)=\(C:[^ ]*\).*/\2/p' | grep -iE 'IBMCOM|MPTN')

grep -qi 'Bindings = PCNTND_nif' "$C/IBMCOM/PROTOCOL.INI" && say "bound     TCPIP_nif -> PCNTND_nif" || {
  say "NOT BOUND TCPIP_nif"
  fail=1
}
grep -qi '^\[PCNTND_nif\]' "$C/IBMCOM/PROTOCOL.INI" && say "section   [PCNTND_nif]" || {
  say "NO SECTION [PCNTND_nif]"
  fail=1
}
# The video pinning must be untouched by this script.
for d in 'C:\TCPIP\DLL' 'C:\IBMI18N\DLL'; do
  if tr -d '\r' <"$C/CONFIG.SYS" | grep -i '^LIBPATH=' | grep -qiF "$d"; then
    say "libpath   $d"
  else
    say "LIBPATH MISSING $d"
    fail=1
  fi
done
grep -qiF 'ICONPOS=8,78' "$C/STARTUP.CMD" && say "desktop   WebExplorer icon at 8,78" || {
  say "DESKTOP ICON NOT REPOSITIONED"
  fail=1
}
grep -qi '^EnableProxy=Yes' "$C/MPTN/ETC/EXPLORE.INI" && say "browser   proxy 10.99.0.2:3128 enabled" || {
  say "PROXY NOT ENABLED"
  fail=1
}
grep -qi '^\[viewers\]' "$C/MPTN/ETC/EXPLORE.INI" && say "browser   [viewers] present" || {
  say "NO [viewers] SECTION"
  fail=1
}
grep -qi 'SET C1=GENGRADD' "$C/CONFIG.SYS" && say "video     GENGRADD line intact" || {
  say "VIDEO LINE LOST"
  fail=1
}

[ "$fail" = 0 ] && echo "os2-stack: OK" || {
  echo "os2-stack: FAILED"
  exit 1
}
INNER

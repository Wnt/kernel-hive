#!/usr/bin/env bash
# install-requests-volume.sh — the miss-journal spool: a tiny shared directory the
# gateway CT writes and the crawl CT reads. Idempotent; re-running is the repair path.
#
# WHY A SEPARATE VOLUME. The journal used to be specified as a file at the corpus
# root, "the one path both containers share". It never worked once: the proxy unit
# sets ReadOnlyPaths on the corpus (correct — a service that only serves must not be
# able to write what it serves), and the corpus bind-mount is owned by a host uid
# outside CT 951's idmap, so it appears as nobody:nogroup and NO in-CT user can ever
# own it. record_miss swallowed the resulting OSError on every miss and the whole
# station-request channel was silently dead. The fix is not to loosen the corpus but
# to give the hint channel a few kilobytes of its own.
#
# OWNERSHIP is the whole trick, and it is why this must run on the host:
#   owner 100997 = CT 951's rnproxy (uid 997) seen through the unprivileged idmap
#                  (+100000) — it creates and appends to the journal
#   group   1000 = host wnt = CT 950's crawl user, which must RENAME and UNLINK the
#                  journal to rotate it, and that needs write on the DIRECTORY
#   mode    2775 = both can write; setgid keeps new files in the shared group
#
# RUNS ON LABHOST (needs zfs + pct). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-requests-volume.sh'
#
# As-built: docs/lab/retronet/ERA-PRESS.md, docs/lab/retronet/WEB-PROXY.md.
set -euo pipefail

POOL_DS="${RN_REQ_DS:-data/vms/retronet-requests}" # ZFS dataset name
VOL="${RN_REQ_VOL:-/data/vms/retronet-requests}"   # labhost/CT 950 path (CT 950 sees it via /data/vms)
QUOTA="${RN_REQ_QUOTA:-1G}"                        # a runaway journal must never fill the pool
CT="${RN_VMID:-951}"                               # the gateway CT
CT_SPOOL="${RN_CT_SPOOL:-/var/spool/retronet}"     # where CT 951's proxy journals misses
IDMAP_BASE="${RN_IDMAP_BASE:-100000}"              # unprivileged LXC uid offset
RNPROXY_UID="${RN_PROXY_UID:-997}"                 # rnproxy inside CT 951
CRAWL_GID="${RN_CRAWL_GID:-1000}"                  # host wnt = CT 950's crawl user

say() { printf '  %s\n' "$*"; }

# 1) the dataset ------------------------------------------------------------
if zfs list -H -o name "$POOL_DS" >/dev/null 2>&1; then
  say "dataset $POOL_DS exists"
else
  say "creating dataset $POOL_DS (quota $QUOTA, mountpoint $VOL)"
  zfs create -o "mountpoint=$VOL" -o "quota=$QUOTA" "$POOL_DS"
fi
zfs set "quota=$QUOTA" "$POOL_DS"
chown "$((IDMAP_BASE + RNPROXY_UID)):$CRAWL_GID" "$VOL"
chmod 2775 "$VOL"
say "owner $((IDMAP_BASE + RNPROXY_UID)):$CRAWL_GID mode 2775 on $VOL"

# 2) bind-mount into the gateway CT -----------------------------------------
if pct config "$CT" | grep -q "mp=$CT_SPOOL"; then
  say "CT $CT already bind-mounts the spool — skipping mount"
else
  slot=mp1
  pct config "$CT" | grep -q '^mp1:' && slot=mp2
  say "adding bind-mount $slot $VOL -> $CT:$CT_SPOOL and restarting CT $CT"
  pct set "$CT" "-$slot" "$VOL,mp=$CT_SPOOL,backup=0"
  timeout 90 pct reboot "$CT" || {
    pct stop "$CT" || true
    sleep 2
    pct start "$CT"
  }
fi

# 3) verify — the write itself, from the account that will do it ------------
for _ in $(seq 1 40); do
  [ "$(pct status "$CT" | awk '{print $2}')" = running ] && break
  sleep 1
done
got=$(pct exec "$CT" -- findmnt -no SOURCE "$CT_SPOOL" 2>/dev/null || true)
[ "$got" = "data/vms/retronet-requests" ] &&
  say "mount OK: $CT_SPOOL <- $got" ||
  say "WARN: $CT_SPOOL source is '$got', expected data/vms/retronet-requests"
# The acceptance that matters: can rnproxy actually create the journal? Anything
# less (the dir exists, the mount is there) is what let this ship broken before.
if pct exec "$CT" -- runuser -u rnproxy -- test -w "$CT_SPOOL"; then
  say "PASS: rnproxy can write $CT_SPOOL — misses will be journalled"
else
  say "FAIL: rnproxy CANNOT write $CT_SPOOL — station requests will not reach the crawl"
  exit 1
fi
zfs list -o name,used,avail,quota "$POOL_DS"

#!/usr/bin/env bash
# install-corpus-volume.sh — create the big retronet web corpus volume and wire
# it into the gateway CT (951). Idempotent; re-running is the repair path.
#
# WHY a volume: CT 951's rootfs is only 8 GB, far too small for a ~10 GB corpus.
# The corpus instead lives in a ZFS dataset on the `data` pool and is bind-mounted
# into CT 951 at the proxy's corpus path. It is placed UNDER /data/vms because the
# dev container CT 950 already bind-mounts /data/vms (recursively), so CT 950 sees
# the volume WITHOUT a restart and era-press can write the crawl straight into it
# while CT 951's proxy reads it live. The one restart this needs is CT 951's, to
# apply its bind-mount.
#
# RUNS ON LABHOST (needs zfs + pct). From a workstation:
#   ssh lab '/data/kernel-hive/scripts/retronet/web/install-corpus-volume.sh'
#
# As-built: docs/lab/retronet/ERA-PRESS.md.
set -euo pipefail

POOL_DS="${RN_CORPUS_DS:-data/vms/retronet-corpus}" # ZFS dataset name
VOL="${RN_CORPUS_VOL:-/data/vms/retronet-corpus}"   # labhost/CT 950 path (CT 950 sees it via /data/vms)
QUOTA="${RN_CORPUS_QUOTA:-20G}"                     # headroom over the ~10 GB crawl budget
OWNER="${RN_CORPUS_UID:-1000}"                      # CT 950's wnt writes the crawl; world-readable for the proxy
CT="${RN_VMID:-951}"                                # the gateway CT
CT_CORPUS="${RN_CT_CORPUS:-/data/retronet/corpus}"  # where CT 951's proxy reads the corpus

say() { printf '  %s\n' "$*"; }

# 1) the dataset ------------------------------------------------------------
if zfs list -H -o name "$POOL_DS" >/dev/null 2>&1; then
  say "dataset $POOL_DS exists"
else
  say "creating dataset $POOL_DS (quota $QUOTA, mountpoint $VOL)"
  zfs create -o "mountpoint=$VOL" -o "quota=$QUOTA" "$POOL_DS"
fi
zfs set "quota=$QUOTA" "$POOL_DS"
chown "$OWNER:$OWNER" "$VOL"
chmod 0755 "$VOL"

# 2) migrate the existing in-CT corpus the FIRST time, BEFORE the bind-mount
#    shadows it — the proxy must never blink to an empty corpus. ------------
if pct config "$CT" | grep -q "mp=$CT_CORPUS"; then
  say "CT $CT already bind-mounts the corpus volume — skipping migrate + mount"
else
  if [ -z "$(ls -A "$VOL" 2>/dev/null)" ] && pct exec "$CT" -- test -d "$CT_CORPUS"; then
    n=$(pct exec "$CT" -- sh -c "find $CT_CORPUS -type f 2>/dev/null | wc -l")
    say "migrating $n existing corpus file(s) from CT $CT rootfs -> $VOL"
    pct exec "$CT" -- tar -C "$CT_CORPUS" -cf - . | tar -C "$VOL" -xf -
    chown -R "$OWNER:$OWNER" "$VOL"
    chmod -R a+rX "$VOL"
  fi
  # 3) bind-mount + restart to apply (backup=0: never dump 10 GB into vzdump)
  say "adding bind-mount mp0 $VOL -> $CT:$CT_CORPUS and restarting CT $CT"
  pct set "$CT" -mp0 "$VOL,mp=$CT_CORPUS,backup=0"
  timeout 90 pct reboot "$CT" || {
    pct stop "$CT" || true
    sleep 2
    pct start "$CT"
  }
fi

# 4) verify -----------------------------------------------------------------
for _ in $(seq 1 40); do
  [ "$(pct status "$CT" | awk '{print $2}')" = running ] && break
  sleep 1
done
src="data/vms/retronet-corpus"
got=$(pct exec "$CT" -- findmnt -no SOURCE "$CT_CORPUS" 2>/dev/null || true)
[ "$got" = "$src" ] && say "mount OK: $CT_CORPUS <- $got" || say "WARN: $CT_CORPUS source is '$got', expected '$src'"
say "corpus files visible in CT $CT: $(pct exec "$CT" -- sh -c "find $CT_CORPUS -type f 2>/dev/null | wc -l")"
zfs list -o name,used,avail,quota "$POOL_DS"

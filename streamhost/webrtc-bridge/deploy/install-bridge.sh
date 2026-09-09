#!/usr/bin/env bash
# install-bridge.sh — put a freshly built bridge binary + unit + env live on the box.
#
# Runs ON labhost (root). Usage:
#   install-bridge.sh <path-to-new-binary> [<repo-root>]
#
# What it does, in order, and stops at the first failure:
#   1. resolves the public address from registry/local.env SH_GALLERY_HOST
#      (falls back to an already-present /etc/osgallery-webrtc/bridge.env),
#      writes /etc/osgallery-webrtc/bridge.env (0640, root) — box state, never
#      committed (AGENTS.md rule 1);
#   2. backs up the live binary with a timestamp, installs the new one;
#   3. installs the unit, daemon-reload, restarts the bridge;
#   4. proves it: ss -lun must show the bridge's -udp-port, /healthz must answer.
# The restart drops every open WebRTC peer (the fallback transport only);
# WebTransport stations are untouched.
set -euo pipefail
new_bin="${1:?usage: install-bridge.sh <new-binary> [repo-root]}"
repo="${2:-/data/vms/streamhost}"
unit_src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/osgallery-webrtc-bridge.service"
live_bin=/data/vms/streamhost/webrtc/bin/osgallery-webrtc-bridge
env_dir=/etc/osgallery-webrtc
env_file=$env_dir/bridge.env
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

[ -x "$new_bin" ] || {
  echo "install-bridge: $new_bin is not executable" >&2
  exit 2
}
udp_port="$(sed -n 's/^ *-udp-port \([0-9]*\).*/\1/p' "$unit_src")"
[ -n "$udp_port" ] || {
  echo "install-bridge: no -udp-port in $unit_src" >&2
  exit 2
}

# 1. the public address
public_ip=""
if [ -r "$repo/registry/local.env" ]; then
  host="$(sed -n 's/^SH_GALLERY_HOST=//p' "$repo/registry/local.env" | tail -1)"
  if [ -n "$host" ] && [ "$host" != "gallery.example.com" ]; then
    public_ip="$(getent ahostsv4 "$host" | awk 'NR==1{print $1}')"
  fi
fi
if [ -z "$public_ip" ] && [ -r "$env_file" ]; then
  public_ip="$(sed -n 's/^WEBRTC_PUBLIC_IP=//p' "$env_file" | tail -1)"
fi
[ -n "$public_ip" ] || {
  echo "install-bridge: cannot resolve the public address (SH_GALLERY_HOST in $repo/registry/local.env)" >&2
  exit 3
}
install -d -m 0755 "$env_dir"
umask 027
printf '# written by install-bridge.sh %s from SH_GALLERY_HOST; never commit\nWEBRTC_PUBLIC_IP=%s\n' "$stamp" "$public_ip" >"$env_file.tmp"
mv "$env_file.tmp" "$env_file"

# 2. binary, with a timestamped backup of what was live
if [ -f "$live_bin" ]; then
  cp -p "$live_bin" "$live_bin.bak-$stamp"
  echo "install-bridge: backed up $live_bin -> $live_bin.bak-$stamp"
fi
install -m 0755 "$new_bin" "$live_bin"

# 3. unit
install -m 0644 "$unit_src" /etc/systemd/system/osgallery-webrtc-bridge.service
systemctl daemon-reload
systemctl restart osgallery-webrtc-bridge.service

# 4. proof
sleep 1
if ! ss -lun | grep -q ":$udp_port "; then
  echo "install-bridge: bridge is NOT listening on udp/$udp_port" >&2
  systemctl --no-pager status osgallery-webrtc-bridge.service | tail -15 >&2
  exit 4
fi
curl -fsS http://127.0.0.1:18080/healthz >/dev/null
echo "install-bridge: live on udp/$udp_port, public candidate from ${public_ip%.*.*}.x.x"

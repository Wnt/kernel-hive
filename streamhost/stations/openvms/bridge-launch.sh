#!/bin/bash
# Lean X root client. OpenVMS supplies DECW$MWM and all visible applications.
set -u
xset s off -dpms s noblank 2>/dev/null || true
xsetroot -solid '#202a36' 2>/dev/null || true
while :; do
  sleep 3600
done

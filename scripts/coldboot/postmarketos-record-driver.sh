#!/bin/bash
# Clone-only phosh greeter driver. The login value stays in the environment.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}/postmarketos-driver"
PIN="${POSTMARKETOS_RECORD_PIN:?export POSTMARKETOS_RECORD_PIN for the clone login}"
[[ "$PIN" =~ ^[0-9]+$ ]] || br_die "postmarketos driver: PIN must contain digits only"
mkdir -p "$WORK"

# UEFI + phosh is deliberately given a wide cold-boot window. Confirm the real
# portrait framebuffer before entering anything so keys cannot hit firmware.
portrait=0
for i in $(seq 1 90); do
  shot="$WORK/wait-$i.png"
  br_screendump "$QMP" "$shot" || {
    sleep 2
    continue
  }
  if [ "$(identify -format '%wx%h' "$shot" 2>/dev/null || true)" = "720x1440" ]; then
    portrait=1
    break
  fi
  sleep 2
done
[ "$portrait" -eq 1 ] || br_die "postmarketos driver: 720x1440 phosh greeter not reached"
sleep 5
for ((i = 0; i < ${#PIN}; i++)); do
  br_hmp "$QMP" "sendkey ${PIN:i:1}" >/dev/null
done
br_hmp "$QMP" 'sendkey ret' >/dev/null
sleep 20
br_screendump "$QMP" "$WORK/ready.png" || br_die "postmarketos driver: final framebuffer capture failed"

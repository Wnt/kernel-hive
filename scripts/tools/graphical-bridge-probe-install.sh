#!/usr/bin/env bash
# Guest-side overlay installer used by graphical-bridge.sh's reference probe.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y --no-install-recommends build-essential libx11-dev
cc -O2 -Wall -Wextra -Werror \
  -o /usr/local/bin/graphical-bridge-pointer-probe \
  "$GB_PAYLOAD_DIR/graphical-bridge-pointer-probe.c" -lX11
test -x /usr/local/bin/graphical-bridge-pointer-probe

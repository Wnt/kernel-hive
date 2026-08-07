#!/usr/bin/env bash
# Full-screen reference client for the graphical-bridge absolute-pointer gate.
set -euo pipefail

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export SDL_VIDEODRIVER=x11
exec /usr/local/bin/graphical-bridge-pointer-probe

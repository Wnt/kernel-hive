#!/usr/bin/env bash
# rn-onboard.sh — join one station to the retronet. Dry-run unless --apply.
#
#   scripts/retronet/rn-onboard.sh <id> --address 10.99.0.N --mac <mac> \
#       [--uin <uin>] [--client <key>] [--static] [--planes web,icq] [--apply]
#
# The name is the interface every wave brief and doc refers to; the tool itself
# is Python next door, because its two load-bearing behaviours — rendering the
# containment template and REFUSING to commit a real MAC or address — are only
# worth having if they are unit-tested (scripts/test_rn_onboard.py).
set -euo pipefail
exec python3 "$(dirname "$(readlink -f "$0")")/rn_onboard.py" "$@"

#!/bin/bash
# =============================================================================
# tiles/nokia9300rom.sh — stage the nokia9300rom station: the nokia9300
# station's ROM window-server COMPARISON sibling (agent D5, 2026-09-25). It is
# tiles/nokia9300.sh with this station's paths, uid base and fork pin:
#
#   * EKA2L1 from fork branch s80-rom-full (Z4 worker F): ROM boot (A), ROM
#     input (B), the ROM window bridge (D) and ROM FBS (E) on s80-integration
#     @ b1fec4a28. The launcher sets EKA2L1_ROM_WSERV=1 EKA2L1_ROM_FBS=1 from
#     the fixture's NOKIA_EMU_ENV.
#   * the SAME golden v3.1 ledger as nokia9300 (its own copy under
#     $STATION/golden), plus GOLDEN_OVERLAY = C:\System\Programs\SysState.exe
#     (Z4 worker F's rebuild of tools/s80-sysstate at s80-rom-full 20ee52b11:
#     sha256 6e8b2068…fac0), which the ROM window server's STARTUP directive
#     launches; it also feeds the ROM window bridge. Staged on the box at
#     /data/assets-staging/symbian-s80/nokia9300rom-overlay with its manifest.
#   * uid base 2686976 (41 x 65536, `kh-claim uidbase 2686976`).
#
# Re-pin: point EKA2L1_FORK_BRANCH/EKA2L1_FORK_PIN at the new fork head
# below (and the station row's emulator.source), then
#   scripts/dev/labrun -c 'bash <repo>/scripts/build-guests/tiles/nokia9300rom.sh --build'
#   ssh lab 'systemctl restart streamhost@nokia9300rom'
# usage: nokia9300rom.sh [--build] [--rootfs] [--golden]   (as nokia9300.sh)
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export OUT="${OUT:-/data/vms/streamhost/assets/nokia9300rom}"
export STATION="${STATION:-/data/vms/streamhost/stations/nokia9300rom}"
export UIDBASE="${UIDBASE:-2686976}"
export GOLDEN_OVERLAY="${GOLDEN_OVERLAY:-/data/assets-staging/symbian-s80/nokia9300rom-overlay}"
# Own source/build tree (the live station's stays at its own pin); the trixie
# build root is nokia9300's, entered read-mostly (package set unchanged = no apt).
export WORK="${WORK:-/data/vms/sandbox/BUILD-eka2l1-rom}"
export BUILDROOT="${BUILDROOT:-/data/vms/sandbox/s80-eka2l1/buildroot}"
export EKA2L1_FORK_BRANCH="${EKA2L1_FORK_BRANCH:-s80-rom-full}"
export EKA2L1_FORK_PIN="${EKA2L1_FORK_PIN:-20ee52b1182f5b7e6fea2c2ac33e56be8f1087c9}"
exec bash "$HERE/nokia9300.sh" "$@"

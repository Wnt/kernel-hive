#!/bin/bash
# =============================================================================
# tiles/nokia9300rom.sh — stage the nokia9300rom station: the nokia9300
# station's ROM window-server COMPARISON sibling (agent D5, 2026-09-25). It is
# tiles/nokia9300.sh with this station's paths, uid base and fork pin:
#
#   * EKA2L1 from fork branch s80-rom-station = s80-rom-boot (Z4 worker A:
#     the ROM's own ewsrv.exe behind EKA2L1_ROM_WSERV=1, controlled startup via
#     the resident SysState helper; = s80-integration @ b1fec4a28 + the ROM
#     track) + s80-rom-input (Z4 B, ROM raw input) + s80-rom-apps (Z4 D, the
#     ROM window bridge for ekactl list/focus/switch). The launcher sets
#     EKA2L1_ROM_WSERV=1 from the fixture's NOKIA_EMU_ENV.
#   * the SAME golden v3.1 ledger as nokia9300 (its own copy under
#     $STATION/golden), plus GOLDEN_OVERLAY = C:\System\Programs\SysState.exe
#     (Z4 worker D's build of tools/s80-sysstate at s80-rom-apps 93961ef8e:
#     sha256 77a7d8c1…98d2), which the ROM window server's STARTUP directive
#     launches; it also feeds the ROM window bridge. Staged on the box at
#     /data/assets-staging/symbian-s80/nokia9300rom-overlay with its manifest.
#   * uid base 2686976 (41 x 65536, `kh-claim uidbase 2686976`).
#
# Re-pin (e.g. when s80-rom-fbs lands): merge into s80-rom-station, push, change EKA2L1_FORK_PIN
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
export EKA2L1_FORK_BRANCH="${EKA2L1_FORK_BRANCH:-s80-rom-station}"
export EKA2L1_FORK_PIN="${EKA2L1_FORK_PIN:-ac7c1e126109d799306d070c25e8a9641f431137}"
exec bash "$HERE/nokia9300.sh" "$@"

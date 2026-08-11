#!/usr/bin/env bash
# Overlay installer for the SGI IRIX 6.5 graphical-kiosk (issue #20).
# Runs as root INSIDE the thin bookworm overlay (never the frozen base).
#
# Installs a prebuilt bookworm MAME 0.288 (git master; 0.276 has a fatal
# indy GIO2/UTLB emulation panic), fetches the Indy PROM + IRIX 6.5 CHD from
# archive.org, and stages a pre-initialised PROM NVRAM (eaddr/monitor/date) so
# IRIX boots straight to the 4Dwm desktop with no PROM interaction.
#
# Payload (staged at $GB_PAYLOAD_DIR by graphical-bridge.sh --payload-dir):
#   sgi            - the bookworm MAME 0.288 binary (SGI subtarget)
#   nvram/*        - pre-set indy_4610 NVRAM (eeprom + rtc)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PAYLOAD="${GB_PAYLOAD_DIR:?GB_PAYLOAD_DIR unset}"
MEDIA_BASE="https://archive.org/download/irix65.7z"

apt-get update -o Acquire::Retries=3
# MAME 0.288 runtime libs (built against bookworm) + extraction/download tools.
apt-get install -y --no-install-recommends \
  libsdl2-2.0-0 libsdl2-ttf-2.0-0 libfontconfig1 libpulse0 \
  p7zip-full curl ca-certificates \
  matchbox-window-manager xdotool

# --- MAME 0.288 binary (from payload) ---
install -D -m 0755 "$PAYLOAD/sgi" /opt/mame/sgi
/opt/mame/sgi -version || true

# --- Indy PROM romset + IRIX 6.5 CHD (from archive.org) ---
mkdir -p /opt/irix/roms/indy_4610 /opt/irix/nvram/indy_4610 /opt/irix/diff
work="$(mktemp -d)"
cd "$work"
curl -fsSL -o indy_4610.7z "$MEDIA_BASE/indy_4610.7z"
curl -fsSL -o irix65.7z "$MEDIA_BASE/irix65.7z"
7z x -y indy_4610.7z >/dev/null  # -> indy_4610.zip
7z x -y indy_4610.zip >/dev/null # -> indy_4610/<proms>
cp -f indy_4610/*.bin indy_4610/*.zm82 /opt/irix/roms/indy_4610/ 2>/dev/null ||
  cp -f indy_4610/ip24prom* /opt/irix/roms/indy_4610/
7z x -y irix65.7z >/dev/null # -> irix65.chd
mv -f irix65.chd /opt/irix/irix65.chd
cd /
rm -rf "$work"

# --- Pre-initialised PROM NVRAM (eaddr/monitor/date already set) ---
cp -f "$PAYLOAD"/nvram/* /opt/irix/nvram/indy_4610/ 2>/dev/null || true

# ui.ini (read via MAME -inipath /opt/irix): skip the "imperfect emulation" startup
# warning. The MAME build is patched so this flag always skips it.
printf 'skip_warnings 1\n' >/opt/irix/ui.ini

# Verify the romset MAME will use.
/opt/mame/sgi -bios b10 -rompath /opt/irix/roms -verifyroms indy_4610 || true

ls -la /opt/mame/sgi /opt/irix/irix65.chd /opt/irix/roms/indy_4610/ /opt/irix/nvram/indy_4610/
echo "irix-bridge-install: done"

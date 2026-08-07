#!/bin/sh
# ==== postmarketOS phosh GOLDEN TEST FIXTURE setup ====
# Runs at every phosh login (~/.config/autostart/zz-golden-fixture.desktop). Idempotent.
#  - never blank / DPMS-off / never auto-suspend / never lock (no black-on-idle)
#  - steady caret + no GTK animations (byte-stable when idle)
#  - on-screen keyboard OFF (fixture drives a hardware keyboard via QMP)
#  - open GNOME Console as the deterministic input-reactive surface
for i in $(seq 1 30); do
  gsettings get org.gnome.desktop.session idle-delay >/dev/null 2>&1 && break
  sleep 1
done
gsettings set org.gnome.desktop.session idle-delay 'uint32 0'
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false
gsettings set org.gnome.desktop.interface cursor-blink false
gsettings set org.gnome.desktop.interface enable-animations false
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false
gsettings set mobi.phosh.PhoshTour last-shown-version '99.0' 2>/dev/null || true
if ! pgrep -x kgx >/dev/null 2>&1; then
  (kgx >/dev/null 2>&1 &) || (gapplication launch org.gnome.Console >/dev/null 2>&1 &)
fi
exit 0

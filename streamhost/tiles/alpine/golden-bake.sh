#!/bin/bash
# (Re)bake the 'golden' snapshot for tile alpine from a COLD LiveCD boot.
# Use after a bare-metal/NVMe rebuild that wiped state.qcow2. Assumes the tile's
# QEMU is freshly launched WITHOUT a golden snapshot (cold boot to login prompt).
#   1) bash tiles/alpine/qemu-streamhost.sh    # cold boot (no -loadvm; snapshot absent)
#   2) bash tiles/alpine/golden-bake.sh        # this script
set -e
BASE=/data/vms/streamhost/tiles/alpine
SK="python3 $BASE/sk.py $BASE/qmp.sock"
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
type_line() {
  $SK text64 "$(b64 "$1")"
  $SK key ret
  sleep 0.4
}
echo "[bake] waiting for LiveCD to reach the login prompt..."
sleep 35
# Alpine LiveCD: log in as root (no password)
$SK key ret
type_line "root"
sleep 2
# --- fixture tweaks (idempotent), baked into the guest as /root/fixture-tweaks.sh ---
type_line "cat > /root/fixture-tweaks.sh <<'EOF'"
type_line "#!/bin/sh"
type_line "# Alpine golden test fixture tweaks (idempotent). Captured in savevm 'golden'."
type_line "echo 0 > /sys/class/graphics/fbcon/cursor_blink   # steady caret: kill only idle animation"
type_line "printf '\\033[9;0]\\033[14;0]' > /dev/tty1         # no console blank / no VESA powerdown"
type_line "EOF"
type_line "chmod +x /root/fixture-tweaks.sh; sh /root/fixture-tweaks.sh"
# --- clean banner (the keyboard-reactive fixture surface) ---
type_line "cat > /root/banner <<'EOF'"
type_line "  ============================================================"
type_line "   ALPINE LINUX 3.24  --  GOLDEN TEST FIXTURE (resetMode=loadvm)"
type_line "  ============================================================"
type_line "   Keyboard-reactive surface: type below. Characters echo at the"
type_line "   steady (non-blinking) caret; Left/Right arrows move the caret."
type_line "   Reset: QMP 'loadvm golden' restores this exact screen, live."
type_line "  ============================================================"
type_line "EOF"
type_line "clear; cat /root/banner"
sleep 1
echo "[bake] savevm golden ..."
python3 "$BASE/qmp.py" "$BASE/qmp.sock" '[{"execute":"human-monitor-command","arguments":{"command-line":"savevm golden"}}]'
python3 "$BASE/qmp.py" "$BASE/qmp.sock" '[{"execute":"human-monitor-command","arguments":{"command-line":"info snapshots"}}]'
echo "[bake] done. Future launches auto -loadvm golden (see qemu-streamhost.sh)."

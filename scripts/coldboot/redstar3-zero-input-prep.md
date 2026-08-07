# Red Star OS 3.0 Desktop boot capture — zero-input prep

Status: **LIVE CAPTURE VERIFIED 2026-07-16**.

The production fixture is a logged-in, modal-free 1024×768 KDE desktop.  Its
top menu, green wallpaper, and macOS-like dock are visible, and the absolute
USB tablet is parked at the dock's lower-right reveal edge.  The golden has no
audio device and no network device.

Cold boot needs no operator input.  The offline build helper enables KDM auto-login
for `gallery` because Red Star's `kdmgreet` crashes under QEMU, disables the
power-manager/mixer/integrity-checker autostarts that otherwise create delayed
modals, and persists the audio warning's own "do not show again" choice.  The
shipping disk can still show that no-audio notice on a true cold boot, so the
clone-only `redstar3-record-driver.sh` detects its red close control in the real
framebuffer, accepts the focused dialog with Enter, and parks the USB tablet at
the golden's lower-right edge.  This requires no credential.  A from-disk boot
then reaches the same desktop in roughly two minutes.

The `redstar3` arm copies
`/data/gallery-guests/RedStar3/redstar3.qcow2` into its namespaced bootrec clone,
rewrites the launcher to that copy, and removes `-loadvm golden`.  It never
attaches the live writable disk.  Canvas is 1024×768 at 30 fps, without audio;
the driver is followed by a 45-second desktop redraw/settle hold with a
90-second detection cap.

The dry-run clone launcher was inspected for the pinned
`pc-i440fx-11.0`/`Nehalem,kvm=off`/cirrus/IDE/USB-tablet device set and contained
`-nodefaults` with no `-netdev`, `-nic`, network `-device`, or `hostfwd`.  The
real capture must still be inspected and its last frame compared with the
parked-pointer live golden fixture; do not publish on timing alone.

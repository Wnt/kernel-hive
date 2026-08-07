# Red Star OS 2.0 boot capture — zero-input prep

Status: **PUBLISHED + FRAMEBUFFER/SEAM-PROVEN 2026-07-16**.

The production fixture is a logged-in, modal-free 1024×768 KDE desktop for
`gallery`. KDM auto-login is enabled by an offline qcow2 edit; no password or
guest input is needed. The KDE profile disables the screensaver and removes the
panel clock, so the handoff frame is static. The final guest has no audio device
and, by policy, no network device or backend.

A cold disk boot requires no guest input and reaches the same KDE desktop in
roughly 30 seconds. The installed Xorg configuration pins the Cirrus driver at
depth 16 with software cursor/no acceleration and binds the QEMU USB Tablet
through the corrected evdev absolute path. No first-run wizard or delayed
desktop modal is part of the boot path. Cold-boot and golden-first-frame
screenshots measured SSIM 1.000000 on the real framebuffer.

The `redstar2` bootrec arm copies
`/data/gallery-guests/RedStar2/redstar2.qcow2` into its namespaced clone and
rewrites the cloned launcher to that copy. The recorder removes `-loadvm golden`
for the cold boot; it never attaches the live writable disk. Canvas is 1024×768
at 30 fps without audio. Detection uses a conservative 60-second fixed hold and
a 120-second hard cap.

Before a real capture, run `record-boot.sh redstar2 --dry-run` and inspect the
clone launcher for `pc-i440fx-11.0`, `-cpu host`, Cirrus, IDE, and USB tablet.
It must retain `-nodefaults` and contain no `-netdev`, `-nic`, network `-device`,
or `hostfwd`. A clip may be published only when its last frame matches the
logged-in KDE golden fixture; timing alone is not a release gate.

The published 61.133-second clip passed the clone `savevm`/`loadvm` seam gate
at SSIM 1.000000. Its cold-boot poster is pixel-identical to the production
golden first frame; decoded H.264 frame 1834/1834 measured SSIM 0.994612
against it. `/boot/redstar2/` serves the MP4, poster, sprite, and WebVTT, and the
HTTP range/VTT scrub checks pass.

# pet2001 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `pet2001)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5824→6824. Before recording it stops `getty@tty1`
and `xpet` over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The PET 2001's
ROM comes up unattended at `*** COMMODORE BASIC *** / 7167 BYTES FREE /
READY.`, which is exactly what the golden holds — so a clip's last frame would
hand off to the golden's first frame cleanly. Nothing is typed at any point.

Ready means an **800×600** capture (not the 720×400 VGA text mode the Linux
boot passes through) carrying those three lines of blue-white phosphor and the
block cursor, and nothing else. `scripts/build-guests/tiles/pet2001.sh` states the
same predicate numerically: geometry exactly 800×600 **and** 1200–4000 lit
pixels. The geometry half is not decoration — GRUB's `Booting 'Debian
GNU/Linux'` screen sits inside the pixel band and was mistaken for the fixture
once already.

Canvas is the QEMU kiosk's scanout at 30 fps; the X root is 800×600. Audio flows
via ALSA/AC97 but the exhibit is silent: the 1977 PET had no sound hardware.

**A cold boot shows Linux, and the golden never does.** With the golden present
the launcher boots straight into it (`-loadvm golden`), so GRUB and the kernel
messages are visible only in a deliberate cold-boot recording. If a clip is ever
published, trim to the moment the 800×600 X root appears.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

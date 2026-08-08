# plus4 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `plus4)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5822→6822. Before recording it stops `getty@tty1`
and `xplus4` over clone SSH; after capture it starts the kiosk again. Bridge
kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The Plus/4's
ROM comes up unattended at `COMMODORE BASIC V3.5 / 60671 BYTES FREE /
3-PLUS-1 ON KEY F1 / READY.`, which is exactly what the golden holds — so a
clip's last frame would hand off to the golden's first frame cleanly. (This was
not true of the tile's first golden, which was curated inside the 3-plus-1
suite; that fixture was replaced because it dropped visitors into the middle of
an application.)

Ready means the white page inside its lavender border with all four lines
painted and the cursor present. Canvas is the QEMU
kiosk's scanout at 30 fps; the X root is 800×600. TED audio flows via ALSA/AC97.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

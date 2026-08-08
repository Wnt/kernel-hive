# plus4 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `plus4)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5822→6822. Before recording it stops `getty@tty1`
and `xplus4` over clone SSH; after capture it starts the kiosk again. Bridge
kind intentionally skips `savevm`.

**Zero input is genuine, but note what a cold boot reaches.** The Plus/4's ROM
comes up unattended at `COMMODORE BASIC V3.5 / 3-PLUS-1 ON KEY F1 / READY.` —
*not* at the exhibit's fixture. The 3-plus-1 suite is a curated state produced
by `scripts/build-guests/plus4.sh` and restored only by `loadvm golden`, which
is why this tile's `resetMode` is `loadvm`. A boot clip for this tile therefore
ends on the BASIC prompt and would NOT hand off seamlessly to the golden's
first frame; publishing one needs the clip to continue into the F1+RETURN and
`C=`+`C`,`tc` sequence, or the playbook's last-frame rule is broken. That is
the reason no clip is published today.

Ready (for a BASIC-prompt capture) means the white page inside its lavender
border with all three lines painted and the cursor present. Canvas is the QEMU
kiosk's scanout at 30 fps; the X root is 800×600. TED audio flows via ALSA/AC97.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

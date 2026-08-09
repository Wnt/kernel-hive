# dragon32 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `dragon32)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5833→6833. Before recording it stops `getty@tty1`
and the kiosk's MAME process over clone SSH; after capture it starts the kiosk
again. Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** Nothing is
curated into this tile: the Dragon's ROM comes up unattended at
`(C) 1982 DRAGON DATA LTD / 16K BASIC INTERPRETER 1.0 / (C) 1982 BY MICROSOFT /
OK`, which is exactly what the golden holds, so a clip's last frame would hand
off to the golden's first frame cleanly.

Ready means those three banner lines and the `OK` prompt painted in dark green
on the MC6847's bright green page, inside the Dragon's own darker border.
Canvas is the QEMU kiosk's scanout at 30 fps; the X root is 1024×768 and MAME
fills it with aspect correction on. The 6-bit DAC's output flows via ALSA/AC97,
and at idle it is silent — a clip of this boot has an audio track with nothing
on it, which is correct.

**The kiosk process is named `dragon`, not `mame`.** The shipped binary is a
MAME 0.289 `SUBTARGET=dragon` build (scripts/build-guests/build-mame-dragon32.sh)
installed as `/opt/dragon32/mame/dragon`, so `pkill -u bridge mame` — the string
the mpf2 arm uses — matches nothing here and the prep step would silently do
nothing. `BR_EMU_PREP_CMD` below kills `dragon`.

**If a recorded clip ever shows `DRAGONDOS 1.0` instead of the banner**, the
guest's `/etc/bridge/launch.sh` has lost its `-ext ""` and the exhibit is
booting the disk operating system. That is a tile fault, not a capture fault;
see `docs/guests/dragon32.md`.

# vic20 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip has been recorded and `spa.bootVideo` is
not set in `registry/tiles/vic20.json`; this file and the `vic20)` arm in
`bootrec-tiles.conf` exist so the cold-boot path is audited and ready, which is
what the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5821→6821. Before recording it stops `getty@tty1` and `xvic`
over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`: every visit cold-boots the emulator.

**Zero input is genuine.** The VIC-20 has nothing to answer at power-on: the
ROM prints its banner and the `READY.` prompt and stops. The Debian kiosk around
it needs no input either — GRUB is silent on serial with a zero timeout, the
kernel boots quiet, `agetty` auto-logs in the `bridge` user, and
`.bash_profile` execs `startx -- -nocursor`, which runs `/etc/bridge/launch.sh`
and therefore `xvic`. Nothing prompts, and nothing must be typed.

Ready means the cyan border, white paper, and all three lines of the power-on
screen (`**** CBM BASIC V2 ****`, `3583 BYTES FREE`, `READY.`) fully painted
with the cursor block present. Canvas is the QEMU kiosk's scanout at 30 fps;
the X root is 800×600 (VICE's SDL window is fixed and cannot grow), so a
recorded clip is letterboxed inside the declared 1024×768 canvas exactly as the
live tile is. VIC-I audio flows via ALSA/AC97 to AAC. The 45 s Tier-3 hold is
generous: the ROM itself is up within a second of `xvic` starting, and the wait
is really for the Debian boot underneath.

**Do not redirect the kiosk session's stdout when adapting this arm.** VICE 3.9
segfaults in `vice_banner()` whenever its stdout is not a terminal, before it
prints anything at all — see `scripts/build-guests/tiles/vic20.sh` and
`docs/guests/vic20.md`.

Reject any capture that shows the Linux console, a black emulator window, or a
screen that has scrolled past the banner.

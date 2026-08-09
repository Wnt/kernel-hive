# cbm8032 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `cbm8032)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5825→6825. Before recording it stops `getty@tty1`
and `xpet` over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The CBM 8032's
ROM comes up unattended at `*** commodore basic 4.0 *** / 31743 bytes free /
ready.`, which is exactly what the golden holds — so a clip's last frame would
hand off to the golden's first frame cleanly. Nothing is typed at any point.

**Ready means the SPARSE screen, not the first one.** The PET's screen RAM is
uninitialised at power-on and the CRTC paints all 2000 cells of random bytes as
random glyphs for a moment before the KERNAL clears them, so a "there is green
on the screen" test fires on a solid block of garbage (measured 375726 green
pixels, against the banner's 1985). Any readiness gate added to this arm must
test a BAND, the way `wait_for_basic()` in `scripts/build-guests/cbm8032.sh`
does — and a clip that starts before that moment will contain the garbage frame,
which is authentic but should not be the thumbnail.

Ready is therefore the three banner lines plus the block cursor, green on black,
with the X root at 1600×1200 and the emulated screen filling 1408×1064 of it.
Canvas is the QEMU kiosk's scanout at 30 fps. The AC97 path exists and carries
nothing: the 8032 has no sound generator.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

# zx81 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `zx81)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5831→6831. Before recording it stops `getty@tty1`
and the kiosk's MAME process over clone SSH; after capture it starts the kiosk
again. Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The ZX81 needs
no attention at all on the way up: the ROM initialises and stops at its `K`
cursor, which is precisely what the golden holds, so a clip's last frame hands
off to the golden's first frame with no seam and nothing typed in between.
There is no menu, no self-test, no key to acknowledge and no clock to differ.

**Ready is not "the screen is bright".** This is the one tile whose readiness
cannot be judged photometrically: a ZX81 blanks its display while it computes,
so an empty white field is a perfectly ordinary intermediate state and looks
exactly as bright as the finished one. Ready means *a white field carrying one
inverse-video block in the bottom-left character cell and no ink anywhere
else*, held still for three seconds — the `K` cursor does not blink, so a frame
that is still changing is not the fixture. That test is implemented once, in
`streamhost/stations/zx81/zx81-frame.py`, and any detector added to this arm
should call it rather than re-deriving a threshold:

```bash
python3 /data/vms/streamhost/stations/zx81/zx81-frame.py <frame.ppm> --assert idle
```

`BR_DETECT_TIER=3` (fixed timer) is therefore what the arm ships: tier 1's
change-fraction detector settles as happily on a blanked screen as on the
fixture, and tier 2 would need a reference crop of a single character cell.

Canvas is the QEMU kiosk's scanout at 30 fps; the X root is 1024×768 and MAME
draws the ZX81's 384×311 raster fullscreen with aspect correction, which fills
it exactly (4:3). AC97 is wired like every other bridge tile and carries
silence: the ZX81 has no sound hardware.

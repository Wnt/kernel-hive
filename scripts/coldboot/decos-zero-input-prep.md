# decos boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `decos)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5829→6829. Before recording it stops `getty@tty1`
and reaps any simulator over clone SSH; after capture it starts the kiosk again.
Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The golden is
the chooser and nothing else — no simulator is running inside it — and a cold
boot arrives at exactly that chooser, so a clip's last frame hands off to the
golden's first frame cleanly. Nothing is typed at any point.

Ready means the full placard painted: the 80-column rule of `=` drawn edge to
edge, all three numbered entries, and the line
`Press 1, 2 or 3.        Reset returns you to this screen.` The mechanical test
the builder uses is the same one to use here — `pnmcrop -black -verbose` on the
frame must report a lit bounding box spanning `x = 3…962` of 1024. Canvas is the
QEMU kiosk's scanout at 30 fps; the X root is 1024×768.

**The kiosk reaps orphaned simulators with `SIGKILL`, and the prep command must
too.** SIMH catches `SIGTERM`, stops the simulated CPU and then keeps spinning
at 100 % of a core; a plain `pkill -x pdp11` in a prep step would leave a busy
orphan poisoning the recording's own CPU baseline. Use
`pkill -u bridge -KILL -x pdp11`.

Audio: the AC97 card is in the device set, as it is for every bridge tile, but
nothing in this guest makes a sound. Record with `BR_HAS_AUDIO=1` for device-set
parity and expect silence.

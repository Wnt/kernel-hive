# gt40 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and a `gt40)` arm in `bootrec-tiles.conf` exist so the cold-boot path
is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5828→6828. Before recording it stops `getty@tty1`
and the `pdp11` simulator over clone SSH; after capture it starts the kiosk
again. Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and it is genuine in a stronger sense than on any other
tile: this machine has no keyboard at all.** The kiosk autologins, `startx`
runs `/etc/bridge/launch.sh`, and `pdp11` loads `lunar.lda`, deposits 1 in
location 32530 and `run`s. Nothing is typed at any stage, by the recorder or by
anyone else, because there is nothing to type at — the 1973 Lunar Lander reads
the VT11 light pen and nothing else.

**Ready** means the VT11 drawing a real picture: the mountainous horizon across
the bottom, four telemetry readouts across the top, the throttle bar and
rotation arrows at the right, and the full twelve-item menu column below them
(`HEIGHT` … `SECONDS`, ~5450 lit pixels in the rect `1035 755 120 268`). The
whole 1024x1024 window measures ~13 000 lit green pixels once the descent is
running; a bare X root or a dead simulator measures ~0. Canvas is the QEMU
kiosk's scanout; the X root is 1280x1024 and SIMH's window is centred at
`+128+0`.

**A cold boot does NOT land on the golden's frame, and that is expected.** The
golden is the first seconds of a *fresh* descent, reached by riding the
program's own crash-and-restart loop (~135 s), whereas a cold boot draws the
tape's **introductory message** first — a screen with no menu on it at all — and
only then starts flying. A clip that ends at "the VT11 is drawing" therefore
hands off to the golden's first frame with a visible jump. If a clip is ever
recorded for this tile, either let it run to the first self-restart before
cutting, or accept the cut and say so.

**Audio: there is none.** The AC97 card is in the device set for parity with the
other bridge tiles, but a VT11 has no sound hardware and the tape makes none. A
recorder that gates on non-silent audio will hang here.

**Do not add `-nocursor` when adapting this arm.** Every other bridge kiosk
starts X without a core pointer because it is a keyboard exhibit; this one is
the opposite, and the visible pointer is the light pen. The launcher also runs
`xsetroot -solid black -cursor_name left_ptr`, because the root window's default
cursor is the classic X "X" and the pointer rests on the root in the fixture.

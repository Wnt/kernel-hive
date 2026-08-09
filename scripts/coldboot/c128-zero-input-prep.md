# c128 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `c128)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5823→6823. Before recording it stops `getty@tty1`
and `x128` over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The C128's ROM
comes up unattended at `COMMODORE BASIC V7.0 122365 BYTES FREE / (C)1986
COMMODORE ELECTRONICS, LTD. / (C)1977 MICROSOFT CORP. / ALL RIGHTS RESERVED /
READY.` in the VDC's cyan on black, which is exactly what the golden holds — so
a clip's last frame would hand off to the golden's first frame cleanly.

**Do not shorten the hold to the first BASIC frame.** The kiosk attaches the
CP/M system disk to drive 8 about **10 seconds after VICE starts**, over VICE's
guest-local text monitor, and that attach is part of the fixture even though it
changes nothing on screen (`scripts/build-guests/c128.sh` explains why the disk
cannot simply be passed as `-8`: the KERNAL boots any CP/M disk it finds at
reset). A clip that ends before the attach would hand off to a golden whose
drive contents differ from the recorded machine's. Hold at least 20 s past the
BASIC screen, and confirm `/tmp/c128-attach.log` in the clone reads
`attached …` before treating the capture as complete.

Ready means the four banner lines plus `READY.` painted in cyan with the cursor
present — and **no magenta anywhere**, which is the discriminator against a
machine that has autobooted CP/M. Canvas is the QEMU kiosk's scanout at 30 fps;
the X root is 800×600 and VICE's 789×576 window fills it. SID audio flows via
ALSA/AC97.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

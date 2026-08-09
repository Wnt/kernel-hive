# cbm2 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `cbm2)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5826→6826. Before recording it stops `getty@tty1`
and `xcbm2` over clone SSH; after capture it starts the kiosk again. Bridge
kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The CBM 610's
ROM comes up unattended at `*** commodore basic 128, v4.0 ***` / `ready.`,
which is exactly what the golden holds — nothing is curated into it and nothing
is typed — so a clip's last frame would hand off to the golden's first frame
cleanly.

Ready means both lines painted in green on black with the block cursor present
beneath `ready.`, inside the native 704×528 emulator window centred on the
800×600 X root. Measured position of the lit text on the shipped geometry: rows
100..178, columns 80..342 of the captured frame (see
`scripts/build-guests/tiles/cbm2.sh`, `wait_for_basic`). Canvas is the QEMU kiosk's
scanout at 30 fps; the X root is 800×600. SID audio flows via ALSA/AC97.

**Do not add `-CRTCdsize` when adapting this arm.** With no window manager the
doubled 1408×1056 window is silently clipped by any root this fleet uses, and
because both the emulated screen and the bare X root are black the clipping is
invisible until you put a coloured root behind it.

**Do not redirect the kiosk session's stdout when adapting this arm** — VICE
3.9 segfaults in `vice_banner()` when stdout is not a terminal
(`docs/guests/vic20.md`).

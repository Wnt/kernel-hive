# kc854 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `kc854)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5835→6835. Before recording it stops `getty@tty1`
and the `kc85` MAME process over clone SSH; after capture it starts the kiosk
again. Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** CAOS 4.2 comes
up unattended at its own command menu and prompt, which is exactly what the
golden holds, so a clip's last frame would hand off to the golden's first frame
cleanly. Nothing is curated into the fixture and no key is posted after a
restore.

**The one thing that could make a clip lie.** kc85_4 is a `preliminary` driver,
so stock MAME opens it with a full-screen red "THIS SYSTEM DOESN'T WORK" panel
that `-skip_gameinfo` does not suppress. The tile ships a patched binary in
which `ui.ini`'s `skip_warnings 1` applies to that panel, and
`scripts/build-guests/kc854.sh`'s readiness predicate asserts the panel's red is
absent from the frame. If a future clip shows a red flash before the CAOS
screen, the deployed binary or `/opt/kc854/ui.ini` has regressed — do not
publish it, and do not "fix" it by trimming the clip.

Ready means the CAOS command menu painted in colour on black with the prompt
below it, and no red panel. Canvas is the QEMU kiosk's scanout at 30 fps; the X
root is 1024×768 and MAME fills it fullscreen with aspect correction. The KC's
speaker flows via ALSA/AC97.

Redirecting the kiosk session's stdout to a log file is safe here: that is a
VICE 3.9 fault (`docs/guests/vic20.md`), not a MAME one, and mpf2 does the same.

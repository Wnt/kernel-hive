# oricatmos boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `oricatmos)` arm in `bootrec-tiles.conf` exist so the
cold-boot path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared frozen base stays
read-only) and rewrites SSH 5834→6834. Before recording it stops `getty@tty1`
and the `oricatmos` MAME process over clone SSH; after capture it starts the
kiosk again. Bridge kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** The Atmos's ROM
comes up unattended at `ORIC EXTENDED BASIC V1.1 / (c) 1983 TANGERINE /
37631 BYTES FREE / Ready`, which is exactly what the golden holds — nothing is
curated into it and no post-restore keys are sent — so a clip's last frame
hands off to the golden's first frame cleanly.

Ready means the white page filling the frame with all three banner lines and
`Ready` painted, the `CAPS` marker in the top-right corner, and the cursor
present. Canvas is the QEMU kiosk's scanout at 30 fps; the X root is 800×600,
which is 4:3, so MAME's `-keepaspect` fills it with no black surround.
AY-3-8912 audio flows via ALSA/AC97.

**Two things a clip passes through on the way.** The kiosk's launcher re-asserts
the 800×600 mode after X starts (the base `.xinitrc` asks for it but has been
observed not to get it), and it then sleeps 2 s before exec'ing MAME. A capture
therefore shows a brief black root before the Oric appears; trim to the first
frame that has the white page in it.

The launcher also runs `xset r off`. That is not cosmetic: with X's typematic
repeat on, a late-delivered key release floods the emulated Oric with the held
key and then leaves it deaf (see `docs/guests/oricatmos.md`). A re-recorded clip
must be made against a golden that has the setting, which the current one does.

**Unlike the Commodore bridge tiles, redirecting the kiosk session's stdout is
safe here** — the segfault that forbids it on `vic20`/`plus4` is a VICE bug in
`vice_banner()`, not a MAME one, and this overlay's `.bash_profile` does send
the X log to a file.

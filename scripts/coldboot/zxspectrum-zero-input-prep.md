# zxspectrum boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip has been recorded and `spa.bootVideo` is
not set in `registry/tiles/zxspectrum.json`; this file and the `zxspectrum)` arm
in `bootrec-tiles.conf` exist so the cold-boot path is audited and ready, which
is what the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5830→6830. Before recording it stops `getty@tty1` and MAME over
clone SSH; after capture it starts the kiosk again. Bridge kind intentionally
skips `savevm`: every visit cold-boots the emulator.

**Zero input is genuine.** The ZX Spectrum has nothing to answer at power-on:
the ROM clears memory, paints the screen white and prints one line,
`© 1982 Sinclair Research Ltd`, and stops. There is no prompt and no cursor
until a key is pressed. The Debian kiosk around it needs no input either — GRUB
is silent on serial with a zero timeout, the kernel boots quiet, `agetty`
auto-logs in the `bridge` user, and `.bash_profile` execs
`startx -- -nocursor`, which runs `/etc/bridge/launch.sh` and therefore MAME.
Nothing prompts, and nothing must be typed.

Ready means the whole frame in the Spectrum's non-bright white (RGB ≈ 191,191,191
as QEMU dumps it) with the single black copyright line fully painted along the
bottom, and **nothing else** — no Linux console, no black emulator window, no
MAME warning panel. The builder's own predicate is the same shape and is worth
reusing when judging a capture: more than 600 000 paper pixels and more than 300
ink pixels in a 1024×768 dump.

**The hold has to be long.** On a first cold boot of a fresh overlay `xinit` was
observed sitting in *"waiting for X server to begin accepting connections"* for
about three minutes before the kiosk appeared, on a box under heavy load. A
warm overlay comes up in well under a minute, which is what the timings below
assume, but reject a capture that timed out rather than shortening the wait.

**A cold boot and a golden restore reach the SAME screen**, because the golden
is the untouched power-on frame and nothing is typed into it — so a clip hands
off to the live tile with no seam.

**Do not record a clip whose last frame shows a keyboard that does not work.**
This tile's failure mode is invisible in a picture: a kiosk MAME started at cold
boot is occasionally born deaf and ignores every key while rendering perfectly
(see `docs/guests/zxspectrum.md` §4). Any capture used as a boot clip should be
followed by a live `labctl` keystroke test on the same instance.

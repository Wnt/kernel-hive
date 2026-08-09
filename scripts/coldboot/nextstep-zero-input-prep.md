# nextstep boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip has been recorded and `spa.bootVideo` is
not set in `registry/tiles/nextstep.json`; this file and the `nextstep)` arm in
`bootrec-tiles.conf` exist so the cold-boot path is audited and ready, which is
what the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` — its shared base
`/data/vms/bridge/bridge-base.qcow2` stays read-only — and rewrites SSH
5837→6837. Before recording it stops `getty@tty1` and the `previous` emulator
over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`: every visit cold-boots the emulator.

**A cold boot is NOT pointer-equivalent to the live tile, and that is by
design.** The exhibit's absolute pointer comes from NeXTSTEP's own tablet driver,
a kernel server that is attached once at build time and carried by the `golden`
snapshot (`loadvm` restores RAM, it does not boot). A cold boot — which is what
this arm records — has no tablet driver and falls back to Previous's relative
mouse. Nothing in a boot capture touches the pointer, so the clip is unaffected;
but do not read a cold-booted nextstep as a working exhibit, and do not use this
arm to test input. `docs/guests/nextstep.md` §4 has the full asymmetry and the
one-command re-install.

**Zero input is genuine, but only from the second boot of a given disk image
onwards.** NeXTSTEP 3.3 runs a one-time Welcome panel (language + keyboard) the
very first time a fresh install boots; `scripts/build-guests/tiles/nextstep.sh`
answers it with two RETURNs during the build, and it never appears again. From
then on the machine boots to a Workspace with nothing to answer: NeXTSTEP logs
in automatically as the user `me`, there is no password prompt, and no dialog
waits for a click.

The Debian kiosk around it needs no input either — GRUB is silent on serial with
a zero timeout, the kernel boots quiet, `agetty` auto-logs in the `bridge` user,
`.bash_profile` execs `startx`, and `~/.xinitrc` runs `/etc/bridge/launch.sh`,
which sets the custom 1120x832 X mode, starts
`/usr/local/bin/nextstep-kiosk-frame.sh` and execs `previous`.

**Ready** means the grey NeXTSTEP Workspace fully painted: the Workspace menu at
the top left, the File Viewer window with the home directory, and the Dock down
the right-hand edge with the recycler at the bottom. Canvas is the QEMU kiosk's
scanout — **1120x832, not 1024x768**: the X root is made exactly the size of the
NeXT MegaPixel display so the picture is pixel-exact, and the declared canvas has
to match or the clip will be letterboxed differently from the live tile. NeXT
sound flows via ALSA/AC97 to AAC, though the fixture itself is silent.

The Tier-3 hold is long on purpose. A cold boot is two machines in series: the
Debian kiosk (~30 s) and then the NeXTcube's own ROM POST, Mach kernel load and
Workspace login, which took **about four minutes** wall-clock in every observed
run on this host. `BR_MAX_MS` is set well above that.

**Two things must not be "simplified" when adapting this arm.**

1. The frame watcher is not optional decoration. With no window manager, nobody
   calls `XSetInputFocus` and no `EnterNotify` is generated for a pointer that
   was already inside the window when it was mapped, so SDL3 gives Previous
   neither keyboard nor mouse focus and the exhibit silently ignores all input.
   The same script also re-anchors the window at +0+0, because SDL3 centres it
   at +16+12 on a same-sized root and clips the Dock.
2. `SDL_FRAMEBUFFER_ACCELERATION=0` in `/etc/bridge/launch.sh` is what keeps the
   present path on `XPutImage` instead of llvmpipe. Without it the recording
   host pays 135% extra CPU and the emulator falls behind real time, which shows
   up in a clip as a boot that takes minutes longer than the live tile's.

A published clip's last frame must equal the golden's first live frame: the
Workspace with the File Viewer open and the pointer where the golden left it.
(The golden is baked after the tablet install, whose automation pixel-diffs the
desktop back onto the untouched Workspace, so the two frames still match.)
Follow `scripts/coldboot/README.md`; run `record-boot.sh nextstep --dry-run`
and read the rewritten clone launcher before any real capture.

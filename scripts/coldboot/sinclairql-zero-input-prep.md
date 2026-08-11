# sinclairql boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip has been recorded and `spa.bootVideo` is
not set in `registry/stations/sinclairql.json`; this file and the `sinclairql)` arm
in `bootrec-tiles.conf` exist so the cold-boot path is audited and ready, which
is what the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays read-only)
and rewrites SSH 5836→6836. Before recording it stops `getty@tty1` and `mame`
over clone SSH; after capture it starts the kiosk again. Bridge kind
intentionally skips `savevm`: every recording cold-boots the emulator.

**ZERO INPUT IS NOT GENUINE HERE, AND THAT IS THE POINT OF THIS FILE.** Every
other bridge tile's emulator reaches its fixture untouched. This one does not,
twice over:

1. MAME puts up its imperfect-dump warning — the QL's `hal16l8.ic38` PLD has
   never been dumped anywhere, so the warning is permanent and `-skip_gameinfo`
   does not suppress it. It waits on "press any key", and **`ret`, `spc` and
   `esc` do not satisfy it** (measured 2026-08-09); a plain letter does.
2. The QL itself then asks `F1...monitor / F2...TV` and draws nothing else until
   one of them is pressed. This is the machine's own behaviour, not the rig's.

A recording driver for this tile must therefore send `x`, wait for the chooser,
send `f1`, and wait for monitor mode — the same three framebuffer-asserted steps
`scripts/build-guests/tiles/sinclairql.sh` runs (`reach_monitor_mode`), including its
retry loop: a lone injected key is occasionally never sampled on this contended
box. **Do not blind-send on a timer.** Until such a driver exists, this arm
records the honest thing — a clip that ends at the chooser — or nothing at all.
The live tile never shows either screen: it enters through `-loadvm golden`.

Ready, for a clip that goes the whole way, means the 80-column monitor screen:
white window #2 left, red window #1 right, empty black command window along the
bottom, no green text anywhere in it. Canvas is the QEMU kiosk's scanout at
30 fps; the X root is 1024×768 and the QL's 512×256 fills it at an exact 2×3
scale, so nothing is letterboxed. QL beeper audio flows via ALSA/AC97 to AAC.

**Do not drop `-autoframeskip` or `SDL_VIDEODRIVER=x11` when adapting this arm.**
Without the first, MAME runs at ~42% of realtime on this host and the injected
keys are sampled away; without the second, SDL intermittently opens no X window
at all and the capture is pure black with the emulator alive. Both are measured
in `docs/guests/sinclairql.md`.

Reject any capture that shows the Linux console, a black emulator window, or a
command window with characters already typed into it.

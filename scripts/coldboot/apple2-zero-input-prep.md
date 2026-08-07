# apple2 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. The live shot showed Apple GEOS with the BIGWON disk
window on the 1024×768 kiosk scanout.

The arm copies the bridge overlay and rewrites SSH 5817→6817. Before recording it
stops the pointer watchdog, `getty@tty1`, and LinApple; after capture starts it restarts
the kiosk and watchdog. The patched LinApple config cold-boots Apple //e GEOS without
the former interrupt/mouse-card dialogs or human input. A 60 s hold covers the
documented 30–45 s boot.

Ready means the monochrome GEOS deskTop, disk window, menu bar, and pointer are fully
painted. Canvas is the QEMU kiosk's 1024×768 at 30 fps. Apple speaker audio flows via
ALSA/AC97 to AAC. Bridge kind skips savevm; reject any dialog, black emulator window,
or ProDOS-only screen.

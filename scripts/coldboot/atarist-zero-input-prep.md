# atarist boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. The live shot showed the 1024×768 kiosk with Hatari's
monochrome GEM desktop.

The bridge arm copies `overlay.qcow2`, loads the kiosk golden, and rewrites SSH
5816→6816. Before capture it stops `getty@tty1`/Hatari; after capture starts it starts
the kiosk. Hatari then cold-boots EmuTOS without guest input. The 50 s fixed hold
covers the documented 30–40 s boot. Ready means GEM menu bar, DISK A/B, trash, and
printer are completely painted inside the black kiosk canvas.

Canvas is the actual QEMU scanout, 1024×768/30 fps—not the inner 640×400 ST mode.
YM2149→ALSA→AC97 is recorded to AAC. Bridge kind skips savevm because the emulator
cold-boots per visit. Reject a black emulator window or boot logo before publishing.

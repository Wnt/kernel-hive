# macos753 boot capture — zero-input prep

Status: **AUDITED, NOT YET RECORDED**, 2026-08-16. The cold-boot behaviour below
was observed repeatedly on the build clone at
`/data/vms/soltest/macos753-build/`; no clip has been captured and the live
station was only read (`labctl shot macos753`).

The station is a 1152×870×8 Quadra 800 under **TCG with no acceleration path**,
so a cold boot is slow by the standards of every other arm in this file: the
Happy Mac appears within a few seconds, but the SCSI probe, the extension load
and the Finder taking the desktop run to roughly **60–80 s** before the machine
is still. `BR_MAX_MS=240000` is deliberately generous for that reason, not
because anything is expected to hang.

**Ready** means the quiet Finder desktop: menu bar, `Macintosh HD` at top right,
Trash at bottom right, no window open and nothing selected. That is a
dead-still grey field, which is why this arm can use the tier-1 change-fraction
detector where several other graphical arms cannot — there is no caret, no
clock second-hand and no animation anywhere in the fixture. The menu-bar clock
shows minutes only, so it changes at most once during the settle window.

## Two things that will ruin a capture if they are not respected

1. **Clone BOTH disks.** `BR_DISKS` names `macos753-golden.qcow2` *and*
   `pram-golden.qcow2`, because QEMU writes the vmstate into the **first
   snapshot-capable drive** and on this machine that is the 256-byte PRAM, not
   the hard disk. A clone of the hard disk alone carries a `golden` tag with no
   machine state behind it. The PRAM is also where the boot device and the
   mouse-tracking calibration live.
2. **The cold boot must follow a CLEAN shutdown.** If the guest was stopped
   uncleanly, Mac OS opens with *"This computer may not have been shut down
   properly"* and waits for a keypress — a zero-input capture then records a
   modal dialog and stops there. The station's normal lifecycle never cold-boots
   (it restores the checkpoint), so this only bites a recording run. Bring the
   clone down with `Special → Shut Down`, or via
   `scripts/install-vision/adb_pointer.py --qmp <clone>/qmp.sock menu 231 10 260 140`.

## Handoff

A published clip's last frame must match the checkpoint's first live frame. Both are
the same quiet desktop, so the handoff should be seamless — but the menu-bar
**clock** is part of that frame and reads the emulated RTC, so expect the two
frames to differ by the clock glyphs alone. Compare with the clock region
excluded before concluding a seam is real.

No driver script is needed: the machine reaches its fixture with no input at all.

Run `record-boot.sh macos753 --dry-run` first and inspect the rewritten clone
launcher — it must never attach the live writable disks.

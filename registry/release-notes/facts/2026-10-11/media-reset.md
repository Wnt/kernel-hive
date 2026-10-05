# media-reset — facts for release notes

**What changed for visitors:** Restore now really means a clean machine on
eight stations that have disks: the Apple //e, the Apple IIGS, the ARM
Evaluation System, the Atari 800XL, the Kaypro II (CP/M 2.2), the Macintosh
128K (System 1.0), the Philips MSX2 and the SAM Coupé. Until now a file a
visitor saved, or a disk they renamed, could survive Restore and greet the next
person. On the Apple //e one had: a Dazzle Draw picture saved during a test on
8 September sat in the `/DAZZLE` folder for four weeks.

**Under the hood:** MAME opens its disk images read-write. A hard disk takes
every write at once, and a floppy is written back whenever its motor stops.
Each station now boots from a fresh copy of a read-only master image every time
it starts. Restore on the stations with a savestate is still the 0.4-second
in-place state load. Before that load, a small Lua hook inside MAME swaps a
fresh copy of every disk in while the machine is paused. A state load alone
cannot do this: MAME's savestates carry the drive mechanics but not a floppy's
contents. On the Kaypro, a file saved to the boot floppy lived only in MAME's
memory, and after a plain state load it reappeared at the next warm boot. The
Apple //e master image was rebuilt by undoing exactly two guest writes. The
result matched the image its golden was captured against, byte for byte.

**What a visitor will notice:** nothing, until they save something. Restore
answers in well under a second on six of the eight (the MSX2 and the ARM
machine restart and boot as before). Saving inside a session works as it did:
the SAM Coupé, Apple and MSX programs saved in a visit are still there until
Restore.

Links: https://kernelhive.madekivi.fi/os/apple2e,
https://kernelhive.madekivi.fi/os/samcoupe,
https://kernelhive.madekivi.fi/os/cpm22,
https://kernelhive.madekivi.fi/os/macsys1

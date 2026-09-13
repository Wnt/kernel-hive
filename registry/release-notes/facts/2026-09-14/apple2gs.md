# apple2gs — facts from week ending 2026-09-14

Extracted for the Sunday authoring pass; raw material, not publishable prose
on its own.

## From the summary prose

- (New stations) <u>[Apple IIGS](station:apple2gs) joins as a third Apple II
  family station, running the 16-bit machine's own GUI: **GS/OS System
  6.0.1** (1992) booting into the Finder, next to `apple2` (GEOS) and
  `apple2e` (ProDOS text menu).</u> The GS's ADB keyboard and mouse are
  handled by a motherboard controller, not add-in cards, so this station
  needed none of the //e's Mouse Card or Disk II controller.

## Bullets

- [Apple IIGS](station:apple2gs) is host-native MAME 0.289 (`apple2gs`
  driver), booting GS/OS 6.0.1's Finder from a 32 MB CFFA 2.0 ProDOS volume in
  slot 7 — the same CFFA-in-7 trick as [Apple //e](station:apple2e), but the
  GS needs no mouse card or Disk II controller because both are handled by
  its own ADB controller and built-in IWM.
- [Apple IIGS](station:apple2gs)'s golden checkpoint is a 474,700-byte MAME
  save state written in 152 ms; restoring it produces a framebuffer
  byte-identical to the 33.8-second cold-boot Finder desktop.
- [Apple IIGS](station:apple2gs)'s 96-key ADB keymap was dumped straight off
  the running machine's own `KEYDUMP` diagnostic rather than reused from a
  sibling station — the GS's ADB keyboard is a different device from the
  //e's hardware encoder.
- [Apple IIGS](station:apple2gs) ships keyboard-only for now: its ADB mouse
  reports on 8-bit axes like the //e's mouse card, but the pointer gain is not
  yet measured, so `stream.pointer.transport` stays `"none"`.

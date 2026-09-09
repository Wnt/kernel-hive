# lisa — facts from week ending 2026-09-13

Raw material for the Sunday authoring pass, not publishable prose on its own.

## New station

- [Apple Lisa](station:lisa) joins: **Lisa Office System 3.1** (1984) on an
  emulated Lisa 2 (Motorola 68000 at 5 MHz, 1 MB, boot ROM rev H, 5 MB
  ProFile) with all seven Lisa tools — LisaWrite, LisaDraw, LisaCalc,
  LisaGraph, LisaList, LisaProject, LisaTerminal — plus the Clock and
  Calculator on the disk.
- The document-centric desktop that preceded the Macintosh: stationery pads,
  tear-off documents, a desktop saved across power cycles; lineup position
  between the Xerox stations and the Macintosh.
- Host-native from day one: LisaEm 2.0.0 (Ray Arachelian, GPL-2.0) as a plain
  X application under a pinned 720x498 Xvfb, the daemon capturing the X root
  and driving XTEST; the Lisa's own arrow follows the visitor's pointer
  exactly (absolute XTEST motion in root coordinates).
- Sandboxed under the week's new host-application rule: LisaEm runs inside a
  systemd-nspawn container with private PID/mount/network/user namespaces
  (unprivileged host uid range, read-only root, only the station's work and
  X-socket directories writable) — the same shape `medley` was moved into.
- The screen is the Lisa's own 720x364 with its 1.5:1 pixels drawn at the
  right proportion; the GTK menubar is collapsed and the window offset so
  nothing but the Lisa is captured.
- Boot ROM assembled from the MAME `lisa2` romset halves (an archive.org "Lisa
  ROMs" item turned out to be a bad dump); the system disk is a pre-installed
  LOS 3.1 ProFile image, shipped unmodified, so a reset is a true cold boot
  back to the shipped desktop (~2-2.5 min at 5 MHz).
- No network: a 1984 Lisa has no TCP/IP; no retronet, no IM, no audio.
- MAME's own Lisa driver (present in the lab's 0.276) could not be used: it has
  floppy drives but no ProFile, and the Office System boots only from a
  ProFile.

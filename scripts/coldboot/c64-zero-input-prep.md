# c64 boot capture — bridge prep

Status: **PROVEN-NEW** end to end on an isolated clone, 2026-07-14. The live C64
tile was only read with `labctl shot`.

The clone resumes the copied Debian kiosk golden, but the boot video must show VICE
and the C64 rather than the already-running desktop. Before capture the arm stops
`getty@tty1` and x64sc over clone SSH; after capture starts it starts the kiosk again.
VICE true-drive autostarts GEOS 2.0. No visitor input is sent. The 100 s hold covers
the documented 60–90 s load. Ready means the GEOS deskTop System window, icons, and
pointer are fully painted.

Proof: record 100.560 s → postprocess → trim 78.587 s. The visually inspected poster
showed the GEOS System window. Trim preserved final-frame MD5
`a90a4d1b6ab9b4b6d52ad0ac47343ab3`. Final MP4 is 1024×768, H.264 High,
yuv420p, 30/1, 0.5 s keyframes, AAC-LC; sprite/VTT/`durationMs` regenerated.
Bridge kind intentionally skips savevm: every visit cold-boots the emulator.

The arm copies only `overlay.qcow2`, keeps its shared backing read-only, rewrites
hostfwd 5814→6814, and uses the bridge key path without exposing its contents.

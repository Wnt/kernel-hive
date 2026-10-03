# Spectravideo and MSX station wave — 2026-10-03

Six offline exhibits follow a visitor's memories of Spectravideo BASIC and
CP/M. The user authorized concurrent implementation, builds and CI, and asked
for compiler caching and browser-tested type-in programs on the four command
line exhibits. No retronet onboarding belongs to this wave.

## Reserved stacks

Each station has its own branch and `/data/vms/sandbox/<session>/repo` worktree.
Allocation was completed with `wave.sh alloc` before implementation started.
The private `.wave.env` files retain the complete allocation; no network
addresses or MACs belong in this ledger.

| Station | Session | Slot / UDP / VMID | Exhibit |
|---|---|---|---|
| msxturbor | msxturbor | 220 / 54220 / 220 | Panasonic FS-A1GT, MSX View |
| svi328 | svi328 | 221 / 54221 / 221 | Spectravideo SV-328, Extended BASIC |
| svi328cpm | svi328cpm | 222 / 54222 / 222 | Expanded SV-328, CP/M and 80-column display |
| svi728 | svi728 | 223 / 54223 / 223 | Spectravideo SVI-728, MSX-BASIC |
| svi738 | svi738 | 224 / 54224 / 224 | Spectravideo SVI-738 X'Press, CP/M |
| symbos | symbos | 225 / 54225 / 225 | Expanded Philips MSX2, SymbOS 4.0 |

The integration branch/session is `spectra-wave`. Workers own station sources
and unique build/output directories. Shared generated registries are regenerated
after integration. Builds and checks may run together; only the repository's
existing landing lock serializes publication.

## Acceptance

Boot images alone do not establish a finished station. Each exhibit needs its
own verified media, native framebuffer and input path, accurate visitor text,
scene row, reset behavior, poster, and working stream across reconnections.
The four BASIC/CP/M stations must enter and execute their demo through the
actual web button. CP/M demos must run a program, rather than merely list files.
Both desktop stations need keyboard, pointer, applications and writable-file
tests. Reset must discard visitor changes to writable media.

Final acceptance uses VNC Chrome and a dedicated expiring viewer invite. Keep
the invite and browser session state outside git. Record observed results in
the station documents; do not copy a sibling's proof claims.

## Build policy

MAME uses the fleet pin and the shared `mame-ccache.sh` configuration, with
explicit `ccache gcc` / `ccache g++` in generated makefiles. Isolated copies of
compatible existing build trees may retain compiled objects. openMSX also uses
ccache. Cache statistics and successful framebuffer checks belong in the build
evidence; enabling an environment flag alone is insufficient.

## Status

SVI-728 and SVI-738 are published at main commit 01c1e1cf with native
services, exhibition notes, framebuffer images and Type demo actions. Their
web demos passed in staging; production boot/reset screens were inspected.
The other four stations remain in implementation or browser acceptance.
Licensed hardware galleries have been acquired for all six and await the
next publication. Each guest document records its own evidence.

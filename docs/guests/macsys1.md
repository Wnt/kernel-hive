# macsys1 guest

Status: **scaffold only** (Tier 1, disabled candidate; not in the lineup).

## Identity and source

- Public ID / tile directory: `macsys1`
- Reserved slot / UDP port: `199` / `54199`
- Archetype: `beige-tower-crt`
- Stable release, architecture, source/license class, URL, size, and SHA-256: TODO

## Build and device set

- Builder: `scripts/build-guests/tiles/macsys1.sh`
- Canonical output: TODO
- QEMU binary, machine, accelerator, CPU, RAM, display, storage, NIC, audio, and input: TODO
- Ready framebuffer and bounded automation path: TODO

## Golden, input, and rollback

- Reset mode and fixture: TODO
- Run `scripts/lib/golden-verify.sh macsys1 --bake` on a namespaced clone, then
  rerun without `--bake` before promotion.
- Pointer/click/drag/wheel proof: TODO. Keyboard: see "Keyboard" below.
- Cold-boot zero-input state and optional clip: TODO
- Credentials reference only (never values): `guest/macsys1`
- Rollback plan: TODO

## Keyboard (2026-10-04)

The M0110 keyboard is its own emulated device: an i8021 MCU scans its matrix
and clocks keycodes to the Mac. Measured on a rig of this station's binary
and golden, through a sandbox daemon, typing a new name for the selected
Write/Paint disk (`A+B*C(D)E$!"1+2*3`; a Mac name cannot hold `:`) at 150 ms
a character with Shift and its key back to back, which is how `typeText()`
types: labctl, the on-screen keyboard's character keys, and any capital a
visitor types without holding Shift.

**Shift was lost on every shifted character.** The live binary typed
`a=b8c9d0e41'1=28`. The `ctlsock` module put Shift and the key into the
matrix in one drain pass, and the i8021 scanned the key first. The modifier
lead (`SH_KEY_MOD_LEAD_MS`) holds the key press until Shift has been in the
matrix that long, in emulated time:

| Lead | Shifted characters |
|---|---|
| 0, 1, 2, 5 ms | lost (2 runs each) |
| 10, 20, 50 ms | exact (2 runs each) |
| 20 ms with `MAME_CTL_KEY_EXCL=:ROW` | exact |

The threshold is between 5 and 10 ms, about one i8021 scan period, against 1
to 2 ms on the QL and the Oric. The station ships **20 ms**. The golden is
pixel-identical under the new binary, and the savestate signature is
unchanged (`87d97500`, 2883 entries). Exclusive scan is not set: it did not
change the fault below.

**OPEN: a phantom `]`.** In about one run in three, at every lead, with and
without exclusive scan and even with every edge 300 ms apart, one key the
daemon never sent arrives: `]` or `}`, once `8`. Sometimes it never
releases, autorepeats, and the Finder answers *That name is too long*.
The daemon's records show only the keys sent. A likely place is the M0110
emulation or its serial clock: the Mac's poll reply for "no key" is `0x7B`,
which decoded as a key transition is a press of keycode `0x3D`, the `]` key.
Not verified.

**Fresh media per start (2026-10-05).** The station mounts per-start COPIES of
immutable templates (`MAME_NATIVE_DISK_TEMPLATE`, mode 444, never handed to
MAME): MAME opens its media read-write, and before this a visitor's saved file
landed in the shared asset and outlived Restore. A start copies both `.dc42`
floppies to `stations/macsys1/media/`. Restore stays the in-process `LOADST
golden`, but LOADST restores CPU, RAM and device registers, not media (a
floppy's track data lives in the drive's memory, a hard disk is the file), so
the Restore path pauses MAME, has the launcher's companion `media-hook.sh`
(emitted as an aux file, a Lua hook entering through `-pluginspath`) unload,
re-copy and reload every image, then LOADSTs and resumes. Without the armed
hook a Restore takes the service restart, which copies fresh media at its
start: never a plain LOADST. Mechanism:
`streamhost/stations/mame-native/x11-runtime.sh` and `media-hook.sh`.

**Proof.** Rig: renaming the selected disk to `KHPROOF` and clicking the
desktop committed it to the image (hash changed); Restore 396 ms brought back
Write/Paint, the golden frame pixel-identical, image hashes pristine, and the
disk opened normally afterwards (6 items). Live: the gallery Restore answered
in 601 ms, in-process.

Evidence:
`/data/vms/streamhost/stations/macsys1/evidence/media-reset-2026-10-05/` (rig
frames and live frames). Rollback: `station.env.pre-mediareset-20261005` and
`x11-runtime.sh.pre-mediareset-20261005` in the station dir.

**Live since 2026-10-04.** Through the real SPA keyboard, bare characters (so
the SPA adds a synthetic Shift, the shape that failed): the selected disk's name
became `A+B(D)E$!"1+2=3` exactly, uncommitted, and Restore to golden brought
back Write/Paint. Both floppy images hashed identical before and after
(`evidence/.../floppy-guard/`).

Evidence: `/data/vms/streamhost/stations/macsys1/evidence/shift-lead-2026-10-04/`.
Rollback: `assets/macsys1/mame-native/mac128.pre-shiftlead-20261004` and
`station.env.pre-shiftlead-20261004`.


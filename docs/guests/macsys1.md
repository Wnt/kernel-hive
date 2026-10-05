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

**OPEN: the floppies are writable.** MAME runs as root and holds both
`.dc42` images open read-write despite their 0444 mode, so a rename a
visitor commits (Return, or a click elsewhere) could reach the asset media
and outlive Restore. Their mtimes (2026-09-13) show nothing has been written
so far. Opening them read-only (or from a copy per launch) would close it.

**Live since 2026-10-04.** Through the real SPA keyboard, bare characters (so
the SPA adds a synthetic Shift, the shape that failed): the selected disk's name
became `A+B(D)E$!"1+2=3` exactly, uncommitted, and Restore to golden brought
back Write/Paint. Both floppy images hashed identical before and after
(`evidence/.../floppy-guard/`).

Evidence: `/data/vms/streamhost/stations/macsys1/evidence/shift-lead-2026-10-04/`.
Rollback: `assets/macsys1/mame-native/mac128.pre-shiftlead-20261004` and
`station.env.pre-shiftlead-20261004`.


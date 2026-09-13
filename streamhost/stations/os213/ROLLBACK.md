# os213 rollback — absolute pointer cutover (2026-09-13)

Binary + golden + launcher move together. `-device kh-ramabs` registers no
`VMStateDescription`, so the *device set* is unchanged by the cutover — but
the golden was still re-baked (cold) under the new binary, and its snapshot
now belongs to that binary. Restoring the pre-cutover fixture under the old
`qemu-system-i386` binary is untested; treat the pair as one unit.

## What changed

| | before | after |
|---|---|---|
| binary | fleet `qemu-system-i386` (symlink to the host `qemu-system-x86_64`) | `/opt/qemu-os213/bin/qemu-system-x86_64` (own build, `0007` + the `point16le_yx` row) |
| golden | `disk.qcow2` snapshot `golden`, baked under the fleet binary | re-baked cold under `/opt/qemu-os213`, same fixture scene |
| launcher | plain PS/2 relative, no ptr device | `${OS213_QEMU:-/opt/qemu-os213/...}` + conditional `-device kh-ramabs` when `KH_RAMABS_ADDR` is set |
| fixture | `SH_CURSOR_SCALE=1.0`, no `SH_INPUT_BACKEND` | `SH_INPUT_BACKEND=ramabs`, `KH_RAMABS_ADDR=0x253ca`, `SH_CURSOR_SCALE=1.0` (inert under ramabs, kept for rollback) |
| registry | `stream.pointer` rel / `qemu-ps2-relative` | `stream.pointer` abs / `qemu-guestram-abswrite` / backend `ramabs` |

## To roll back

1. Stop the station: `ssh lab 'systemctl stop streamhost@os213'`.
2. Restore the pre-cutover disk: `station-land.sh` parks the previous golden
   as `disk.qcow2.pre-<timestamp>` next to the live one — copy that back over
   `disk.qcow2` (do **not** trust the new golden's snapshot to be readable
   under the old binary; it was baked under `/opt/qemu-os213`).
3. Drop the pointer lines from `streamhost/stations/os213/station.env.fixture`
   (`SH_INPUT_BACKEND`, `KH_RAMABS_ADDR`, `SH_RAMABS_SOCK`, `SH_RAMABS_TRACE`,
   `PTR_TRACE`) — or simply unset `KH_RAMABS_ADDR` at runtime, which is
   FAIL-CLOSED: the launcher's `PTR_ARGS` array stays empty and no
   `kh-ramabs` device is added, and the daemon falls back to
   `SH_INPUT_BACKEND=dbus-rel` (or its absence) automatically.
4. The launcher's `OS213_QEMU` variable can point back at plain
   `qemu-system-i386` — the base device set (isapc/486/16 MB/isa-vga/KVM) is
   identical on both binaries, so a relative-only launch works on either.
5. Revert `registry/stations/os213.json`'s `stream.pointer`, `spa.pointerRel`,
   `operator.labctl.pointer_mode` and `reset.mouse`/`reset.pointer` to the
   pre-cutover values (see the commit this file shipped with), and re-run
   `python3 scripts/stations-registry.py generate` + `station-land.sh`.

## Not exercised

Unlike `beos` (docs/lab/BEOS-ABSOLUTE-POINTER.md §6), this rollback has **not**
been drilled end-to-end on the live station — only reasoned from the device
set being unchanged and the fixture keys being additive. If rolling back for
real, prove step 2 (old golden restores under the old binary) on a clone
before touching the live station.

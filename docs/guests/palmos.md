# palmos guest

Status: **production, dark-launched** (`listing.state: hidden`). Host-native
MAME, no QEMU, no guest OS filesystem. See `docs/lab/PALMOS-WAVE.md` for the
full wave brief, the pointer-route design, and the OPEN items blocking
promotion.

## Identity and source

- Public ID / tile directory: `palmos`
- Reserved slot / UDP port: `207` / `54207`
- Archetype: `touch-phone` (temporary — no PDA-shaped 3D body model exists
  yet; scene tuple `pizzaBoxB,none,none,none`)
- Machine: Palm III (Motorola MC68328 "DragonBall", 16.58 MHz)
- OS: Palm OS 3.3, **French** release (no byte-exact English 3.x dump found
  for this driver inside the wave's budget — see the wave doc)
- ROM: `palmos33-fr-iii.rom`, 2 097 152 B, SHA-1
  `c7c90df814d4f97958194e0bc28c595e967a4529`, sourced as
  `Palm-III-3.3-fr.rom` from https://palmdb.net/app/palm-roms-complete
  (staged at `/data/assets-staging/palmos/roms/` on labhost)
- License/source class: preservation-archive (abandonware); ROM is a private
  exhibit asset, never committed to git

## Build and device set

- Builder: `scripts/build-guests/emulators/native.d/palmos.sh` +
  `scripts/build-guests/emulators/build-mame-native.sh palmos`
- MAME driver: `palmiii` (`src/mame/palm/palm.cpp`), pin `mame0289`
- MAME_NATIVE_ARGS: `-bios 3.3f`
- Published surface: `160x220` (the driver's own visarea — no letterbox)
- Patches: `mame-ctlsock.patch mame-drawshm.patch mame-kiosk-no-ui.patch
  mame-ctlsock-ptr-tags.patch mame-ctlsock-abs-fields.patch`
- Capture: drawshm → shm; audio off for this release (seed's own call)

## Golden, input, and rollback

- Reset mode: `relaunch` (restores the golden MAME savestate; `palmiii`
  ships `MACHINE_SUPPORTS_SAVE`)
- Fixture: see `streamhost/stations/palmos/station.env.fixture`
- Pointer: **new route**, `mame-ctlsock-abs-fields.patch` +
  `MAME_CTL_ABS=1` — Palm's pen is a true absolute `IPT_LIGHTGUN_X/Y`
  ioport field (not a relative mouse), so `MOVEA` writes the field
  directly, scaled from the published surface into the field's own
  declared range. No accumulator, no cursor readback — see
  `docs/lab/PALMOS-WAVE.md` for why every other MAME pointer route in this
  fleet does not fit this machine.
- Hardware buttons: `palmiii`'s `PORTD` port carries seven real device
  buttons (Power, Up, Down, four app-launch buttons for Date Book/Address
  Book/To Do/Memo Pad), bound to plain PC keycodes (D/Y/H/F/G/J/K) so they
  are reachable from the on-screen keyboard, not a hidden host shortcut.
  `streamhost/stations/palmos/palmos.keymap` gives them labels — **PLACEHOLDER,
  pending a real `scripts/dev/mame-keymap.py` KEYDUMP run**.
- Golden scene: OPEN — the golden stream still needs to reach the
  Applications Launcher (a fresh `palmiii` boot most likely lands on Palm
  OS's own Welcome/digitizer-calibration flow first).
- Credentials reference only (never values): `guest/palmos` (none actually
  needed — no login)
- Rollback plan: this is a new station; rollback is deleting the registry
  entry and the staged binary/ROM, no prior version to revert to.

## OPEN

See `docs/lab/PALMOS-WAVE.md` §OPEN: golden scene, English ROM, real keymap,
PDA body model, promotion.

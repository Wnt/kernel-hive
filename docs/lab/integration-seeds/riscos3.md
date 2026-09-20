# Integration seed — RISC OS 3.11 on Acorn Archimedes

Tracking: #47  
Prep branch: `riscos3`  
Exhibition copy: `docs/lab/spa-drafts/riscos3.md`

## Proposed station shape

- **station id:** `riscos3`
- **runtime:** host-native MAME, shared-memory capture, MAME control-socket input
- **closest sibling:** `apple2gs` (current MAME 0.289 direct/shm path with absolute pointer)
- **scene archetype:** start from `beige-tower-crt`; replace with a more Acorn-specific assembly later if desired
- **audio:** off for the first wave
- **network:** none for the first wave; do not let networking block the desktop exhibit

## Start here

Create a worktree from this prep branch:

```bash
scripts/dev/wt.sh new riscos3-work --from origin/riscos3
cd ../riscos3-work
```

Allocate only the station resources needed for a host-native MAME guest:

```bash
scripts/dev/wave.sh alloc riscos3
python3 scripts/stations-registry.py new riscos3   --like apple2gs --production --slot auto
```

Immediately replace the copied Apple-specific museum/runtime fields; keep the shared `mame-native/x11-runtime.sh` shape.

## Media acquisition

The OS is ROM-resident. For the first proof use a RISC OS 3.11 A310 ROM set.

Useful known facts:

- MAME driver: `aa310`
- BIOS selector: `-bios 311`
- MAME expects the A310 machine ROM set and Archimedes keyboard ROM.
- A standalone RISC OS 3.11 ROM is commonly identified as `ROM311` with MD5 `b7e46ab8c832d720942fcd2c8a66c294`; MAME itself normally wants the split A310 ROM members.
- Use the exact member names/checksums from the fleet-pinned MAME, not an internet list:

```bash
/path/to/mame aa310 -listxml > /tmp/aa310.xml
/path/to/mame aa310 -listbios
```

Stage the resolved ROM set under the normal station asset directory and pin hashes in the builder.

Reference material:
- https://wiki.mamedev.org/index.php?title=Driver:RiscOS
- https://www.riscos.com/riscos/310/index.php

## First smoke command

Before streamhost integration, prove the machine with the ordinary MAME UI:

```bash
mame aa310 -bios 311 -skip_gameinfo
```

Expected result: RISC OS reaches the Desktop with no disk attached. If the machine instead lands at `*`, use the documented desktop command/startup sequence rather than adding a hard disk prematurely.

If `aa310` is too restrictive for the intended apps, the first fallback is:

```bash
mame aa5000 -bios 311
```

Use A5000 only if ARM3/HDD software actually requires it.

## Kernel Hive native path

Once the desktop is proven, add `scripts/build-guests/emulators/native.d/riscos3.sh` using the existing MAME-native stations as the template. The final launch should use the same patched MAME features as `apple2gs`:

- drawshm/shared framebuffer
- ctlsock keyboard/mouse
- station-local keymap
- no X window as the published surface

Do not copy Apple IIGS pointer assumptions. Measure which MAME input ports the Archimedes mouse exposes and wire only those.

## Intended golden scene

RISC OS Desktop at rest with:

- icon bar visible
- one Filer window open
- `!Draw` or `!Paint` one click away
- no emulator menus or warnings

Best demo: open a Filer window, launch `!Draw`, draw/drag one object, reset.

## Proof checklist

- [ ] `aa310 -bios 311` reaches Desktop
- [ ] framebuffer dimensions measured from the actual output
- [ ] three mouse buttons mapped and at least Select/Adjust proven
- [ ] keyboard input proven
- [ ] relaunch/reset returns to the same Desktop scene
- [ ] final ROM member list + hashes recorded
- [ ] poster draft promoted into `registry/posters/riscos3.md` after scaffold

## Stop conditions / likely wall

If MAME's Archimedes mouse cannot be made deterministic through the current control socket, stop there and race Arculator/CLK as a host-X11 fallback. Do not spend a long session patching MAME before one alternate emulator has been smoke-tested.

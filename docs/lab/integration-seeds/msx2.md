# Integration seed — MSX2 + MSX-DOS 2

Tracking: #60  
Prep branch: `msx2`  
Exhibition copy: `docs/lab/spa-drafts/msx2.md`

## Proposed station shape

- **station id:** `msx2`
- **runtime:** openMSX inside nspawn/Xvfb
- **closest sibling:** `medley`
- **scene archetype:** `beige-tower-crt` temporarily; a home-computer assembly can replace it later
- **target machine:** Philips NMS 8250 or another ordinary disk-equipped MSX2
- **published surface:** openMSX window cropped to the emulated display
- **input:** XTEST keyboard; pointer only if the chosen demo needs an MSX mouse

## Start here

```bash
scripts/dev/wt.sh new msx2-work --from origin/msx2
cd ../msx2-work
scripts/dev/wave.sh alloc msx2
python3 scripts/stations-registry.py new msx2   --like medley --production --slot auto
```

Replace Medley with openMSX, keeping the isolated host-app/Xvfb pattern.

## Emulator acquisition

Pin an openMSX release/source:
- https://openmsx.org/
- https://github.com/openMSX/openMSX

The station builder should stage:
- openMSX binary/runtime data
- one selected MSX2 machine definition + its ROMs
- MSX-DOS 2 ROM
- MSX-DOS 2 boot disk

## Machine choice

Start with:

```
Philips_NMS_8250
```

because it is a conventional MSX2 with floppy drives and makes the “multi-vendor standard” story clearer than a later turboR.

If that machine definition is not available in the staged openMSX system, list available MSX2 machines and choose another ordinary Sony/Panasonic/Philips model rather than changing the exhibit to turboR.

## First smoke command

Preferred:

```bash
openmsx   -machine Philips_NMS_8250   -ext msxdos2   -diska MSXDOS2.DSK
```

If the chosen machine lacks a suitable mapper/disk setup, use the known universal MSX2 extension shape:

```bash
openmsx   -machine <MSX2>   -exta slotexpander   -ext Panasonic_FS-FD1A   -ext ram512k   -ext msxdos2   -diska MSXDOS2.DSK
```

Do not use that universal hardware pile if the real chosen MSX2 already provides the devices.

## Media acquisition

MSX-DOS2 ROM/disk mirrors are widespread. Stage:
- DOS2 kernel/cartridge ROM
- English or Japanese DOS2 system disk

Useful reference:
- https://openmsx.org/manual/setup.html
- https://download.file-hunter.com/System%20Disks/Cartridges/ASCII/MSX-DOS2/

Ask openMSX to validate media/device presence during builder smoke rather than trusting filenames.

## Intended rest scene

Two-stage visitor story:

1. power-on MSX-BASIC screen
2. one labeled action boots/enters MSX-DOS 2

For the golden, choose whichever is more immediately useful:
- BASIC `Ok` prompt with DOS2 one command away, or
- MSX-DOS2 prompt with BASIC accessible via reset

A small productivity/drawing application is more valuable than another game-only demo.

## Input proof

- keyboard typing at BASIC
- disk access under DOS2
- arrow/function keys if file manager/app uses them
- optional mouse only if the curated app requires it

## Reset strategy

openMSX relaunch from immutable ROM/disk assets. Visitor-writable disks should be copied to a work file on each launch.

## Proof checklist

- [ ] selected real MSX2 profile boots
- [ ] DOS2 ROM recognized
- [ ] boot disk reaches DOS2 command prompt
- [ ] keyboard mapping proven
- [ ] relaunch restores pristine disk state
- [ ] openMSX chrome excluded from published surface

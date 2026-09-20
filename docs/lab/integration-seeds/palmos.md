# Integration seed — Palm OS 4.1 handheld

Tracking: #48  
Prep branch: `palmos`  
Exhibition copy: `docs/lab/spa-drafts/palmos.md`

## Proposed station shape

- **station id:** `palmos`
- **preferred runtime:** host-native MAME
- **preferred machine:** Palm III first; m505 second if color support is stable
- **closest sibling:** `fmtowns` for current MAME/shm/absolute-input mechanics
- **scene archetype:** `touch-phone` temporarily; a PDA-specific scene can replace it later
- **network/audio:** off for the first wave

The important part is stylus accuracy, not networking.

## Start here

```bash
scripts/dev/wt.sh new palmos-work --from origin/palmos
cd ../palmos-work
scripts/dev/wave.sh alloc palmos
python3 scripts/stations-registry.py new palmos   --like fmtowns --production --slot auto
```

After scaffolding, change `spa.archetypeId` to `touch-phone` and remove FM-Towns-specific audio/keymap fields.

## Media acquisition

PalmDB currently has complete device ROM collections and Palm OS 4.1 images.

Recommended first target:

- machine: `palmiii`
- ROM: Palm III / IIIx 4.1 English if accepted by the driver
- fallback: `palmm505` with `Palm-m505-4.1-en.rom`

Source:
- https://palmdb.net/app/palm-roms-complete
- https://palmdb.net/app/upgrade-os4

Before staging anything, ask the pinned MAME what the chosen driver expects:

```bash
mame palmiii -listxml > /tmp/palmiii.xml
mame palmm505 -listxml > /tmp/palmm505.xml
```

Create the ROM zip/member names to match **that** output exactly.

## First smoke commands

Try grayscale first:

```bash
mame palmiii -skip_gameinfo
```

Then color:

```bash
mame palmm505 -skip_gameinfo
```

Whichever reaches a stable launcher with pen input first wins the first station. Do not spend the first pass chasing every Palm model.

## Input strategy

Treat the browser pointer as the stylus:

- absolute coordinates only
- button-down = pen-down
- drag = pen stroke
- no pointer-lock/relative path

The first acceptance test is:
1. tap Applications,
2. open Memo Pad,
3. draw/write in the Graffiti area or select UI controls,
4. reset.

If MAME's pen device is not exposed cleanly through the existing MAME control path, pivot quickly to CloudpilotEmu rather than adding a Palm-specific input subsystem to MAME.

Cloudpilot fallback:
- https://github.com/cloudpilot-emu/cloudpilot-emu

## Intended golden scene

Application launcher with recognizable built-ins visible. Keep a Memo/Date Book target one tap away. Avoid leaving setup/calibration dialogs as the exhibit scene.

## Builder handoff

The builder should:
- fetch/stage exactly one chosen ROM
- verify its checksum
- build/pin the station MAME binary if the fleet pin is insufficient
- emit no mutable Palm user-data image into Git; runtime state belongs in the station assets/golden

## Proof checklist

- [ ] one Palm driver reaches launcher
- [ ] stylus lands within a few pixels across at least five targets
- [ ] drag works
- [ ] one built-in app opens and accepts input
- [ ] reset returns to launcher
- [ ] poster draft promoted after scaffold

# Integration seed — Psion Series 5 / EPOC32

Tracking: #52  
Prep branch: `psion5`  
Exhibition copy: `docs/lab/spa-drafts/psion5.md`

## Proposed station shape

This candidate needs a **very short emulator race before scaffolding**, because current MAME marks `psion5mx` preliminary and older reports show blank-screen/unmapped-memory failures.

Race only these two paths:

1. **MAME `psion5mx`** — preferred if it reaches the EPOC desktop on the fleet pin.
2. **WindEmu** — fallback if MAME still fails; host-X11 capture through the same pattern as `medley`.

If MAME wins:
- sibling: `fmtowns`
- runtime: MAME direct/shm + control socket
- temporary scene archetype: `touch-phone`

If WindEmu wins:
- sibling: `medley`
- runtime: Xvfb/X11 capture + XTEST
- temporary scene archetype: `touch-phone`

A bespoke clamshell/handheld scene can replace `touch-phone` later.

## Start here

```bash
scripts/dev/wt.sh new psion5-work --from origin/psion5
cd ../psion5-work
scripts/dev/wave.sh alloc psion5
```

Do the smoke race **before** choosing `--like`.

### MAME candidate

Use the Series 5mx English ROM:

- `5mx_v1.05(250)_eng.bin`
- MD5 `672afdf329d46876d4a0b39f348b2c52`

Source:
- https://github.com/explit28/Psion-ROM

Ask the fleet MAME for its exact ROM member naming:

```bash
mame psion5mx -listxml > /tmp/psion5mx.xml
```

Build the expected zip/member layout, then:

```bash
mame psion5mx -skip_gameinfo
```

If the EPOC desktop appears and accepts touch/keyboard input, scaffold:

```bash
python3 scripts/stations-registry.py new psion5   --like fmtowns --production --slot auto
```

### WindEmu fallback

If MAME still produces only a blank LCD/unmapped-memory loop, stop immediately and smoke WindEmu instead:

```bash
git clone https://github.com/Treeki/WindEmu.git
# build per project README
DISPLAY=:<display> ./windemu <rom/config arguments>
```

If WindEmu wins:

```bash
python3 scripts/stations-registry.py new psion5   --like medley --production --slot auto
```

Then replace the Medley inner app with WindEmu and set `spa.archetypeId=touch-phone`.

## Input strategy

The exhibit needs **both**:
- absolute pen/touch coordinates
- physical keyboard input

Acceptance targets:
- tap an icon/menu
- drag/scroll
- type text in Word/Agenda
- verify dedicated Psion key(s) if useful

Do not add custom browser input until the winning emulator's native input surfaces have been enumerated.

## Intended golden scene

Prefer:
- EPOC system screen / Extras bar
- Agenda, Word or Contacts visible one action away
- no ROM boot diagnostics

Best guided demo: open Word, type one short sentence, return to system screen, reset.

## Proof checklist

- [ ] one emulator path reaches EPOC32
- [ ] exact Series 5/5mx ROM file pinned
- [ ] touch coordinates measured across five targets
- [ ] keyboard typing proven
- [ ] relaunch/reset returns to a clean system scene
- [ ] poster draft promoted after scaffold

## Stop condition

Do not patch the MAME Series 5mx CPU/memory model in the first integration pass. If current MAME fails the basic smoke test, WindEmu gets the next attempt immediately.

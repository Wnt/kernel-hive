# Integration seed — CP/M 2.2 on Kaypro II

Tracking: #55  
Prep branch: `cpm22`  
Exhibition copy: `docs/lab/spa-drafts/cpm22.md`

## Proposed station shape

- **station id:** `cpm22`
- **runtime:** host-native MAME `kaypro2`
- **closest sibling:** `apple2gs` for the current MAME 0.289 direct/shm infrastructure
- **scene archetype:** change to `mono-terminal`
- **pointer:** none
- **audio/network:** none
- **reset:** MAME relaunch from immutable floppy images

## Start here

```bash
scripts/dev/wt.sh new cpm22-work --from origin/cpm22
cd ../cpm22-work
scripts/dev/wave.sh alloc cpm22
python3 scripts/stations-registry.py new cpm22   --like apple2gs --production --slot auto
```

After scaffold:
- set `spa.archetypeId=mono-terminal`
- remove Apple pointer/audio assumptions
- keep MAME shared-memory capture + control-socket keyboard

## Media acquisition

Need two things:

1. Kaypro II ROM set expected by the fleet MAME
2. bootable CP/M 2.2 disk, plus optionally a WordStar disk

Ask MAME first:

```bash
mame kaypro2 -listxml > /tmp/kaypro2.xml
mame kaypro2 -listmedia
```

Useful disk sources:
- Maslin Kaypro archive: https://oldcomputers.dyndns.org/public/pub/archiv/maslin/masl-dsk/images-97/kpro/index.html
- preservation copy labelled “KAYPRO II 64k CP/M 2.2” is also widely mirrored

Prefer a raw/IMD image already accepted by MAME. If the source is TD0/Teledisk, convert during the builder into the exact floppy format MAME consumes.

## First smoke command

The expected shape is:

```bash
mame kaypro2 -flop1 <cpm22-image> -skip_gameinfo
```

If MAME reports a different slot name, use `-listmedia` output instead of guessing.

Expected result:
- Kaypro boot banner
- CP/M prompt `A>`

Then attach WordStar media on the second drive if supported:

```bash
mame kaypro2 -flop1 <system> -flop2 <wordstar>
```

## Intended rest scene

`A>` prompt with a short `DIR` listing visible.

Guided demo:
1. `DIR`
2. switch/login to B: if WordStar is separate
3. launch `WS`
4. return/reset

This is keyboard-only. Do not add mouse affordances.

## Builder target

`tiles/cpm22.sh` should:
- stage the Kaypro ROM set
- stage one bootable CP/M disk
- optionally stage WordStar disk
- convert source image formats reproducibly
- assert MAME reaches a nonblank text screen

## Proof checklist

- [ ] `kaypro2` boots CP/M
- [ ] `A>` prompt accepts rapid typing
- [ ] WordStar launches
- [ ] reset/relaunch returns to prompt
- [ ] screen crop preserves the Kaypro terminal proportions

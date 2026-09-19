# Integration seed — Symbian S60 on Nokia 5320

Tracking: #53  
Prep branch: `symbians60`  
Exhibition copy: `docs/lab/spa-drafts/symbians60.md`

## Proposed station shape

- **station id:** `symbians60`
- **runtime:** EKA2L1 in an isolated host-X11/nspawn station
- **closest sibling:** `medley`
- **scene archetype:** `touch-phone`
- **target device:** Nokia 5320 (S60 3rd Edition), because EKA2L1 explicitly calls it the most maintained N-Gage/S60v3 target
- **published surface:** EKA2L1 device window, not emulator menus

## Start here

```bash
scripts/dev/wt.sh new symbians60-work --from origin/symbians60
cd ../symbians60-work
scripts/dev/wave.sh alloc symbians60
python3 scripts/stations-registry.py new symbians60   --like medley --production --slot auto
```

After scaffold:
- change `spa.archetypeId` to `touch-phone`
- replace Medley's inner process with EKA2L1
- keep Xvfb/X11 capture + XTEST input initially

## Emulator acquisition

Pin an EKA2L1 Linux release or exact commit:
- https://github.com/EKA2L1/EKA2L1/releases

The builder should either:
1. download a pinned Linux release artifact, or
2. build a pinned commit reproducibly if no suitable artifact exists.

Do not use a floating latest build.

## Device/firmware acquisition

Target a Nokia 5320 firmware package containing:
- `.vpl`
- matching firmware payload files

EKA2L1 supports:
- ROM + RPKG, or
- full firmware via VPL

Use the **VPL path** for this station because it is the documented S60v3 workflow.

Reference:
- https://eka2l1.github.io/quickstart/basic/installdevice/

Stage the complete device firmware package under `assets/symbians60/media/` and pin hashes.

## First smoke procedure

Run EKA2L1 under Xvfb:

```bash
DISPLAY=:<display> ./eka2l1_qt
```

First run:
1. File → Install → Device
2. choose Firmware/VPL
3. select Nokia 5320 VPL
4. choose one English-capable regional variant
5. boot device

Once the installed EKA2L1 device-data directory is known, the **builder should stage that prepared device profile** so production startup does not repeat the install dialog.

## Input mapping

S60v3 is keypad/soft-key driven. Map at least:
- D-pad up/down/left/right/center
- left soft key
- right soft key
- menu/application key
- back/end
- numeric 0–9
- `*` and `#`

Prefer explicit station keyboard-profile buttons over asking visitors to memorize PC-key equivalents.

Pointer/touch is not required for the 5320 target.

## Intended golden/rest scene

Standby screen or main application menu with:
- signal/battery chrome
- soft-key labels visible
- Contacts and Messaging reachable immediately

Best guided demo:
1. open application menu,
2. open Contacts or Messaging,
3. back out using native soft keys,
4. reset.

## Reset strategy

This should be a relaunch from the same installed EKA2L1 device profile. Keep mutable phone state in a station-private work copy so reset can replace it from a pristine seed.

## Proof checklist

- [ ] EKA2L1 starts unattended inside nspawn/Xvfb
- [ ] Nokia 5320 profile boots
- [ ] keypad/soft keys mapped
- [ ] system survives repeated relaunch
- [ ] pristine-state reset proven
- [ ] emulator window cropped cleanly for streamhost

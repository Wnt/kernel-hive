# Integration seed — IBM MVS 3.8j / 3270

Tracking: #49  
Prep branch: `mvs38`  
Exhibition copy: `docs/lab/spa-drafts/mvs38.md`

## Proposed station shape

- **station id:** `mvs38`
- **runtime:** Hercules + x3270 inside the existing host-application/nspawn shape
- **closest sibling:** `medley` (Xvfb/X11 capture + XTEST + relaunch)
- **scene archetype:** change to `mono-terminal`
- **published surface:** x3270 only; Hercules operator console stays hidden
- **pointer:** optional; keyboard is the critical path

## Start here

```bash
scripts/dev/wt.sh new mvs38-work --from origin/mvs38
cd ../mvs38-work
scripts/dev/wave.sh alloc mvs38
python3 scripts/stations-registry.py new mvs38   --like medley --production --slot auto
```

After scaffold:
- set `spa.archetypeId=mono-terminal`
- replace Medley launcher/inner script with a container that starts Hercules and x3270
- keep `capture=x11` and the nspawn isolation pattern

## Media acquisition

Fastest smoke source: a turnkey MVS 3.8j TK5/TK4-style environment.

Reference implementation:
- https://github.com/joergschultzelutter/tk5-hercules

The repo's existing catalog already records the expected visitor path:
- Hercules IPLs MVS
- TCP 3270 listener becomes available
- x3270 connects to it
- TSO/ISPF is the museum surface

For the builder, stage the exact TK archive/config files under `assets/mvs38/` and hash them. Do not vendor a container image as the canonical source; extract the actual Hercules config/disks the station runs.

## First smoke commands

Run the turnkey system exactly as its package documents until TCP 3270 answers.

Connectivity proof:

```bash
nc -z 127.0.0.1 3270
```

Visitor-surface proof:

```bash
DISPLAY=:<display> x3270 -model 3279-2 127.0.0.1:3270
```

If the distribution uses a different local port, follow its config rather than forcing 3270.

## x3270 capture

Use a fixed Xvfb geometry large enough for a crisp terminal, e.g. 1024x768. Disable x3270 menus/toolbars if they distract from the terminal, but do not fake the 3270 screen in a generic terminal emulator.

The exact special-key mapping must include:
- Enter
- Clear
- PA1 if needed
- PF1–PF12 at minimum

Put these in the station keyboard profile/onscreen keyboard rather than requiring visitors to know x3270 host shortcuts.

## Intended golden scene

Preferred:
- connected 3270
- TSO/ISPF primary option menu or a clean TSO READY prompt
- no host shell and no Hercules messages visible

One guided demo:
- open a dataset/member or submit/show one tiny job
- return to the menu
- reset

## Reset shape

Reset should restart the isolated container/session from a known MVS disk set and reconnect x3270. It does not need to power-cycle the historical machine if a deterministic Hercules restart is faster.

## Proof checklist

- [ ] Hercules IPL reaches ready state unattended
- [ ] TCP 3270 listener appears
- [ ] x3270 connects under Xvfb
- [ ] keyboard + PF keys proven
- [ ] relaunch gives a clean TSO/ISPF scene
- [ ] no Hercules operator console leaks into the published framebuffer

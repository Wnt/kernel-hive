# Integration seed — Multics MR12.8

Tracking: #51  
Prep branch: `multics`  
Exhibition copy: `docs/lab/spa-drafts/multics.md`

## Proposed station shape

- **station id:** `multics`
- **runtime:** DPS8M in nspawn + fullscreen terminal client
- **closest sibling:** `medley` for nspawn/X11 capture
- **scene archetype:** `mono-terminal`
- **published surface:** terminal attached to Multics line, not DPS8M operator console
- **pointer:** none required

## Start here

```bash
scripts/dev/wt.sh new multics-work --from origin/multics
cd ../multics-work
scripts/dev/wave.sh alloc multics
python3 scripts/stations-registry.py new multics   --like medley --production --slot auto
```

After scaffold, switch the archetype to `mono-terminal` and replace the Medley inner process with DPS8M + terminal startup.

## Media acquisition

Use the MR12.8 QuickStart path rather than rebuilding the historical system from distribution tapes in the first wave.

Reference:
- https://multicians.org/simulator.html

Expected staged shape:
- DPS8M binary/source pin
- MR12.8 QuickStart directory/files
- boot ini, e.g. `MR12.8_boot.ini`

Pin all downloaded archive hashes in the builder.

## First smoke command

From the QuickStart directory:

```bash
./dps8 MR12.8_boot.ini
```

Then prove the user terminal:

```bash
telnet 127.0.0.1 6180
```

For the gallery use a fixed-size X terminal under Xvfb instead of a raw host TTY:

```bash
DISPLAY=:<display> xterm -geometry 100x32 -e telnet 127.0.0.1 6180
```

The exact terminal program can change later; the invariant is that simulator diagnostics never share the visitor framebuffer.

## Container layout

Use the same safety shape as other host applications:
- read-only/base root where practical
- station-private work dir
- private network unless the guest network is intentionally exposed
- no host filesystem access except staged assets/runtime dir

DPS8M and the terminal should be supervised together; if one exits, relaunch the whole station cleanly.

## Intended golden/rest scene

This station probably does **not** need a frozen VM-state golden. A deterministic relaunch to a clean Multics login is preferable.

Rest scene:
- Multics login / command processor
- terminal fills most of the screen
- no shell prompt from Linux host

Guided demo:
- login
- show current users/directory
- open help or list a directory
- reset

## Proof checklist

- [ ] MR12.8 QuickStart boots unattended
- [ ] port 6180 becomes reachable
- [ ] X terminal attaches and accepts keyboard input
- [ ] relaunch returns to the same login state
- [ ] host/DPS8M console remains hidden
- [ ] measured startup time recorded

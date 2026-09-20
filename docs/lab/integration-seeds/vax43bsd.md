# Integration seed — 4.3BSD on VAX-11/780

Tracking: #56  
Prep branch: `vax43bsd`  
Exhibition copy: `docs/lab/spa-drafts/vax43bsd.md`

## Proposed station shape

- **station id:** `vax43bsd`
- **runtime:** SIMH `vax780` inside nspawn + fullscreen X terminal
- **closest sibling:** `medley`
- **scene archetype:** `mono-terminal`
- **pointer:** none required
- **published surface:** a clean login/session terminal, not SIMH operator output

## Start here

```bash
scripts/dev/wt.sh new vax43bsd-work --from origin/vax43bsd
cd ../vax43bsd-work
scripts/dev/wave.sh alloc vax43bsd
python3 scripts/stations-registry.py new vax43bsd   --like medley --production --slot auto
```

Replace the Medley inner process with SIMH + terminal startup and change archetype to `mono-terminal`.

## Media acquisition

For the **reproducible builder**, use the stock 4.3BSD distribution files from a TUHS/4BSD archive:

- `stand.gz`
- `miniroot.gz`
- `rootdump.gz`
- `usr.tar.gz`
- `srcsys.tar.gz`
- `src.tar.gz`
- optionally `new.tar.gz`, `ingres.tar.gz`, `vfont.tar.gz`

Install reference:
- https://gunkies.org/wiki/Installing_4.3_BSD_on_SIMH

For the **first smoke only**, using an already-installed 4.3BSD SIMH disk is acceptable to prove capture/input. The builder should still be able to reproduce the disk from the distribution set afterward.

## Canonical SIMH config

The documented VAX-11/780 install uses RA81 disks. A final boot config is essentially:

```
set rq0 ra81
att rq0 rq.dsk
set rq1 dis
set rq2 dis
set rq3 dis
set rp dis
set lpt dis
set rl dis
set tq dis
set tu dis
att ts 43.tap
set tti 7b
set tto 7b
load -o boot42 0
d r10 9
d r11 0
run 2
```

At the boot prompt:

```
: ra(0,0)vmunix
```

The published station should hide this operator/startup console after boot.

## Visitor terminal path

The install guide documents the DZ serial interface as a cleaner remote-user surface:

Inside BSD once:

```sh
cd /dev
sh ./MAKEDEV dz0
```

SIMH config:

```
set dz lines=8
att dz 8888
set dz 7b
```

Then the gallery can show:

```bash
DISPLAY=:<display> xterm -geometry 100x32 -e telnet 127.0.0.1 8888
```

This is better than exposing SIMH's simulator console.

## Intended rest scene

Login prompt or root shell with:

```
4.3 BSD UNIX ...
login:
```

A curated logged-in scene can show `uname`, `who` and `netstat`.

Keep TCP/IP optional: the historical network stack is the story, but SIMH/VAX Ethernet reliability should not block the station. The DZ terminal is enough for the first release.

## Reset strategy

Relaunch from a pristine RA81 image copy. If the disk is writable during visits, reset should replace the work copy from a hashed seed before starting SIMH.

## Proof checklist

- [ ] stock 4.3BSD reaches multiuser login
- [ ] DZ/telnet visitor line works
- [ ] keyboard input proven through X terminal
- [ ] relaunch restores pristine disk
- [ ] SIMH console is not visible to visitor
- [ ] measured boot-to-login time recorded

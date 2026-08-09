# pdp11 boot capture — bridge prep

Status: **AUTHORED-UNTESTED**. No clip is recorded and `spa.bootVideo` is unset;
this file and the `pdp11)` arm in `bootrec-tiles.conf` exist so the cold-boot
path is audited, as the playbook requires before a tile ships.

The arm copies only the bridge `overlay.qcow2` (its shared base stays
read-only) and rewrites SSH 5827→6827. Before recording it stops `getty@tty1`
and, over clone SSH, kills the simulator **by resolving `/proc/<pid>/exe` to
`/opt/pdp11/bin/pdp11`** — never `pkill -f pdp11`, which on this tile matches
the recording shell itself. After capture it starts the kiosk again. Bridge
kind intentionally skips `savevm`.

**Zero input is genuine, and a cold boot reaches the fixture.** This is worth
stating carefully, because a PDP-11 normally does not boot unattended: 2.11BSD's
boot block stops at a `:` prompt asking which kernel to load, and single user
waits for `^D`. Both answers are given by the kiosk's own console driver
(`/opt/pdp11/pdp11-console.py`), which walks that dialogue and then becomes a
transparent relay — so from power-on to the multiuser `login:` prompt nothing
outside the guest types anything. The last frame of a clip would therefore hand
off to the golden's first frame cleanly.

SIMH's own `EXPECT`/`SEND` was tried first and did not fire against the boot
block; do not "simplify" the arm by putting the answers back in the `.ini`.

**Timings measured on the live tile** (cold QEMU power-on to the fixture,
~60 s total): GRUB and the Debian kiosk are silent and reach X in ~15 s, the
simulator prints its banner and `70Boot from ra(0,0,0)` almost immediately, the
2.11BSD kernel reaches single user at ~8.5 s of simulated boot and the multiuser
`login:` at ~11 s, with the remainder spent on X startup and the 10 %-throttled
simulator. Ready means the green 80×24 terminal showing
`2.11 BSD UNIX (pdp11) (console)` and `login:` with the block cursor present;
the builder's own readiness predicate is the pair
"`login: ` present in `/tmp/pdp11-console.log`, no `hard error|panic|dumping`"
plus a green-ink count above 12 000 on the captured framebuffer (a healthy
fixture measures ~21 900).

Canvas is the QEMU kiosk's scanout at 30 fps; the X root is 1024×768. There is
**no audio** — the AC97 card is in the device set only because the golden was
baked with it, and a console terminal has nothing to play.

**Do not add `set cpu idle` to the `.ini` when adapting this arm.** It looks
like free CPU (2.4 % instead of 19.7 %) and it silently breaks every subsequent
`loadvm`: SIMH's idle detection rides on a calibrated timer that a snapshot
restore destroys, after which keystrokes take 38–80 s to echo, or never do.
See `docs/guests/pdp11.md`.

# domainos — facts for release notes

**What arrived:** an Apollo DN3500 (1989), running Domain/OS SR10.4.1 —
Apollo Computer's own UNIX-derived, distributed, single-level-store
operating system, on host-native MAME (`dn3500` driver). No bridge kiosk was
ever built for this station.

**Year:** 1989 (the DN3500 is MAME's 1989 machine; the SR10.4.1 release is
1994, and this particular disk was last written in 2002 — an Apollo that
stayed in service).

**What a visitor can do:** the exhibit is Apollo's own Display Manager (DM),
driven by function keys rather than a mouse — `F1` opens a `Command:` bar to
start a shell pad or a live process display, `F11` aborts back to input,
`F6` clears the command line. There is no boot-menu program; the DM itself
is the interaction. The pointer does not track (see below), so this is a
keyboard-only station, like `apple2e` and `samcoupe`.

**What was hard, in order of cost:**
1. MAME's fleet-wide 0.289 pin hangs the DN3500's Normal-mode keyboard
   self-test — every boot goes black forever. The station is pinned to
   0.276 instead, a per-station override now supported by the native build
   script.
2. The boot ROM halts on a "more than 14 days since last shutdown" calendar
   check that no amount of clock-faking satisfies (Domain/OS windows a
   spoofed year through its own two-digit logic). The fix is a one-time
   Service-mode `EX CALENDAR` run baked into the disk; a visible side
   effect is that the guest's clock now reads 1981.
3. The pointer doesn't move, and it's now understood exactly why: the
   emulated keyboard is a 1200-baud serial device that only reports the
   mouse once the operating system has taken it out of "compatibility
   mode", and Domain/OS never does — proven by attaching a debugger to the
   running emulator and watching the mode-setting call never fire once
   across a whole boot, login and mouse burst. The two-byte handshake that
   would unlock it is known, and the likeliest reason it is never sent is a
   Display Manager startup file this disk does not have. Wiring it up is the
   next step, not done this wave.
4. The keyboard needed its own pacing profile — 180 ms per key edge — since
   it's a serial device, not a scanned matrix, so the fleet's usual
   matrix-scan pacing knob doesn't apply here.

**Checkpoint:** the driver keeps no save state of its own, so a reset needs
a dedicated patch (in progress, in another stream of this wave) before a
visitor's session can be handed back to a clean screen; until then a reset
leaves the previous visitor's frame on the glass.

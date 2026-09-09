# domainos — facts for release notes

**What arrived:** an Apollo DN3500 (1988), running Domain/OS SR10.4.1 —
Apollo Computer's own UNIX-derived, distributed, single-level-store
operating system, on host-native MAME (`dn3500` driver). No bridge kiosk was
ever built for this station.

**Year:** 1988 (Domain/OS SR10.4.1 winchester image last recorded 2002-07-31,
but the hardware and OS lineage are 1988).

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
   emulated keyboard is a 1200-baud serial device that stays in a
   "compatibility mode" MAME never leaves because Domain/OS's own pointer
   initializer script is missing from the disk. The two-byte handshake that
   would unlock it is known; wiring it up is the next step, not done this
   wave.
4. The keyboard needed its own pacing profile — 180 ms per key edge — since
   it's a serial device, not a scanned matrix, so the fleet's usual
   matrix-scan pacing knob doesn't apply here.

**Checkpoint:** the driver keeps no save state of its own, so a reset needs
a dedicated patch (in progress, in another stream of this wave) before a
visitor's session can be handed back to a clean screen; until then a reset
leaves the previous visitor's frame on the glass.

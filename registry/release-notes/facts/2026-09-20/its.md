# its — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[ITS](station:its) joins the museum</u> — the Incompatible Timesharing
System, written at the MIT AI Lab starting in 1967 by the people who later
built early hacker culture around it (and gave the world the jargon file).
It runs on an emulated DEC PDP-10 under SIMH, and unlike almost everything
else in the museum, there was never a product to install: the exhibit's
disk was built by cloning the ITS project's own source tree and letting it
boot a PDP-10 and assemble the whole system from scratch, on this machine,
for this station.

The visitor surface is a single terminal into a live DDT session — DDT
being ITS's combination debugger/command interpreter, the closest thing
the system has to a shell. A visitor can list the system directory
(`:LISTF SYS;`) and see real file timestamps running from 1977 to 1987,
paged behind ITS's own `--More--` prompt. There are no passwords anywhere
in ITS — not a gap, the actual system, which the museum leaves as-is and
lets the surrounding container be the security boundary instead.

What was hard: ITS's 1967-era kernel refuses to boot at all without a
Chaosnet interface present — MIT's own pre-Ethernet local network hardware
— even though nothing ever needs to answer on the other end; without the
interface it panics into its own debugger complaining the "breaker" is
tripped. And logging a fresh connection in isn't automatic: ITS doesn't
greet an incoming terminal at all, because on the real system the boot
messages went to the operator's console, not to a visitor's line — the
station has to send one keystroke (Control-Z, the ITS login gesture) to
get a screen with anything on it at all, and offers that same key on the
on-screen keyboard for a visitor who logs out and wants back in. The
control-character vocabulary that follows (Control-Z, Altmode/Escape,
Control-X, Control-C, Control-L) sits in the always-visible row of the
keyboard rather than behind a "more" button, since those keys are how
anything on ITS gets done at all.

Reset is a full relaunch, proven clean: a file created by a visitor
disappears completely after a reset, and the seed disk's checksum never
moves.

What's open: no network plane (ITS spoke ARPANET and Chaosnet, neither has
anywhere real to go here) — deliberate for this first release, matching
the other 1970s-80s terminal exhibits landed alongside it this week.

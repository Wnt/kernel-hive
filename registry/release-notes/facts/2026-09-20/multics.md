# multics — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[Multics](station:multics) joins the museum</u> — MR12.8, the final
release (1992) of the system that began at MIT in 1965 and whose ideas
(hierarchical filesystems, dynamic linking, ring-based protection) shaped
Unix by way of the people who left the project to write it. It runs on an
emulated Honeywell DPS-8/M under the DPS8M simulator, and the exhibit is
one terminal logged into a real Multics session as user `Repair`.

Multics doesn't greet a connecting terminal with a login prompt — it prints
its banner and waits, assuming a 1969 user already knows the word is
`login`, so the museum's own type-in demo is what tells a visitor how to
start. Once in, the system feels foreign on purpose and the station leaves
that alone rather than smoothing it over: `#` erases a character and `@`
kills a whole line (both proven by typing deliberately garbled text and
watching Multics clean it up), `>` separates path components instead of
`/`, and Ctrl-C doesn't cancel — it suspends into a new command level,
which a visitor backs out of with `release`.

What was hard: the terminal line a visitor connects to isn't handed
straight to Multics. The emulated network hardware (an FNP, front-end
processor) first offers a 32-channel raw connection menu that would fill a
third of the screen with 1970s telephony plumbing before a visitor ever
saw the actual banner, and stock telnet's own connection chrome would add
more on top. The station replaced the terminal client with a small bridge
that answers that menu itself and strips telnet's own noise, so what's on
screen is only the Multics banner. The same bridge also fixes a dead-end:
a visitor who types `logout` — which is the correct, and demonstrated, way
to leave a Multics session — would otherwise be dropped by stock telnet
into a disconnected terminal that every subsequent visitor would inherit
until the next reset happened to run; the bridge reconnects at a fresh
banner instead.

Getting the machine itself installed took real care: the released
distribution forces a password change on first login, which the station
pays for once during the build rather than showing a visitor a "change
your password" prompt as the first thing Multics ever says to them.

What's open: no network — Multics had ARPANET service in its day, but this
first release is a single terminal line, an island by design, matching the
posture of the wave's other 1970s-80s exhibits landed alongside it
(vax43bsd, mvs38, its). One installed command, `print_wd`, isn't present
on this particular build and isn't part of the demo.

# vax43bsd — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[4.3BSD](station:vax43bsd) joins the museum</u> — Berkeley's June 1986
release, on an emulated **DEC VAX-11/780** under Open SIMH. A visitor gets
one terminal line into a real timeshared Unix: the exhibit is a single
telnet-style session onto the VAX console, no pointer (there wasn't one to
have), full keyboard. The login banner is period-authentic down to "Would
you like to play a game?" and the warning not to log in as root, and
`/usr/games` is fully populated — adventure, backgammon, chess, fortune,
hangman and the rest.

This station is the first of a small cluster of 1970s-80s
timesharing exhibits landed together this week (alongside mvs38, multics
and its), and it's the one that worked out the shared plumbing the others
reused: how to run an old-world simulator with a modern browser terminal
in front of it, contained rather than bridged. Two things that plumbing
had to solve here first — keeping keyboard focus pinned on the terminal
window since there's no window manager to do it, and knowing when the
machine is actually ready rather than just listening on a port: 4.3BSD's
`getty` prints its login banner once, at boot, into a line nobody is
watching yet, so a later visitor connecting sees silence for nearly 25
seconds unless the station sends one keystroke itself to make it reprint.

Reset is a full relaunch — this simulator has no checkpoint format, so
"reset" means kill it, copy the pristine disk back, and boot cold again,
proven to erase anything a visitor wrote. Cold boot takes 53-60 seconds
end to end, mostly filesystem checks on a cleanly-halted disk.

What's open: the disk carries a genuine 4.3BSD install but no kernel
source tree (it wasn't on the distribution tape sourced for this release),
so `/usr/src` isn't there to browse. There's no network — this station is
an island by design, one of eight DZ11 terminal lines wired up and seven
left unused, which is itself a small piece of the real 1986 timesharing
experience: a visitor is one of several who could be logged in.

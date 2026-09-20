# mvs38 — facts for the week closing 2026-09-20

Raw material for the Sunday authoring pass.

## New stations

<u>[MVS 3.8j](station:mvs38) joins the museum</u> — IBM's OS/VS2 MVS, the
1981 service level, the last version IBM ever put into the public domain
(which is the only reason a museum can run it at all). It runs under
Hercules, the open-source mainframe emulator, via the TK5 distribution, and
the exhibit is a real IBM 3270 terminal session logged all the way in to
ISPF, the menu system mainframe operators and programmers navigated for
decades.

Getting there is not automatic and none of it is discoverable by guessing:
the emulator paints its own device logo on the 3270 first, with fields
locked, so a visitor's first keypress would just lock the keyboard — the
station has to send a `Clear` first, then ask for `TSO`, then answer a
userid and password prompt and click through the site's welcome banners,
before ISPF's primary option menu ever appears. The whole chain is driven
by watching the actual text on the 3270 screen and reacting to it, because
four consecutive screens in that sequence differ by exactly one line and
nothing shorter than reading the text tells them apart.

MVS itself takes about 55 seconds to finish starting its network stack and
another 17 after that to have the ISPF menu ready — the emulator's telnet
port opens in the first 8 seconds, long before any of that, so the station
had to learn to wait for a specific log line rather than the open port.
This "port open but not ready" gap is a pattern this wave hit on more than
one 1970s-80s terminal exhibit.

What a visitor can do: navigate ISPF, log real TSO commands, and see the
system genuinely allocate and catalog a dataset — proven by creating one,
resetting the station, and watching it be gone, exactly as a fresh IPL
should leave it. The terminal only shows what belongs to the guest: the
emulator's own startup banner (which would otherwise print the host
machine's real name and CPU count onto the museum's screen) is replaced
with one that keeps only the facts that are actually part of the emulated
mainframe.

What's open: pressing the PF1 help key on the main menu returns "PANEL NOT
FOUND" — that's a gap in the TK5 distribution's own install, not something
this station broke. There's no audio, no network and no pointer, all
authentic to a 3270 terminal.

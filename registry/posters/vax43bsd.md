---
title: 4.3BSD
subtitle: 1986 · Berkeley Unix on a VAX-11/780 — the release the internet grew up on
hero: /posters/vax43bsd/desktop.webp
images:
  - src: /posters/vax43bsd/desktop.webp
    alt: A green-on-black 80-column terminal showing the 4.3BSD login banner for the host kernelhive, a root login, the June 1986 version line, the message of the day ending "Would you like to play a game?", and the kernelhive# prompt
    caption: The whole station is this one terminal. A VT100 on line 0 of a DZ11, into a VAX-11/780 in a machine room — which in 1986 was what using a computer looked like for most of the people who were about to build the internet.
---
## Origins

Unix came out of Bell Labs. Berkeley Unix came out of the fact that AT&T,
barred by a 1956 consent decree from selling computers, licensed Unix to
universities for the cost of the tape.

Ken Thompson spent the 1975–76 academic year at his old department in
Berkeley and left a Version 6 Unix running on their PDP-11. Graduate students
started fixing and extending it — a Pascal system, and an editor a student
named Bill Joy wrote called `ex`, which grew a full-screen mode called `vi`.
In 1978 Joy started mailing out tapes of the collection. He called it the
Berkeley Software Distribution, and he charged $50 for the postage.

Then DARPA came looking. The agency was funding the ARPANET's move to a new
protocol suite, TCP/IP, and it needed a single reference Unix that every
funded site could run on the new 32-bit DEC VAX. In 1980 it gave the contract
to Berkeley, and the Computer Systems Research Group was born.

## Significance

What the CSRG built, and shipped as 4.2BSD in 1983, is the shape of the
network software still in use today. Bill Joy and Sam Leffler's team did not
just port a protocol stack; they invented an *interface* for it. A network
connection would be a file descriptor. You would create one with `socket()`,
attach it to an address with `bind()`, reach out with `connect()`, and then
read and write it like any other file.

That was not obvious. It meant one API could carry TCP, but also Unix domain
pipes, and whatever came next. It is why the same five calls work today in C
on Linux, in Python on a laptop, and — through Winsock, a near-literal port —
on Windows. 4.2BSD also brought the Fast File System, long file names,
job control, `sendmail` and the Berkeley Internet Name Domain server. BIND
still answers most of the world's DNS.

4.2BSD was a landmark and it was slow. 4.3BSD, released in June 1986, is the
same system made to work: reworked TCP with Van Jacobson's congestion
control on the way, a faster kernel, better buffering. It is the release the
ARPANET actually ran on, the one Sun, DEC, HP and every other workstation
vendor licensed, and the direct ancestor of FreeBSD, NetBSD, OpenBSD, of
macOS's networking, and of the sockets layer in almost everything else.

## What you're looking at

A VAX-11/780 with eight megabytes of memory, one RA81 disk and a DZ11
terminal multiplexer. You have a VT100 on line 0.

There is no desktop, no mouse and no window to move. There is a `login:`
prompt, and — because this is 1986 and the machine is in a locked room —
`root` has no password. The message of the day is the one the distribution
shipped with, and it ends by asking whether you would like to play a game.

Useful things to type. `hostname`, and `date`, which will tell you it is
1986. Not `uname` — that does not exist yet, it arrives with System V. `who`,
to see whether anyone else is on. `man man`. `vi`, which is *the* editor here
and is still installed on the machine you are reading this on. And
`ls /usr/games`, which is where the department's real work got done:
`adventure`, `rogue`, `chess`, `hangman`, `doctor`, `fortune`, and a `ching`
that will cast the I Ching for you, all shipped by a university with a
straight face.

`^C` interrupts, `^D` logs you out, `^U` throws away the line you are typing.
They are on the keyboard because on this machine they are not shortcuts —
they are the interface.

---
title: DEC PDP-11 — RT-11, RSX-11M, RSTS/E
subtitle: 1970 · PDP-11 · RT-11 / RSX-11M / RSTS-E
hero: /posters/decos/desktop.webp
images:
  - src: /posters/decos/desktop.webp
    alt: A DEC PDP-11 in a rack, its front panel a row of switches and lamps, with a terminal beside it
    caption: The hero photograph this poster wants is a PDP-11 in its cabinet — the switch-and-lamp front panel of an 11/70 or an 11/40, ideally with a VT52 or VT100 next to it and the two RL02 drives below. Not a bare board and not a museum plinth: the machine as it stood in a laboratory or a machine room, with cables.
---
## Origins

Digital Equipment Corporation announced the PDP-11 in 1970. It was meant to be a small, cheap 16-bit machine, and it turned into the longest-lived computer architecture the company ever built: models kept shipping until 1997, twenty-seven years, and something on the order of half a million of them were sold.

Two ideas made it. The first was the Unibus, a single bus onto which memory, processor and every peripheral were attached as addresses; there were no special I/O instructions, because a disk controller was just some memory locations you could write to with the ordinary MOV. The second was an unusually regular instruction set — eight general registers, and addressing modes that worked the same way on all of them — which made the machine pleasant to write compilers for, and pleasant to write assembly for by hand.

It arrived at exactly the right size and price to be bought by people who were not computer departments: physics labs, hospitals, telephone exchanges, newspapers, machine shops, schools. That is the reason for the exhibit you are looking at.

## Significance

DEC did not sell you a computer with an operating system. It sold you a computer, and then you chose one — and the choice said what the machine was for.

**RT-11** was the single-user real-time monitor. It was small, it was fast, it got out of the way, and it is the one that ran the instrument in the corner of the laboratory: the spectrometer, the milling machine, the patient monitor. Its prompt is a full stop.

**RSX-11M** was the multi-user real-time executive: priority-scheduled tasks, several users, still hard enough real-time to run a factory. Its prompt is a right angle bracket.

**RSTS/E** was timesharing. Its point was to put a couple of dozen people on one PDP-11 at once, each at a terminal, most of them writing BASIC-PLUS, and in the 1970s and 1980s that meant a whole class in a school. Under BASIC-PLUS its prompt is a word: `Ready`; under DCL, which is what the console here comes up in, it is a dollar sign.

There was a fourth choice, and it is the one history remembers. Ken Thompson and Dennis Ritchie wrote the Sixth and Seventh Editions of Unix on PDP-11s at Bell Labs, and the C language grew up on the same hardware. Unix's file abstraction and C's pointer arithmetic both carry the shape of this machine's address space. Every Unix and Linux tile in this gallery is descended from a program that first ran on a PDP-11.

## What you're looking at

A chooser, and then whichever of the three you press. This is one exhibit rather than three because a visitor cannot be expected to tell `.` from `>` from `$`, and three identical green screens would look like an accident. The placard names each one, says what it was for, and prints the prompt to watch for.

Press **1** and RT-11 V5.3 boots off an RL02 pack in about two seconds and prints DEC's own welcome text. Press **2** and RSX-11M V4.2 comes up off an RD52, asks nothing (the exhibit answers its date and terminal-width questions for you) and leaves you at MCR. Press **3** for RSTS/E V9.6, and read the small print on the placard while you do: DEC's installation procedure ends by asking for a second “Library” tape, and no copy of that tape survives, so the system here boots and answers but its packaged commands were never wired up. It is shown that way rather than not shown at all.

The versions are not arbitrary. Mentec, which bought the PDP-11 software rights from DEC in 1994, granted a free non-commercial licence in 1997 covering **RT-11 V5.3 or prior, RSTS/E V9.6 or prior, RSX-11M V4.3 or prior** and RSX-11M-PLUS V3.0 or prior, for use with an emulator. Those exact ceilings are what runs here — which also means that the later versions the hobbyist community circulates most widely are not permitted, and are not used. One honest caveat is on the placard itself: **RSX-11M here is V4.2, not the V4.3 the licence would allow**, because no reachable copy of V4.3 survives on the public internet.

The machines underneath are simulated by Open SIMH, the maintained free-software continuation of Bob Supnik's simulator: an 11/73 with 256 KB for RT-11, an 11/70 with 4 MB for the other two.

## Legacy

Follow the `>`.

RSX-11M was built by a small group at DEC led by Dave Cutler. When DEC started designing the 32-bit machine that would replace the PDP-11, that group was given the operating system, and the result was VMS on the VAX — a system whose scheduling, its notion of a privileged executive, and much of its personality came from RSX-11. In 1988 Cutler left for Microsoft and led the team that built Windows NT, and NT's kernel is recognisably the work of the same people.

This gallery has all three ends of that thread. The `>` you are looking at, `openvms` a few tiles away, and the Windows NT family after it are one continuous line of descent, and it starts on this machine.

The PDP-11 has one more quiet monument. When DEC finally stopped making them in 1997, the last customers were not hobbyists — they were nuclear power stations, steel mills and railway signalling systems, running RSX-11 and RT-11 code written decades earlier, because the machine did the job and nothing had happened to make it stop.

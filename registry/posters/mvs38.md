---
title: IBM MVS 3.8j
subtitle: 1981 · the mainframe behind the green screen — TSO, ISPF and JCL on a System/370
hero: /posters/mvs38/desktop.webp
images:
  - src: /posters/mvs38/desktop.webp
    alt: A colour 3270 terminal screen showing the ISPF primary option menu — a numbered list of options from BROWSE and EDIT to BATCH and COMMAND, with a status block on the right reading USERID HERC01, TERMINAL 3277, SYSTEMID TK5R
    caption: The ISPF primary option menu on an IBM 3279 colour display. This is a form, not a command line — you move between fields with Tab, fill one in, and press Enter to send the whole screen to a computer that is somewhere else entirely.
---
## Origins

In 1964 IBM bet the company on System/360: one architecture, from the smallest
machine to the largest, running one operating system. The bet paid off and the
operating system nearly sank it. OS/360 was late, enormous, and so hard to
reason about that Fred Brooks wrote *The Mythical Man-Month* about managing it.

What came out the other side, and kept coming, is a single unbroken line. OS/360
grew virtual memory and became OS/VS2. In 1974 IBM gave every job its own
16-megabyte address space and called it Multiple Virtual Storage — MVS. Release
3.8, from 1979 and serviced into 1981, is the last version IBM ever placed in
the public domain. That accident of licensing is why this exhibit can exist at
all: MVS 3.8j is the only industrial-strength IBM mainframe operating system
anybody is free to run.

## Significance

Everything about this machine assumes a computer is a scarce, shared, expensive
thing that you submit work to. You do not run a program — you write JCL, a job
control language of `//STEP EXEC PGM=` cards, and submit it to JES2, which
queues it, runs it when it can, and files the printout in a spool you go and
read afterwards. TSO, the Time Sharing Option, was bolted on so that humans
could talk to this batch machine interactively at all, and ISPF put full-screen
panels on top of TSO.

The terminal is the strangest part, and the most important. An IBM 3270 is not a
teletype pretending to be a screen: it is a *block-mode* device. It holds a
whole formatted screen in its own memory, lets you type into the unprotected
fields, and sends nothing at all down the line until you press an Attention
Identifier key — Enter, Clear, or one of PF1 through PF24. The channel between
terminal and mainframe carries screens, not characters. It is why a 3270 could
serve thousands of users on a machine with a fraction of a modern phone's
power, and it is why, if you type into the wrong place, the keyboard simply
locks and the screen says `X SYSTEM` until you press Reset.

MVS became MVS/XA, then MVS/ESA, then OS/390, then z/OS. The JCL you can write
on this screen would still run, largely unchanged, on the machine that
authorises your card payments.

## What you're looking at

A System/370 emulated by Hercules, running the TK5 distribution of MVS 3.8j,
with one IBM 3279 colour display attached to the channel at device address
00C0. The exhibit logs itself on to TSO and rests on the ISPF primary option
menu, the screen an operator or a systems programmer would have spent their
working day inside.

Try option 3 for the utilities, option 6 for a TSO command line, or T for the
tutorial. PF1 is help and PF3 is "go back" — on a mainframe the function keys
are the navigation, not the arrow keys, which move the cursor inside the form.
PF3 from this menu leaves ISPF entirely and drops you to TSO's bare `READY`
prompt, which is worth doing once: type `TIME`, or `LISTC`, and then `ISPF` to
come back. If the keyboard stops responding and a red `X` appears at the bottom
of the screen, that is 1981 working exactly as designed — press Reset.

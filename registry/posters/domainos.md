---
title: Apollo Domain/OS
subtitle: 1989 · a DN3500, the Display Manager, and a network that was one file system
hero: /posters/domainos/desktop.webp
images:
  - src: /posters/domainos/desktop.webp
    alt: Three overlapping text windows with coloured title bars on a black screen, above a command line reading Command
    caption: The Display Manager. Each window is a "pad" with a transcript above and an input line below; the bar along the bottom is the DM's own command line. The listing on the left is the root of a Domain/OS disk — bsd4.3 and sys5.3 sitting side by side is the point of the release.
---
## Origins

Apollo Computer was founded in 1980 in Chelmsford, Massachusetts, by William Poduska, who had already helped start Prime Computer and would later start Stardent. Its first machine, the DN100, shipped in 1981 — before Sun Microsystems existed, and before anybody had settled on what the word "workstation" meant. For most of the decade Apollo was the largest maker of them in the world.

What made an Apollo an Apollo was not the processor. It was DOMAIN: the Distributed Operating Multi-Access Interactive Network, which is a 1981 acronym doing its best to describe a genuinely radical idea. Every Apollo on a site was wired into a 12-megabit token ring, and every machine on that ring saw one file system. Not a mounted share, not a network drive with a letter — one namespace, in which a file on the machine down the corridor was `//thatnode/some/file` and could be opened exactly the way a local one was. Below that, the operating system did not really read and write files at all: objects were mapped into a process's address space and paged, over the network if necessary, so that "open a file on another computer" and "touch some memory" were the same operation. Engineers who used these machines in the 1980s tend to describe the experience in the tone other people reserve for a first car.

The DN3500 on this station is from 1989, near the end of the independent company: a Motorola 68030 at 25 MHz, 16 MB of memory, and an eight-plane colour framebuffer.

## The Display Manager

Domain/OS boots into the Display Manager, and the DM is not a window manager. There is no desktop metaphor here, no icons, no menus — there was not yet a consensus that a graphical system needed any of those. What there is instead is a screen full of **pads**: each one a scrolling transcript of a process, with its own small input line underneath, and a title bar that this machine paints in a different colour for each. The bar across the bottom of the screen is the DM's own command line, and it is how you manage the display: `cp /com/sh` creates a shell in a new pad, `cp /com/pst` creates a pad running the process display, `wp` pops a window to the front.

The Apollo keyboard was built for it. To the left of the ordinary keys sits a second pad of them, labelled not F1 to F10 but **SHELL**, **CMD**, **CUT**, **PASTE**, **MOVE**, **GROW**, **MARK**, **AGAIN**, **READ**, **EDIT**, **SAVE**, **EXIT**, **ABORT**, **HELP** — the window and editing verbs given real, dedicated keys rather than chords. On this station the emulator maps them onto the function-key row: F1 is SHELL/CMD and puts you on that bottom command line, F11 is ABORT and hands you back to the shell.

The release is SR10.4.1, and SR10 is why the listing in the corner window looks the way it does. Until 1988 the operating system was called Aegis and was its own thing, related to Unix by conviction rather than by descent. SR10 renamed it Domain/OS and shipped three environments in one system — Aegis, BSD 4.3 and System V — so that `/bsd4.3` and `/sys5.3` are both simply there, and a user chose which one their login inhabited. That is a remarkable act of hedging by a company that had spent eight years arguing its own design was better.

## What you are looking at

The window on the right is `pst`, the process display, and it is worth reading. Past `init` and `display_manager` there are four daemons — `rgyd`, `glbd`, `lcpd`, `mbx_helper` — that are not Unix daemons at all. They belong to Apollo's Network Computing System: `rgyd` is the network registry that held the accounts for a whole ring of machines, and `glbd` is the **Global Location Broker**, the service you asked where in the network a given interface lived.

NCS is the part of Apollo that outlived Apollo. When the Open Software Foundation went looking for a remote procedure call for its Distributed Computing Environment, it took Apollo's; DCE RPC is NCS grown up, Microsoft's RPC is DCE RPC, and the UUID in the corner of every modern system is Apollo's identifier scheme, still in use, still 128 bits. A machine on this screen is telling you its own location broker is running, in 1989, on a token ring, for a network of workstations that mostly no longer exist.

Hewlett-Packard bought Apollo in 1989 for around $476 million, and the DN3500 was among the last designs of the independent company. HP kept Domain/OS alive into the late 1990s and moved the customers onto HP-UX and PA-RISC, which is the ordinary ending. The unusual part is how much of the idea escaped: the single global namespace, the location broker, the identifier, and the still-unmatched trick of a network that behaved like a file system rather than a file system that had been taught about networks.

This exhibit is keyboard-only. The Apollo's three-button mouse is on the far side of an emulated keyboard controller that never negotiates its way out of compatibility mode, so the pointer does not move — which leaves you where an Apollo user of 1989 would have been perfectly comfortable, at the DM command line with a shell pad open.

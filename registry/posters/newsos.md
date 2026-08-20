---
title: NEWS-OS 4.1R
subtitle: 1991 · Sony's BSD Unix workstation, folded into a laptop
hero: /posters/newsos/desktop.webp
images:
  - src: /posters/newsos/desktop.webp
    alt: The NEWS-OS 4.1R desktop on a 1120×780 monochrome LCD — Sony's NEWS Desk environment with three windows open: sxbitmap (a 48×48 bitmap editor showing "sxbitmap Version 2.1, Copyright 1990, 1991 Sony Corp."), a file manager browsing "/usr" with rows of folder icons (bin, etc, games, man, people, sony, ucb…), and sxedit, a small text editor
    caption: NEWS-OS 4.1R at work on the NWS-3260's monochrome LCD. This is a full 4.3BSD Unix — X11, a windowing desktop and Sony's own tools — running on a MIPS laptop from 1991, logged in as the guest user `demo`.
---
## Origins

**Sony NEWS** — the name stands for *Network Engineering WorkStation* — was Sony's line of Unix workstations, launched in 1987 when the first model, the NWS-800, was pitched as a desk replacement for a VAX minicomputer, and sold mostly inside Japan. It was Sony's bid for the same engineering and research market Sun Microsystems was winning in the United States: a real Unix machine, on the engineer's desk, at a price a university lab could justify. The first NEWS machines ran on Motorola 68020/68030 processors; by the early 1990s the line had moved to MIPS, and later still to faster MIPS parts, from the R4000 class up to a 200-megahertz R10000 in the line's final models.

The operating system, **NEWS-OS**, was a 4.3BSD-derived Unix with Sony's additions on top — an X11 server, the **NEWS Desk** windowing environment, and thorough support for Japanese text (the machines were built for a Japanese-language market that most American workstations served only as an afterthought). Release 4.1R, running on this station, is the mature 4.3BSD generation, with X11R4 and the `sxdm` graphical login.

The machine underneath is a **Sony NWS-3260** (1991) — the *portable* of the MIPS generation. Where most workstations of the era were deskside boxes tethered to a heavy CRT, the 3260 folded a **20 MHz MIPS R3000**, 16 MB of RAM and a **1120×780 monochrome LCD** into a luggable, laptop-shaped case. It is, in effect, a BSD Unix laptop from 1991 — years before that phrase meant anything ordinary.

## Significance

Almost every Unix workstation in this hall is an American machine: Sun's Solaris, SGI's IRIX, DEC's Tru64, HP's HP-UX. NEWS is the one that came from the other side of the Pacific — Japan's own answer to the workstation, from a company far better known for the Walkman and the Trinitron than for `/etc/passwd`. Seeing NEWS-OS next to its American cousins is seeing that the BSD-Unix-on-a-workstation idea was genuinely global, and that Sony, at the height of its hardware confidence, built a credible one. The hall's Sun machine runs the same idea one Berkeley release older: its SunOS 4.1.4 is built on 4.2BSD, the last of Sun's BSD Unixes, while NEWS-OS's 4.3BSD base is the next generation of that same lineage.

And there is a twist of games history buried here. **Early Sony PlayStation development kits were built on NEWS hardware** — the machines that produced one of the best-selling consoles ever made were NEWS Unix workstations with PlayStation graphics hardware bolted on. Nintendo, too, developed its first Super NES titles on Sony NEWS machines. Before Sony made game consoles, it made the workstations the game industry designed them on.

And it is the only *portable* Unix workstation here. The 1120×780 monochrome panel is no downgrade — it is the real hardware: a high-resolution flat panel at a time when flat panels were exotic, driving a full X11 desktop. This is what a mobile engineer's Unix machine looked like in 1991, and there was almost nothing else like it. The panel's 1120-pixel horizon is shared, unbidden, by the NeXTcube's greyscale monitor in this same hall — the same 1120-pixel width, and the NEWS panel gives up just 52 lines to it.

## What you're looking at

NEWS-OS 4.1R booted from its own disk on an emulated NWS-3260, drawn on the machine's 1120×780 monochrome LCD, logged in as the unprivileged guest user **`demo`**. The environment is **NEWS Desk** (`sxsession`): Sony's own X11 desktop, with a menu bar of Session / Environment / Application and a set of bundled tools. Three of them are open here — **sxbitmap**, a 48×48 bitmap editor; a **file manager** browsing the Unix filesystem under `/usr`; and **sxedit**, a small text editor. Underneath the desktop is an ordinary 4.3BSD system: a real shell, real manual pages, TCP/IP and NFS, all reachable from an `xterm`.

Because there is no colour here, the whole interface is rendered in crisp black-and-white dithering — the native look of the LCD.

## Things to try

- **Log in as `demo`** at the `sxdm` greeter (no password) to reach the NEWS Desk desktop. There is no autologin on this machine, so the first login is by hand — as it would have been in 1991.
- **Open the Application menu** on the desktop's menu bar for Sony's bundled tools — a **Terminal Emulator** (`xterm`) for a Bourne/C-shell prompt, the **sxbitmap** editor, **sxedit**, and the **file manager**.
- **In an xterm, poke at a 1991 BSD**: `ls /`, `ps ax`, `df`, `w`, `cat /etc/motd`, `man ls` (the manual pages are installed). The C shell (`csh`) is the login shell; `/usr/ucb` holds the Berkeley classics.
- **Browse the filesystem** in the file manager — walk into `/usr`, `/bin`, `/usr/games` — the same directories you can `ls` in the shell, shown as folders and icons.
- **Reset** power-cycles the machine — a cold boot from the ROM monitor back to the `sxdm` login, about a minute and a half, the way a real NWS-3260 would start its day.

Note for the curious: the NEWS Desk menus open by press-and-hold rather than a single click.

## Legacy

Sony kept the NEWS line going into the late 1990s — its later NEWS-OS releases had moved to a System V R4 base as early as 1992 — but the workstation market it was built for was narrowing around Sun and SGI, and then collapsing as commodity PCs running Windows NT and, soon, Linux took over the engineer's desk. By the time the line was wound down, Sony's consumer PCs — the VAIO line, begun in 1995 — had already absorbed the computing ambition the workstations once carried. The NEWS workstations became one of the great might-have-beens of Japanese computing — technically strong, genuinely original, and almost unknown outside the labs that used them. This station is a rare chance to see one run.

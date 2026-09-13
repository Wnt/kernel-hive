---
title: Minix 2.0.4
subtitle: 1997 · the teaching Unix Linux was written on — and argued with
hero: /posters/minix2/desktop.webp
images:
  - src: /posters/minix2/desktop.webp
    alt: A Minix 2.0.4 text console, white on black — the uname line "Minix minix 2 0.4 i686", a two-line listing of /usr/src (LICENSE, Makefile, boot, commands, etc, fs, inet, kernel, lib, mm, tmp, tools) and a root shell prompt
    caption: The whole exhibit in one screen: /usr/src, the complete source of the operating system you are logged into, at a root prompt on an 80x25 console.
---
## Origins

In 1979, AT&T changed the licence on Unix. Version 7 could still be bought, but the new terms forbade discussing the source code in a classroom — and the source code was the whole reason anyone taught Unix in the first place. **Andrew S. Tanenbaum**, a professor at the Vrije Universiteit in Amsterdam, had been teaching from John Lions' famous commentary on the Version 6 kernel. The licence took his course material away.

So he wrote a replacement. **Minix** — *mini-Unix* — was built from nothing over three years, deliberately system-call compatible with Version 7 and deliberately small enough that a student could read all of it in a term. It ran on an IBM PC with two floppy drives and no hard disk, and it arrived in 1987 as the appendix of a textbook, *Operating Systems: Design and Implementation*, with the source listing printed at the back and the disks sold separately by the publisher.

The design was the argument. Where Unix put the file system, the memory manager and every device driver inside one kernel, Minix put them **outside it**, as ordinary user processes that talk to each other by passing fixed-size messages. The kernel underneath handles interrupts, scheduling and the message plumbing, and almost nothing else. A disk driver that crashes in Minix is a process that died, not a machine that stopped. This is a **microkernel**, and in 1987 it was a minority position held with some force.

Minix found an audience far beyond the course it was written for. The Usenet group **comp.os.minix** ran to tens of thousands of readers, and it is where, on **25 August 1991**, a student in Helsinki posted: *"Hello everybody out there using minix — I'm doing a (free) operating system (just a hobby, won't be big and professional like gnu)."* **Linus Torvalds** had bought a 386, installed Minix on it, found it too limited for what the hardware could do, and written his own kernel using Minix as the development host — down to borrowing its file system layout so the two could share a disk.

## Significance

What happened next is the most-quoted argument in the history of operating systems. On **29 January 1992**, on the same newsgroup, Tanenbaum opened a thread titled **"LINUX is obsolete"**: monolithic kernels were a step back into the 1970s, tying a design to the 386 was a mistake, and a microkernel was simply the better engineering. Torvalds answered — sharply, at length, in public, aged 22. The thread ran for weeks and pulled in half the group.

Both of them turned out to be right about different things. Linux won the argument it was actually having: a monolithic kernel that ran well on the hardware people owned, developed by anyone who sent a patch, under a licence that let them. Minix could not compete on that ground, because Tanenbaum was keeping it small **on purpose** — a system you can read is a system you cannot let grow, and the flood of patches from comp.os.minix was mostly declined. By the time Minix was relicensed under BSD terms in **April 2000**, the thing that needed a free Unix-like kernel had had one for eight years.

But the design argument aged the other way. Microkernels are now what runs underneath the things that must not crash: QNX in cars, L4 in phone basebands, seL4 with a machine-checked proof of correctness. Tanenbaum's own **Minix 3** went on to be adopted as the firmware operating system inside Intel's Management Engine, which means a descendant of this teaching system boots, unseen, on a very large fraction of the world's x86 computers.

## What you're looking at

**Minix 2.0.4** — the last of the 2.0 line, released in November 2003, on the tree that shipped in 1997 as the second edition of the textbook, co-authored with **Albert S. Woodhull**. Minix 2 is the POSIX-conformant rewrite: signals, terminals and the system-call interface brought into line with the standard, still in the same readable shape.

The machine is a period PC — a 32 MB i440fx box with an IDE disk and a standard VGA text console, no mouse and no network. You arrive at a root shell, and the exhibit is one directory: **`/usr/src`**. The entire operating system is there — `kernel/`, `mm/` (the memory manager), `fs/` (the file system), `inet/` (the network server, itself just another user process), `lib/`, `tools/`, and `commands/` — the source to every program in the distribution — and you can read it with the tools that are in it. Try `ls /usr/src/kernel`, then `proc.c`, which is the file where the message passing lives: `mini_send`, `mini_rec`, the whole of the idea in a few hundred lines.

There is no pointer here and nothing to click. That is not a limitation of the exhibit; it is what the system is. Minix was made to be *read*, and this is the screen a first-year student sat in front of in 1997 to find out what an operating system actually is.

## Legacy

Two stations along this hall are the other half of this story: **Slackware 3.4**, from the same year, and **Debian 2.2** — the Linux that the argument on comp.os.minix was about, grown up and shipping. Next to them, Minix looks like the road not taken. It is better understood as the road that was never trying to go there. Minix's job was to be understood completely by one person in one semester, and it has held that job for four decades, through three editions of the book and into Minix 3.

It is worth remembering that the most consequential thing Minix ever did, it did by being available. A student in Finland needed a Unix he could run at home on a 386, and there was exactly one.

## Sources

- Andrew S. Tanenbaum, *Operating Systems: Design and Implementation*, 1st ed. (1987) and 2nd ed. with Albert S. Woodhull (1997) — Minix 1 and Minix 2 respectively.
- Linus Torvalds, comp.os.minix, 25 August 1991 — the "just a hobby" announcement.
- "LINUX is obsolete", comp.os.minix thread begun 29 January 1992; reprinted as Appendix A of *Open Sources: Voices from the Open Source Revolution* (O'Reilly, 1999).
- <https://minix1.woodhull.com/> — Al Woodhull's Minix 2 archive: 2.0.3 (May 2001), 2.0.4 (November 2003), and the installation notes this station's guest was built from.
- <https://en.wikipedia.org/wiki/Minix> — release chronology and the April 2000 BSD relicensing.

---
title: Linux 0.12
subtitle: 1992 · the release that added virtual memory — and the GPL
hero: /posters/linux012/desktop.webp
images:
  - src: /posters/linux012/desktop.webp
    alt: A Linux 0.12 text console, white on black — the kernel boot banner reading "8 virtual consoles", "4 pty's", "Partition tables ok.", "Swap device ok: 1023 pages (4190208 bytes) swap-space", "6/1440 free blocks", "Free mem: 12582912 bytes", then "Ok." and a root prompt "[/usr/root]#" where cat /etc/passwd has printed eight account lines
    caption: Eleven lines of kernel boot output and the password file of a machine with no passwords. Every line on this screen is something the 0.12 release notes announced as new.
---
## Origins

In August 1991 a student in Helsinki posted to **comp.os.minix** that he was writing a free operating system — *"just a hobby, won't be big and professional like gnu"*. The first tarball, **0.01**, went up the following month; it could not even be run by most of the people who downloaded it. **0.02** could. **0.11**, in December, was the first release that a stranger could realistically boot on their own 386.

**0.12** came four months after the announcement, in **January 1992** — the information sheet that shipped with it is dated the 13th. It is the fourth public version of Linux, and by a wide margin the most consequential of the early ones.

Two things happened in it.

The first is in the release notes, in a section headed **COPYRIGHT**, before any of the technical news:

> *The Linux copyright will change: I've had a couple of requests to make it compatible with the GNU copyleft, removing the "you may not distribute it for money" condition. I agree. [...] Otherwise The GNU copyleft takes effect as of the first of February.*

Linux 0.01 through 0.11 had been released under a licence Torvalds wrote himself, and it forbade charging money. That clause would have kept Linux off every shelf and out of every distribution business that later carried it. **0.12 is the release where it goes away.** Everything commercial that Linux became — Slackware, Red Hat, Debian's vendors, Android, the machines this museum runs on — depends on a paragraph in this version's release notes.

The second is further down the same file, under **Virtual memory**:

> *NOTE! This has been tested by Robert Blum, who has a 2M machine, and it allows you to run gcc without much memory. HOWEVER, I had to stop using it, as my diskspace was eaten up by the beta-gcc-2.0 [...] I've been totally unable to make a swap-partition for even rudimentary testing since about christmastime. Thus the new changes could possibly just have backfired on the VM, but I doubt it.*

Linux 0.12 is the first Linux that can **swap to disk**. It is also, on the author's own admission, a release whose headline feature he had not been able to test for a month, because he had run out of disk space compiling a beta compiler. It shipped anyway.

## Significance

Demand paging is what turned Linux from a demonstration into something people could use. A 386 with **2 MB** of RAM was an ordinary machine in 1992 and a 4 MB machine was a good one; GNU's compiler did not comfortably fit in either. With a swap partition it did. The whole free-software toolchain that Linux needed in order to build itself became runnable on hardware students actually owned, and 0.12's own notes say exactly that: *it allows you to run gcc without much memory.*

The rest of the release reads like a list of the things a Unix has to have before anyone will take it seriously, arriving all at once and mostly from other people. **Job control** — `bg`, `fg`, `jobs` — contributed by Ted Ts'o. **Virtual consoles**, **pty's** and **`select`** from Peter MacDonald. **Symbolic links**. **387 emulation**, so a machine with no maths coprocessor could still run compiled floating-point code. **Super-VGA detection**, so the console could be 100x40 instead of a cramped 80x25. Four months in, Linux had stopped being one person's hobby kernel and become a project taking patches.

And it was version 0.12 that was on screen in **January 1992** when Andrew Tanenbaum opened a thread on comp.os.minix titled *"LINUX is obsolete"* — the argument the **Minix 2** station along this hall tells from the other side. The obsolete system in question was three weeks old and had just grown virtual memory.

## What you're looking at

A 386 with 16 MB of RAM, a VGA text console, an IDE disk and nothing else — no mouse, no network card, because **Linux 0.12 has drivers for neither**. There is no mouse support in this kernel at all, and no networking of any kind: the first Linux with a TCP/IP stack was 0.96b, still half a year away. What you can do here you do with a keyboard, which is the whole of what anyone could do with it in 1992.

Almost every line of the boot banner above the prompt is a 0.12 release note:

- **`Loading.......................`** — *"Linux now prints cute dots when loading"*, the first item in the release notes, contributed by Drew Eckhardt.
- **`Press <RETURN> to see SVGA-modes available`** — the new Super-VGA text-mode detection. A cold start stops here and waits for a key, as it did on a real machine.
- **`8 virtual consoles`** and **`4 pty's`** — new in this release.
- **`Swap device ok: 1023 pages (4190208 bytes) swap-space`** — virtual memory, live. This exhibit has a real swap partition, so 0.12's headline feature is running rather than merely present.
- **`6/1440 free blocks`** — the root filesystem is the original 1.44 MB root floppy from the 0.12 distribution, and it is as full as it was then. You can read everything on it; you cannot write much.

The shell is **bash**, the editor is **vi**, and `/usr/bin` holds about two dozen GNU utilities. Root has no password, which the exhibit demonstrates by leaving `cat /etc/passwd` on screen: the second field of every line is empty. In January 1992 that was not a lapse — a single-user 386 under a desk had nobody to keep out.

One detail of the machine is worth knowing, because it is the guest's own documented mechanism rather than a modern liberty. The root filesystem here lives on a **hard-disk partition** instead of a second floppy. That is step 7 of Linus's own install procedure: *"Change the bootdisk to understand which partition it should use as a root filesystem. [...] it's still the word at offset 508 into the image."* This station's builder writes that word, exactly as `rdev` did. The swap partition is enabled by the word at **offset 506**, which the release notes describe two paragraphs later — and which the 1992 boot image already had set, pointing hopefully at a disk nobody had attached until now.

## Legacy

Version 1.0 arrived in March 1994, two years and roughly a hundred releases later. By then Linux had networking, X, and distributions with names. None of that was possible under the 0.11 licence, and little of it was practical without swap.

It is a small file — a kernel that fits on one floppy with room to spare, and a userland on another. But the two decisions inside it, one legal and one about memory management, are why there is a fleet of machines in this museum and not a footnote.

## Sources

- `RELNOTES-0.12`, January 1992 — the copyright change, the feature list, the offsets 506 and 508, and the untested-swap confession. Shipped with the release and mirrored at <https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/Linux-0.12/docs/>.
- `INFO-SHEET-0.12`, last updated 13 January 1992 — *"LINUX 0.12 is a freely distributable UNIX clone"*, the feature summary and the 386-only statement.
- The guest media: `bootimage-0.12-20040306` and `rootimage-0.12-20040306`, the oldlinux.org repackaged raw floppy images of the original 0.12 distribution.
- Linus Torvalds, comp.os.minix, 25 August 1991 — the "just a hobby" announcement.
- "LINUX is obsolete", comp.os.minix thread begun 29 January 1992 — told from the other side on this museum's **Minix 2.0.4** poster.

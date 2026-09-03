---
title: FreeBSD 4.11
subtitle: 2005 · the last release of the 4.x line, with the KDE 3.3.2 desktop from the release CD
hero: /posters/freebsd411/desktop.webp
images:
  - src: /posters/freebsd411/desktop.webp
    alt: The FreeBSD 4.11 KDE 3.3.2 desktop at 1024 by 768 — a blue-grey gradient background, the Kicker panel along the bottom with the K menu, home, Konqueror, help and Konsole icons and a clock, and a Konsole window open with a root shell prompt reading freebsd411#.
    caption: The desktop as the exhibit boots into it, taken from the golden checkpoint. The machine logs in as root by itself and starts KDE 3.3.2; the Konsole is where the type-in demo lands.
---
## Origins

FreeBSD 4.0 shipped in March 2000, and the 4.x line that followed it became the release series the project is still, in some circles, remembered for. It was the FreeBSD of the first commercial web: **Yahoo!** ran its front-end fleet on it and employed FreeBSD developers to keep it that way, **Hotmail** was running on FreeBSD when Microsoft bought it in 1997 and stayed there for several years afterwards, and a great many ISPs, web hosts and news servers of the period were FreeBSD boxes because the network stack was fast, the system was free, and a single machine would stay up for a year.

**FreeBSD 5.0** arrived in January 2003 carrying **SMPng**, a rewrite of the kernel's locking so that it could run on multiprocessor machines without the single giant lock 4.x used. It was the right rewrite and it took years to settle; the project itself told production users to stay on **4-STABLE** while 5.x matured, and it kept cutting 4.x point releases the whole time. **4.11-RELEASE**, in January 2005, was the last of them — the project supported it into early 2007, two years after 5.x had become the recommended branch. This exhibit runs that final 4.x, installed from the official `disc1-kde` CD, which carried the base system, **XFree86 4.3.0** and the complete **KDE 3.3.2** desktop on a single disc.

## Significance

4.11 is the end of a particular way of building a Unix. The 4.x kernel was a direct descendant of the 4.4BSD-Lite code that FreeBSD started from in 1994: one big lock, a monolithic kernel, and a userland whose `/usr/src` you could read in a week. Everything that made the 5.x and 6.x series modern — fine-grained locking, the GEOM storage layer, a new threading library — also made them harder to hold in one head. Sites that ran 4.x kept running it long past its support date for that reason.

The desktop on top of it is the other half of the story. **KDE 3**, which reached 3.3 in the summer of 2004, was the first time a free Unix could offer a desktop that was genuinely complete: a panel and a menu, a file manager that was also a web browser (**Konqueror**, whose KHTML engine Apple had forked for Safari the year before), a terminal, a text editor, a calculator, a full set of games, and a consistent look across all of it. On a FreeBSD box the whole desktop came from the ports collection, and the `disc1-kde` disc existed precisely so that a user could get from a blank disk to that desktop with a single CD. The X server underneath is **XFree86 4.3.0**, released in early 2003 — the last major XFree86 release before the licence change that sent nearly every distribution to the X.Org fork.

## What you're looking at

A single-processor i386 PC with 256 MB of RAM, a standard VGA card driven by XFree86 4.4.0's `vesa` driver at 1024 by 768 in 16-bit colour, a SCSI hard disk on an LSI controller, a PS/2 keyboard and mouse, and an NE2000-compatible network card. The machine boots straight into a root KDE 3.3.2 session: the **Kicker** panel runs along the bottom with the **K** menu at its left, and a **Konsole** window is already open with a root shell.

Type into the Konsole — `uname -a` names the kernel and its build date, `ls /usr/local/bin` shows how much of the installed system came from ports. The K menu holds **Konqueror** (which will show you the local filesystem, and the documentation under `/usr/local/share/doc`), **Kate**, **KCalc**, and the kdegames set. The pointer is absolute: the exhibit moves the cursor by asking the guest's own X server to warp it, so it lands where you point.

The disk is restored to its checkpoint when the exhibit resets, so anything you write in Kate belongs to your visit.

## Legacy

The BSD family is present in this hall four times over: `netbsd14` and `openbsd` are the sibling systems that split from the same 4.4BSD-Lite roots, and `pcbsd` is FreeBSD 6.3 with the next KDE, from the era after SMPng had finally paid off. This station is the one that shows the line in between — the 4.x kernel that carried the early commercial web, and the moment a free Unix first came with a whole desktop on the install CD.

# Exhibit draft — Linux 0.12

> Prep branch: `linux012` · tracking issue: #54  
> Intended destination: `registry/posters/linux012.md`.

---
title: Linux 0.12 — before Linux became a distribution
subtitle: January 1992 · i386 PC · two floppies, a shell and a young kernel
hero: /posters/linux012/desktop.webp
images:
  - src: /posters/linux012/desktop.webp
    alt: A black VGA text console running Linux 0.12 with a root shell prompt and early Unix commands visible
    caption: Linux before installers, package managers and desktops: boot the kernel, mount the root floppy, and there is a Unix-like system on a 386.
---

## Origins

Linux began in 1991 as Linus Torvalds' attempt to build a small Unix-like kernel for his own 386 PC. The early releases were not distributions in the modern sense. A kernel image and a separate root filesystem were enough to turn commodity PC hardware into a usable system.

**Linux 0.12**, released in early 1992, sits at the point where the experiment is already recognizable as Linux but has not yet acquired the enormous surrounding ecosystem people now associate with the name.

That makes it particularly useful beside Kernel Hive's **Minix** exhibit. Minix was the educational Unix-like system Torvalds used and discussed while beginning Linux; the famous design arguments about kernels and portability make much more sense when both systems are actual machines rather than quotations.

## Significance

The striking thing about early Linux is not what it contains. It is what is missing.

There is no distribution installer, no GNOME or KDE, no systemd, no graphical package manager, and no expectation that the machine will discover its hardware. The system is a kernel, a small Unix userland and a filesystem arranged by hand.

Yet the essentials are already there: processes, files, terminals, a shell, permissions and the familiar Unix directory tree. A visitor who has used a modern Linux machine can type `ls`, `ps` or `cat` and recognize the family immediately.

The exhibit therefore shows continuity better than a version timeline can. The Linux world changed almost beyond recognition while the basic user-space vocabulary survived.

## What you're looking at

The intended station boots Linux 0.12 from its historical **boot floppy** and mounts a separate **root floppy**. The resting scene should be a logged-in shell showing the kernel version and a small directory listing.

This is deliberately a text-only exhibit. Adding a later graphical environment would hide the point: Linux at this moment is interesting precisely because the kernel and shell are almost the whole story.

The final paragraph should record the chosen QEMU machine/CPU, RAM and exact image set after the smoke boot is fixed.

## Legacy

Within a few years Linux acquired networking, loadable modules, mature filesystems, package-managed distributions and graphical desktops. Kernel Hive already shows that later story through Slackware, Red Hat, Debian, SuSE, Ubuntu and modern descendants.

Linux 0.12 is the opposite end of that shelf: the system before the ecosystem.

## Sources

- Old Linux image mirror: https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/Linux-0.12/images/
- OldLinux archive: https://oldlinux.org/
- Kernel Hive candidate survey: `docs/catalog/candidates-pre2010-survey.md`

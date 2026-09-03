---
title: Red Hat Linux 6.2
subtitle: 2000 · Red Hat's 'Zoot' release — GNOME 1.0 on kernel 2.2
hero: /posters/redhat62/desktop.webp
images:
  - src: /posters/redhat62/desktop.webp
    alt: Red Hat Linux 6.2 GNOME 1.0 desktop under Enlightenment at 1024x768 — the GNOME panel along the bottom with the foot menu, the pager and a clock, and the GNOME Midnight Commander file manager on the desktop
    caption: GNOME 1.0.55 under the Enlightenment window manager, the default desktop Red Hat Linux 6.2 installed in April 2000.
---
## Origins

Red Hat Linux 6.2, codenamed Zoot, was released in April 2000. It is built on Linux kernel 2.2.14, glibc 2.1.3 and XFree86 3.3.6, and it ships two desktop environments: GNOME 1.0.55 with Enlightenment 0.16 as its window manager, which the installer selects by default, and KDE 1.1.2. Netscape Communicator 4.72 is the web browser. Packages are managed with RPM 3.0.4, the format Red Hat had introduced with its own early releases and which other distributions had by then adopted.

The installer is anaconda, which had made its first appearance one release earlier in 6.1 as Red Hat's first graphical installer. It also runs in text mode and from a kickstart file, an unattended-install mechanism that this exhibit itself was built with.

Red Hat had gone public in August 1999, eight months before Zoot. The company's flotation, and VA Linux's in December of the same year, were the point at which a distribution made by a small North Carolina company became a stock-market story; 6.2 is the first release Red Hat shipped as a public company with the attention that brought.

## Significance

Red Hat Linux 6.2 is a snapshot of the Linux desktop at the moment it became a boxed product sold in shops. GNOME 1.0 had been declared in March 1999 and was still visibly young: the panel, the foot menu and the gmc file manager owe as much to Enlightenment's themes as to any GNOME design, and applications used a mix of GTK+ 1.2 and older Motif and Athena toolkits. KDE 1.1.2 on the same disc represents the rival project, then still under a licensing cloud because of the Qt toolkit.

6.2 was also the last of the 6.x line. Red Hat Linux 7.0, in September 2000, moved to glibc 2.2 and a prerelease gcc 2.96 compiler, a combination that broke binary compatibility with 6.x and drew criticism from other distributions and from upstream GCC developers. That made Zoot the release many installations stayed on for a long time, and the one later remembered as the stable end of the 2.2-kernel era.

## What you're looking at

A GNOME 1.0 desktop under Enlightenment, at 1024x768, logged in as an unprivileged user. The GNOME panel with its foot menu, gnome-terminal, the gmc file manager, Netscape Communicator 4.72 and the GIMP are available. The system was installed unattended from a kickstart file and runs under QEMU/KVM on an emulated Cirrus Logic GD5446 graphics card with a PS/2 mouse.

## Legacy

Red Hat Linux continued through version 9 in 2003, after which Red Hat split the line into the community-run Fedora and the subscription product Red Hat Enterprise Linux. GNOME went on to a full redesign in GNOME 2 in 2002; Enlightenment left the GNOME project's orbit and continued on its own. The kickstart installer, RPM and anaconda that built this exhibit are all still in use in Fedora and RHEL today, which makes 6.2 one of the earlier systems in this hall whose tooling a present-day administrator would recognize.

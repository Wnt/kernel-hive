# Exhibit draft — 4.3BSD on a VAX-11/780

> Prep branch: `vax43bsd` · tracking issue: #56  
> Intended destination: `registry/posters/vax43bsd.md`.

---
title: 4.3BSD on the VAX — Berkeley Unix on the machine that defined an era
subtitle: 1986 · DEC VAX-11/780 · sockets, TCP/IP and university Unix
hero: /posters/vax43bsd/desktop.webp
images:
  - src: /posters/vax43bsd/desktop.webp
    alt: A terminal logged into 4.3BSD on a VAX with a Unix shell prompt, system identification and networking commands visible
    caption: Berkeley Unix on a VAX: the environment in which sockets and the BSD TCP/IP stack became part of everyday Unix programming.
---

## Origins

The **VAX-11/780**, introduced by Digital Equipment Corporation in 1977, became one of the defining 32-bit minicomputers of the following decade. It was large enough to serve departments and laboratories but far more accessible than a mainframe, and universities filled them with Unix.

At the University of California, Berkeley, Unix evolved into the **Berkeley Software Distribution**. The VAX gave that work a natural home. Virtual memory, a large address space and a growing academic network turned BSD from a collection of Unix additions into a system with its own technical identity.

**4.3BSD**, released in 1986, represents the mature classic form of that VAX-era Berkeley Unix.

## Significance

A modern programmer can sit at this terminal and recognize an astonishing amount.

The BSD networking work helped make **TCP/IP** a normal part of Unix. The **sockets** interface became the programming model generations of network software would use. Tools, shells, editors and the filesystem layout spread through universities and into commercial Unix systems.

The exhibit also fills a historical gap between two existing parts of Kernel Hive. The PDP-11 station shows Unix on the smaller machine where the system grew up. SunOS, Ultrix-like descendants and later workstations show Unix after networking and graphics became expected. The VAX is the missing middle: large academic Unix at the moment networking becomes foundational.

## What you're looking at

The intended station is a simulated **VAX-11/780** running 4.3BSD, presented through a period-appropriate terminal session.

A useful resting scene is a shell after login with `uname` and a directory listing visible. Networking commands such as `netstat` or a small socket demonstration can be one command away if the simulated Ethernet path is worth enabling.

This should remain a terminal exhibit. A graphical desktop would belong to a different chapter of the VAX story.

The final paragraph should name the exact SIMH CPU, memory, disk controller and preserved image after the build path is fixed.

## Legacy

BSD's descendants are still active operating systems, but the larger legacy is everywhere: networking APIs, command-line tools, filesystem conventions and code that crossed into commercial Unix and later open-source systems.

The VAX itself faded. The software culture built around it did not.

## Sources

- SIMH 4.3BSD install notes: https://gunkies.org/wiki/Installing_4.3_BSD_on_SIMH
- Kernel Hive candidate survey: `docs/catalog/candidates-pre2010-survey.md`

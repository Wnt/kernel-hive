# Exhibit draft — Multics

> Prep branch: `multics` · tracking issue: #51  
> Intended destination: `registry/posters/multics.md`.  
> Exact simulator/model facts stay out of the visitor prose until the DPS8M configuration is fixed.

---
title: Multics — the computer as a utility
subtitle: 1965–2000 · MIT / GE / Honeywell · time-sharing before Unix
hero: /posters/multics/desktop.webp
images:
  - src: /posters/multics/desktop.webp
    alt: A text terminal logged into Multics, showing a command prompt and directory output from the shared timesharing system
    caption: Multics was designed as a shared computing utility: many users, one continuously available system, each seeing a protected world of programs and files.
---

## Origins

**Multics — Multiplexed Information and Computing Service —** began in 1965 as a joint project of MIT's Project MAC, General Electric and Bell Laboratories. The ambition was larger than building another batch operating system. Its designers described a **computer utility**: a large shared system available continuously, serving many users with different workloads in the way a utility serves many customers.

That required ideas that were still novel. Multics combined paging and segmentation, a hierarchical file system, dynamic linking, strong protection boundaries and interactive time-sharing on hardware designed with those goals in mind.

Bell Labs left the project in 1969. GE sold its computer business to Honeywell in 1970. Multics nevertheless became a commercial system and continued running at customer sites for decades; the last production site shut down in 2000.

## Significance

Multics matters partly because of what it built and partly because of what people did after working on it.

Ken Thompson and Dennis Ritchie had seen the Multics project at Bell Labs. Unix was famously smaller, simpler and designed for much cheaper hardware, but it inherited the context: interactive time-sharing, hierarchical files, commands as composable tools, and the assumption that one machine could serve multiple users at once.

Multics also pursued protection and system structure much further than early Unix. Its segmented address spaces, ring-based protection model and pervasive dynamic linking made it a laboratory for ideas operating systems would keep rediscovering.

The easiest mistake is to look at the text terminal and conclude that the system is primitive. The terminal is simple because the **computer is elsewhere**. The complexity is in the shared service behind it.

## What you're looking at

The intended exhibit is a restored Multics MR12.x environment running under the DPS8M simulator. The visitor sees a normal terminal session connected to that system, not the simulator's operator console.

A useful scene is a clean login or command-processor prompt. From there, simple commands can show the user's directory tree, active users and the system's help environment. The interaction should feel like joining a running institutional computer rather than booting a personal machine.

The final poster should name the exact simulated processor configuration and chosen QuickStart image after integration.

## Legacy

Multics did not win the mass market. The machines were large and expensive, and Unix became the portable system that spread through universities and industry.

But “winning” is the wrong measure for a research system whose ideas kept reappearing. Hierarchical storage, memory protection, shared services, dynamic linking and security rings all became ordinary vocabulary elsewhere.

This exhibit belongs before Unix in the museum's story not because Unix copied Multics wholesale, but because Unix makes more sense after you have seen the large system it was reacting to.

## Sources

- Multics history: https://multicians.org/history.html
- Corbató, Saltzer & Clingen, “Multics — The First Seven Years”: https://www.mit.edu/~Saltzer/publications/f7y/f7y.html
- Simulator overview: https://multicians.org/simulator.html

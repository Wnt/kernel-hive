# Exhibit draft — MIT ITS on the PDP-10

> Prep branch: `its` · tracking issue: #61  
> Intended destination: `registry/posters/its.md`.  
> If TOPS-20 wins the implementation race instead, keep this branch as the ITS-specific candidate and create a separate TOPS-20 poster rather than blending the two systems.

---
title: MIT ITS — the hackers' timesharing system
subtitle: 1960s–1980s · PDP-10 · DDT, Emacs, Maclisp and a machine built to be explored
hero: /posters/its/desktop.webp
images:
  - src: /posters/its/desktop.webp
    alt: A terminal connected to MIT ITS on a PDP-10, showing the DDT command environment or an early Emacs session
    caption: ITS was a shared research computer whose users treated the operating system itself as something to inspect, patch and extend.
---

## Origins

The **Incompatible Timesharing System**, ITS, was created at MIT's Artificial Intelligence Laboratory in the late 1960s for the PDP-6 and PDP-10 family.

The name was a joke aimed at MIT's earlier **Compatible Time-Sharing System**, but the software reflected a serious difference in culture. ITS was built by and for a community of researchers who expected to understand the whole machine. System internals were visible, conventions were informal, and the computer was less a sealed service than a shared laboratory.

MIT's original ITS site eventually shut down in 1990. The source and software culture survived, and modern reconstruction projects can build the system again from its historical sources.

## Significance

A remarkable list of software grew up on ITS: early **Emacs**, Maclisp, Scheme-related work, Macsyma, Zork and other programs that escaped the machine and influenced computing elsewhere.

The operating environment also embodies the original meaning of **hacker** as a skilled, playful systems programmer. Users were expected to poke at the system, share tools and improve the environment they all inhabited.

That makes ITS a useful contrast with both Multics and MVS. All three are shared large-computer systems, but their personalities are different. MVS feels institutional. Multics feels architectural. ITS feels like a workshop whose users never stopped modifying the benches.

## What you're looking at

The intended station is ITS running on an emulated **PDP-10**, with the visitor attached through a clean terminal rather than the emulator console.

A good resting scene is the DDT command environment or an early Emacs session. The first guided interaction should be something culturally specific — start Emacs, inspect a file, or run one of the classic programs that made ITS famous.

The system's unfamiliar control characters are part of the experience but should not become a usability trap; the gallery can expose a few labeled key actions without modernizing the terminal itself.

The final paragraph should name KLH10 versus SIMH, the exact CPU model and disk image after the build is fixed.

## Legacy

ITS never became a commercial operating system. Its influence travelled through people and software instead.

Emacs became one of computing's longest-lived editors. Lisp systems, interactive debuggers and the hacker culture around ARPANET spread beyond MIT. The system's permissive, exploratory environment became part of the mythology and practice of early networked computing.

Running ITS today is therefore less like recovering a product and more like reopening a workshop.

## Sources

- Maintained ITS reconstruction/build project: https://github.com/PDP-10/its
- ITS project summary and historical features: https://github.com/PDP-10/its
- Contemporary Emacs-history material preserved in the ITS tree: https://github.com/PDP-10/its/blob/master/doc/eak/emacs.lore

---
title: SerenityOS
subtitle: 2018 · From-scratch Unix-like
hero: /posters/serenityos/desktop.webp
images:
  - src: /posters/serenityos/desktop.webp
    alt: SerenityOS desktop with its late-1990s-inspired interface
    caption: SerenityOS joins a from-scratch kernel and userland to a deliberately familiar desktop.
---
## Origins

SerenityOS began in 2018 as Andreas Kling’s personal recovery project: building an operating system from first principles and documenting the work publicly. Kling, a Swedish programmer who had spent years on Qt and six years at Apple working on WebKit, named it after the Serenity Prayer from the addiction recovery he completed that same year. It grew into a large open-source collaboration with its own kernel, C library, shell, graphical toolkit, window server, filesystems, network stack, development tools, and applications. Although Unix-like in concepts and interfaces, it is not a Linux distribution and does not reuse a conventional Unix userland.

The desktop deliberately recalls the late 1990s. Gray controls, beveled borders, patterned wallpapers, a taskbar, and compact applications evoke Windows 95-era visual density — an era this museum keeps itself, since the Windows 95 tile shows the real taskbar and bevels the look is paying homage to. That familiarity provides a stable surface on which independently implemented subsystems can be tested.

## Significance

SerenityOS made operating-system development unusually observable. Long-form videos and open discussions exposed debugging, design revisions, regressions, and incremental progress rather than presenting only finished releases. The project became both a working system and a substantial body of public technical education.

Its applications ensure that kernel work is driven by real demands. PixelPaint exercises graphics and documents, games exercise timing and input, Terminal exercises processes and pseudo-terminals, and the browser effort forced increasingly capable networking, layout, JavaScript, and standards code. The browser engine later became the separate Ladybird project, illustrating how a subsystem can outgrow its original laboratory.

## What you're looking at

The native LibGUI desktop presents applications such as Terminal, Solitaire, Minesweeper, and PixelPaint.

The nostalgic appearance should not be mistaken for an old binary environment: the code is contemporary and independently written.

## Legacy

SerenityOS has already demonstrated the cultural value of building in public. It offers contributors a coherent system in which components normally treated as fixed infrastructure remain open to redesign. Its visual affection for an earlier desktop era creates continuity, while its from-scratch implementation ensures that continuity is interpretive rather than imitative.

---
title: ravynOS 0.6.1 "Hyperpop Hyena"
subtitle: 2025 · the last FreeBSD-based ravynOS
hero: /posters/ravynos/desktop.webp
images:
  - src: /posters/ravynos/desktop.webp
    alt: The ravynOS 0.6.1 desktop — a macOS-style global menu bar across the top with a raven glyph at the left and a clock at the right, a photographic wallpaper of a cable-stayed bridge at sunset, and a Dock of three icons along the bottom edge
    caption: ravynOS 0.6.1 after logging in as liveuser — the global menu bar, the wallpaper Dock.app draws behind itself, and a Dock holding Terminal.app, the installer and the Trash. This is the exact frame the exhibit restores to.
---
## Origins

ravynOS began in January 2021 as **airyx**, a one-developer project by **Zoë Knox** with a goal most people would call unreasonable: build a system that looks, feels and — crucially — *compiles* like macOS, on top of a free Unix, without using a single line of Apple's code. Its tagline is "Finesse of macOS. Freedom of Open Source."

The plan was FreeBSD from the waist down and a clean-room Cocoa from the waist up. FreeBSD supplies the kernel, the drivers and a complete Unix userland; on top of it ravynOS assembles its own AppKit, Foundation, CoreGraphics, CoreText and Onyx2D — a stack descended from the Cocotron and GNUstep reimplementations of Apple's frameworks, all of it permissively licensed and written without reference to Apple's sources. The target was never binary compatibility with Mac software but *source-level* compatibility: an application written for macOS should build and run here.

Around that core went the rest of the Mac's shape. A global menu bar. A Dock. Applications that install by dragging a bundle. The macOS folder layout — `/Applications`, `/Library`, `/System`, `/Users`, `/Volumes` — laid over a BSD filesystem. Command-key shortcuts instead of Control. Familiar commands like `open` and `pbcopy` on the path beside FreeBSD's own. The project mascot is a raven, **Muninn**, one of the two who bring Odin the news.

Releases came slowly and steadily. Version 0.5.0 rebased onto FreeBSD 15-CURRENT; 0.6.0 moved to FreeBSD stable/15; **0.6.1 shipped on 25 October 2025**, still labelled a pre-alpha developer preview.

## Significance

Four days later, on 29 October 2025, Knox opened GitHub Discussion #529 — "It's decision time. Please read." — and the project changed course completely. ravynOS would abandon the FreeBSD kernel and restart on Apple's own open-sourced **Darwin/XNU** kernel instead.

Then the FreeBSD-era releases were withdrawn. Every build from v0.4.x through v0.6.1 was removed from the project's GitHub releases page and from its SourceForge mirror. They survive only where volunteers happened to keep copies.

That makes the system on this screen a peculiar kind of artefact. **ravynOS 0.6.1 is the last FreeBSD-based ravynOS**, and the Mac-like desktop the project spent four and a half years building exists *only* in the line that was deleted — the current official Darwin/XNU demo VM boots to a console with no graphical environment at all. This hall is full of systems abandoned by their makers; this is one abandoned so recently, and so thoroughly, that the exhibit preserves a build its own project erased.

It is worth being clear about what is being preserved. Not a finished product — a snapshot of an ambitious reimplementation at the exact moment its author decided the foundation was wrong and started again.

## What you're looking at

An x86-64 PC — UEFI firmware, no legacy BIOS, 4 GB of memory, one display — booting ravynOS 0.6.1 to a LoginWindow. The account is `liveuser`, with no password.

What comes up is a global menu bar drawn by SystemUIServer, a Dock along the bottom that also paints the wallpaper behind it, and one application: **Terminal.app v0.9.2**, which the project's own notes describe as "a very basic proof-of-concept". Behind that veneer is the real thing — a complete FreeBSD 15 userland arranged in the macOS folder layout, with `zsh` as the default shell and `vim`, `turbo` and `curl` installed.

Two features you would expect are simply absent: **the Filer file manager and the graphical installer are commented out of the 0.6.x build and do not ship**, and there is no web browser. So the honest description is a convincing shell of a Mac desktop over a BSD, rather than a Mac you could use. Click into the Terminal and you are on FreeBSD; click anywhere else and you are looking at the ambition.

There is no graphics driver of any kind. Since 0.5.1 the WindowServer paints directly into the framebuffer that UEFI hands it — no OpenGL, no kernel mode-setting, one screen, at the 1280×800 this machine came up with. Everything on this display is drawn by CPU into that single buffer. Input arrives over USB, because the PS/2 and virtio paths lag.

If you find the Command key, treat ⌘⇧Q with respect: it quits the WindowServer, and with no Filer to bring it back, the desktop goes with it.

## Legacy

The Darwin-based ravynOS carries on under the same name and the same author, so this is not a project that died — it is a project that threw away its foundation and kept its goal. Whether starting from Apple's real kernel gets there faster than reimplementing everything around FreeBSD's is a question its next few years will answer.

What the FreeBSD line already showed is that the Mac's *interface* is separable from Apple's hardware and Apple's code. A menu bar at the top of the screen, a Dock, bundles you install by dragging, Command instead of Control: none of it required a Mac, and a single developer with a clean-room Cocoa got a recognisable version of all of it running on a commodity PC. NeXTSTEP and Rhapsody stand elsewhere in this hall as the ancestors of the desktop being imitated here; this station is the same idea approached from the opposite direction, thirty years later, by someone with no access to the original.

The exhibit exists because the evidence nearly did not. Four days between a release and the decision that retired it, and a deletion that took the whole FreeBSD era off the project's own servers.

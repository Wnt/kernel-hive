---
title: Genode Sculpt OS
subtitle: 2025 · a microkernel desktop that is its own component graph
hero: /posters/sculpt/desktop.webp
images:
  - src: /posters/sculpt/desktop.webp
    alt: The Genode Sculpt 25.04 Leitzentrale — a dark control-center screen with a node graph fanning out from a "Hardware" box to ps2, vesa fb, usb (usb hid) and ahci nodes, a "Components" tab lit in the top menu bar, and the GENODE wordmark in the corner.
    caption: Sculpt's Leitzentrale. The running system is drawn on screen as a live graph of components — drivers on the right, the runtime below — that you add, wire and inspect as the machine runs.
---
## Origins

Genode is an operating-system framework built by Genode Labs in Dresden since
2008, assembled from small components over a microkernel rather than one large
monolithic kernel. **Sculpt** is Genode's self-hosting desktop distribution:
the first release you could run and develop on directly, refined every quarter.
This is the 25.04 release.

## Significance

Almost every desktop hides the operating system behind an application metaphor —
files, windows, a taskbar. Sculpt does the opposite. Its **Leitzentrale**
("control center") *is* the system, drawn as a graph: each driver, service and
application is a node you can add, connect, sandbox and tear down while the
machine keeps running. Security is structural — a component can only touch what
it was explicitly granted, so the whole architecture is visible and auditable at
a glance. Nothing else in this museum makes the shape of a running OS this
literal.

## What you're looking at

The dark screen with the node graph is the Leitzentrale at rest. From the
**Hardware** box, branches run to the platform drivers Sculpt has started — the
**ps2** input driver, the **vesa fb** framebuffer, **usb** with its **usb hid**
child, and **ahci** for storage — while **Config**, **Info**, **GUI** and
**ram fs** sit below as core services. The top bar (**Settings · Files ·
Components · Network · Log**) switches what the graph shows. Add a component and
a new node appears, wired live into the system you are watching.

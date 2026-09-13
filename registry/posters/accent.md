---
title: Accent — the kernel inside your phone, at the start
subtitle: 1986 · Accent S6 with Spice Lisp (CMU SPICE, on a Three Rivers PERQ 1)
hero: /posters/accent/desktop.webp
images:
  - src: /posters/accent/desktop.webp
    alt: PLACEHOLDER — the Accent S6 window system on a PERQ 1, with a Spice Lisp listener, black on white, on a tall portrait screen
    caption: PLACEHOLDER — Accent S6 and the Spice Lisp environment, on the machine CMU rewrote from the microcode up.
---
## Origins

Carnegie Mellon in 1981 had a problem that was about to become everyone's
problem: a building full of single-user graphical machines, all of which needed
to talk to each other and to the services around them, and an operating-system
tradition — Unix included — that had been designed for one computer with many
users, not many computers with one user each.

**Rick Rashid and George Robertson** answered it with a kernel whose central
idea was not a file and not a process but a **message**. In Accent, a program
does not call the system; it sends a message to a *port*, and the port might be
served by the kernel, by another program on the same machine, or by a program on
a machine across the network — and the sender cannot tell which, and does not
need to. Memory, files, devices and network services all become the same thing:
somebody, somewhere, listening on a port.

They built it for the **PERQ**, the machine on the tile beside this one, as part
of CMU's **SPICE** project — the Scientific Personal Integrated Computing
Environment. The PERQ was the right machine for it precisely because its
instruction set was not fixed: the microcode is writable, so CMU could throw
away Three Rivers' Pascal-shaped Q-code machine and put a different one in its
place. Same cabinet. Different computer.

## Significance

Accent's message idea carried a second one inside it that turned out to matter
even more: because messages could be large, and copying was expensive, Accent
made **virtual memory and interprocess communication the same mechanism.**
Sending a megabyte does not copy a megabyte; it re-maps it, copy-on-write, and
the pages move only if somebody writes to them. And once memory is just
something a port can serve, a *program* can be the thing that serves it — which
is how you get a file system, or a network file system, that is not in the
kernel at all.

That is the microkernel, stated in 1981 and working.

Then read the family tree. Rashid's group took Accent's lessons, made the new
kernel binary-compatible with Berkeley Unix so that real software would run on
it, and called it **Mach**. Mach went to the CMU RT PCs, then everywhere: to
NeXT, whose NeXTSTEP is a Mach kernel under a BSD userland — the NeXTSTEP
station is on this floor — and from NeXT to Apple, where it became the core of
Mac OS X. **The kernel in the Mac you may have walked in with, and in the phone
in your pocket, is a direct descendant of the kernel running on this PERQ.** Not
an inspiration, not a parallel: a lineage, with the code and the people in it.

Mach's ports also went to GNU Hurd, to OSF/1 and Tru64 — which is also on this
wall — and the message-passing microkernel became one of the two great answers
to how an operating system should be shaped.

## What you're looking at

**Accent S6**, the release CMU ran on PERQs in the mid-1980s, with the **Spice
Lisp** environment on top of it.

Spice Lisp is not a side note. It was CMU's implementation of the language that
would shortly be standardised as Common Lisp — and when the PERQ hardware went
away, Spice Lisp was ported to other machines and renamed **CMU Common Lisp**,
which is still maintained, and from which **SBCL**, the Lisp most people run
today, was forked in 1999. So the listener on this screen is an ancestor too.

<!-- CONDITIONAL — the coordinator trims this block once the lead reports the golden scene. Keep only what the checkpoint actually rests at. -->
What is one keystroke away on the exhibit's keyboard:

- **the Lisp listener** — type a form, get a value. The read-eval-print loop, on
  a 16-bit microcoded workstation, in 1986.
- **the window system** — Accent's own, drawing onto the PERQ's 768×1024
  portrait page. Every window you see is a program holding a port, which is the
  whole thesis of the kernel underneath it, made visible.
<!-- /CONDITIONAL -->

Same 768×1024 portrait screen, same one-bit picture, same Kriz tablet and the
same 14-inch platter as the POS station next door — because it *is* the same
machine. What changed is the microcode, and everything above it.

## Legacy

Accent itself was never sold. It ran at CMU, on a machine whose manufacturer
went under, in a language environment most of the industry had given up on — and
it is arguably the single most influential operating system of the 1980s.

Rashid left CMU for Microsoft in 1991 and founded Microsoft Research; Mach went
to NeXT, and NeXT went to Apple in 1996, and Apple's kernel has carried Mach
ports ever since. Roughly two billion devices are running a descendant of the
thing on this screen, and essentially none of their owners have heard its name.

That is what a research operating system looks like when it works: it does not
survive, it propagates.

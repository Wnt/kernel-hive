---
title: MIT ITS — the hackers' timesharing system
subtitle: 1967 · DEC PDP-10 · DDT, Emacs, Maclisp, and a machine with no locks on it
hero: /posters/its/desktop.webp
images:
  - src: /posters/its/desktop.webp
    alt: An xterm attached to MIT ITS running on an emulated PDP-10, showing the DDT command environment
    caption: ITS was a shared research computer whose users treated the operating system itself as something to inspect, patch and extend.
---
## Origins

The **Incompatible Timesharing System** was written at MIT's Artificial
Intelligence Laboratory from 1967, first for the PDP-6 and then for the PDP-10
family that followed it. The name is a joke at the expense of MIT's earlier
**Compatible Time-Sharing System** down the hall, but the difference underneath
the joke was serious. CTSS and its successor Multics were being built as
utilities — accounted for, access-controlled, designed by committee. ITS was
built by the dozen or so people who used it, for themselves.

So ITS has no passwords. It has no file protection. Any user can read, write or
delete any file, can look at what another user's terminal is displaying, and can
stop, inspect and restart another user's running program. None of that is an
oversight or a limitation of 1967 hardware — Multics had all of it and ITS chose
not to. The ninth floor of Tech Square was a room full of people who trusted each
other and wanted the machine open to all of them.

The other thing a visitor notices immediately is that there is no shell. The
command processor on ITS is **DDT**, the system's debugger. You do not ask a
shell to run a program for you; you attach a debugger to the machine and tell it
what to execute. On ITS, "using the computer" and "debugging the computer" are
the same activity, described with the same commands.

## Significance

The list of software that was first written on ITS is disproportionate to the
number of people who ever used it.

**Emacs** was written here, by Richard Stallman and Guy Steele, as a set of
macros for the TECO editor — which is why Emacs commands are control characters
and why it has been programmable from the inside ever since. **Maclisp** ran
here, and through it Macsyma, the first serious computer algebra system, and the
line of work that led to Scheme and Common Lisp. The **INFO** documentation
system, still the shape GNU manuals take today, was an ITS program. So was the
original *Zork*, upstairs on a different PDP-10 but in the same culture.

And the word **hacker**, in its original sense — someone who understands a system
well enough to play with it — is an ITS word. When MIT finally shut its ITS
machines down and replaced them with systems that would not let him fix a printer
driver, ITS's last system administrator started the GNU project. Much of what
free software still argues about was first an argument about this operating
system.

That makes ITS a sharp contrast with the other large shared machines in this
gallery. MVS feels institutional. Multics feels architectural. ITS feels like a
workshop where nobody ever stopped modifying the benches.

## What you're looking at

MIT's own ITS sites shut down in 1990, and there is no distribution image to
download — ITS was never a product. What exists instead is the **PDP-10/its**
project, which keeps the original MIDAS sources building: the build boots a
PDP-10, assembles the entire operating system inside it, and writes out a
bootable disk pack. That pack is this exhibit. Nothing here was recovered from a
tape; it was rebuilt from source, the way the AI Lab would have.

The station runs that disk on a **DEC PDP-10 (KS10)** under the SIMH simulator,
and puts you on one terminal line — the same way you would have reached the
machine from a Teletype in 1970, rather than at the operator's console. The
simulator's own console is deliberately not on screen.

The keys matter here more than on most exhibits, so the gallery keyboard
offers the ones ITS actually needs: **^Z**, which is how you log in at all;
**Altmode**, the 1960s name for what your keyboard calls Escape, and the key ITS
documentation assumes you will use constantly; **^X**, the Emacs prefix; and
**^C** and **^L**. That is close to the whole vocabulary of the system.

## Legacy

ITS never became a commercial operating system, and almost nobody ever ran it
who was not at MIT. Its influence travelled through people and through software
instead — through Emacs, through Lisp, through the interactive debugger as a way
of working, and through the idea, now unremarkable, that the people using a
computer should be allowed to change it.

Running ITS today is less like recovering a product than like reopening a
workshop.

## Sources

- The maintained ITS reconstruction and build project: https://github.com/PDP-10/its
- Emacs history material preserved in the ITS tree: https://github.com/PDP-10/its/blob/master/doc/eak/emacs.lore

---
title: Multics
subtitle: 1969 · the computing utility MIT, Bell Labs and GE built — and the system Unix was named after
hero: /posters/multics/desktop.webp
images:
  - src: /posters/multics/desktop.webp
    alt: An amber-on-black 80-column terminal showing the Multics MR12.8 banner for channel d.h000, a login as Repair, the "You are protected from preemption" notice, and the output of the who command — "Multics MR12.8, load 6.0/90.0; 6 users, 1 interactive, 5 daemons"
    caption: The whole station is this one terminal. Five of the six users `who` reports are system daemons that log themselves in at every boot; the interactive one is you.
---
## Origins

In 1961 Fernando Corbató demonstrated CTSS at MIT and proved that several
people could use one computer at the same time without any of them noticing
the others. The obvious next question was how far that idea went, and the
answer MIT settled on was: all the way. Computing should be a utility. You
should be able to plug into it the way you plug into the electricity supply —
always on, shared, metered, and nobody's private machine.

Building it took three organisations. MIT's Project MAC had the design,
General Electric built the hardware, and Bell Telephone Laboratories brought
the software people. They announced Multics — Multiplexed Information and
Computing Service — in six papers at the 1965 Fall Joint Computer Conference,
before a single line of it ran.

The machine was a GE-645, a GE-635 modified with the segmentation and paging
hardware the design demanded. The system itself was written in PL/I, which at
the time was close to reckless: everyone knew an operating system had to be
written in assembler, because everyone had only ever seen one written in
assembler.

It was late, and it was enormous. In April 1969 Bell Labs withdrew. Ken
Thompson, Dennis Ritchie and a few colleagues went back to Murray Hill,
found a spare PDP-7, and wrote a small single-user system with the good ideas
and none of the committee. Someone called it UNICS, a joke at the expense of
the thing they had just left, and the joke stuck.

Multics went into service at MIT six months later.

## Significance

Almost everything you expect from a computer today was either invented here
or first made to work here.

A file system with one root, directories inside directories, and symbolic
links between them. Access control lists on every object. Eight hardware
protection rings, so that "the operating system" and "a user program" are
ends of a spectrum rather than two different kinds of thing. Dynamic linking,
where a program does not find a subroutine until the first moment it actually
calls one. A single-level store, in which a file is not something you read
and write but a piece of memory you simply address — an idea so thorough that
Multics has no `read` call to speak of. Hardware you can add or remove while
the system keeps running. And a command processor that is an ordinary user
program with no special privileges, which you may replace with your own.

It was also the system that taught the world what computer security is. A
1974 US Air Force team set out to break into Multics, and the report they
wrote — on the security kernel, on trap doors, on the difference between a
system that has not been broken and one that cannot be — founded the field.
In 1985 Multics became the first operating system rated B2 under the Orange
Book, a level almost nothing has reached since.

Around eighty Multics sites were ever sold. It lost, commercially and
completely, to the small ideas it had inspired. The last one running, at the
Canadian Department of National Defence, was shut down in October 2000. Bull
released the source code in 2007, and a community of people who had used it
spent the years since getting it to boot again.

## What you're looking at

A Honeywell DPS-8/M — the last machine Multics ran on — with a terminal on
one line of its Front-End Network Processor, a whole separate minicomputer
whose only job is to talk to terminals. You have channel d.h000.

There is no desktop and no mouse, because in 1969 there was no such thing.
There is not even a prompt asking you to log in: the banner appears, and the
system waits, because it assumes you know that the word is `login`. Type
`login Repair`, and the password is `multics`.

After that the commands are written out in full, the way Multics liked them —
`list`, `who`, `date_time`, `help`. If you mistype, do not reach for
backspace: Multics predates that convention, and its erase character is `#`
and its kill character is `@`. So `prinq#t` erases the `q`, and anything
followed by `@` is thrown away entirely.

If you interrupt something, the system does not stop it — it suspends it and
hands you a *new command level*, which is why the prompt grows a `level 2` on
the end. Type `release` to throw that level away and come back.

Then have a look at `help`. It is talking to you from 1969, and it is quite
sure you will still be here in the morning.

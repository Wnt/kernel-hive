---
title: Xerox Alto II — the page that stood up
subtitle: 1973 · Alto II XM (portrait page display)
hero: /posters/alto/desktop.webp
images:
  - src: /posters/alto/desktop.webp
    alt: The Xerox Alto Executive on the Non-Programmer's Disk — two banner lines reading "XEROX Alto Executive/11", "OS Version 20/16", "Non-Prog.BFS", then a waiting prompt, black text on a pale page, on a tall portrait screen
    caption: A command prompt, and the most consequential one ever drawn: proportionally spaced type, on a screen shaped like a sheet of paper, in 1973.
---
## Origins

In 1970 Xerox opened a research centre in Palo Alto to work out what the company
should sell after paper. Three years later, in a building full of people who had
just been told to build the office of the future and left largely alone to do it,
Chuck Thacker and Butler Lampson designed a computer for one person to use, all
day, at a desk.

That was not what computers were for. A machine of the Alto's cost belonged to a
department and was rationed out in timeshare slices; the idea that a whole
processor should sit idle waiting for a single human to think was, on any
accounting a manager would recognise, absurd. PARC built it anyway, and then
built about two thousand of them, and never sold one.

Nearly everything on the wall of this gallery is descended from what happened
next. The Alto had overlapping windows and a mouse with buttons. It had a word
processor that showed you the page you were going to get. It had Ethernet — Bob
Metcalfe's, invented on this machine to connect it to other ones — and a laser
printer at the end of it, and electronic mail between the people using them. It
had Smalltalk, and inside Smalltalk the idea that a program is a society of
objects sending each other messages.

## Significance

Start with the screen, because it is the thing you can see from across the room:
it is standing up. The Alto's display is 606 by 808 dots at roughly 72 to the
inch, which is 8.5 by 11 inches, which is a sheet of US Letter paper. That was
not a convenient number that fell out of the hardware. It was the specification.
The machine was for making documents, so the screen was a page, and it therefore
had to be taller than it was wide.

Every document window you have ever scrolled is that decision, still in force.

Then look at what is drawing it. There is no CPU chip in an Alto — no chip in it
does the whole job of a processor. There is a datapath built out of a few hundred
ordinary logic parts, and a microcode program that hands that datapath to sixteen
different *tasks* in priority order. One task repaints the screen straight out of
main memory, sixty fields a second. One shifts sectors on and off the removable
disk cartridge. One moves Ethernet packets. The lowest-priority task, running
only in the gaps the others leave, is the one that executes the instruction set
the software is written in.

So the Alto genuinely gets slower while it is drawing, and faster when the screen
is quiet, and that is not a defect — it is the same trick, taken to its logical
end, that let a machine costing tens of thousands of 1973 dollars belong to one
person.

## What you're looking at

The Alto Executive: the command prompt, on the Non-Programmer's Disk, exactly as
the machine comes up.

It is text, and it is the right text. Look at the type — it is proportionally
spaced, with a serif, on a bitmap screen, at a time when a terminal meant a fixed
grid of identical cells. The Alto had no character generator. Every letter is
pixels the software drew, which is precisely why it could draw any letter it
liked, and precisely why Bravo could show you the page.

Three commands are one tap away on the exhibit's keyboard:

- **BRAVO** — Bravo 7.5, the first WYSIWYG word processor. Charles Simonyi and
  Butler Lampson wrote it in 1974; Simonyi took the idea to Microsoft and it
  became Word. Give it half a minute to load. Its three mouse buttons do three
  different things, which is the whole argument for a mouse having three: the
  left button selects a character, the middle one the word you are pointing at,
  and the right one stretches the selection out to meet you.
- **DRAW** — the illustration program, with its icon palette down the left edge.
  Palettes down the left edge were not yet a convention. This is where they come
  from.
- **LAUREL** — the mail reader, from a building where people already sent each
  other mail all day.

And **?** asks the Executive to list what is on the disk, which is the machine's
own answer to what else it can do.

## Legacy

Xerox did try to sell the idea, as the Star in 1981, and it is the more famous
failure. But the Alto's influence did not travel through a product. It travelled
through visits, and papers, and people leaving: to Apple, where the Lisa and the
Macintosh made the mouse and the window into things you could buy; to Microsoft,
where Simonyi rebuilt Bravo as Word; to 3Com, where Metcalfe sold Ethernet to
everyone.

The most quoted line about PARC is Steve Jobs saying that within ten minutes of
seeing the graphical interface it was obvious that every computer would work this
way one day. The less quoted part is that he was looking at a machine which had
already worked that way for six years, in a building where a few hundred people
used it every day to do their actual jobs, and which the company that owned it
had decided was not a product.

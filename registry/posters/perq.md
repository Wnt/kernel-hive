---
title: PERQ 1 — the workstation, before the word
subtitle: 1986 · POS G.7 (Three Rivers PERQ 1, portrait display)
hero: /posters/perq/desktop.webp
images:
  - src: /posters/perq/desktop.webp
    alt: PLACEHOLDER — the POS G.7 shell on a PERQ 1, black text on a pale page, on a tall portrait screen
    caption: PLACEHOLDER — the PERQ Operating System at its prompt, on a screen shaped like a sheet of paper.
---
## Origins

In 1979 three men left Carnegie Mellon University in Pittsburgh, took the name
of the city's rivers for their company, and set out to build something nobody
was selling: a computer for one person, with a picture on the screen and a
pointing device in the hand.

That was not a new idea in 1979. Xerox PARC had been living it since 1973, on
the Alto on the wall of this gallery — but Xerox was not selling Altos to
anyone, and would not sell the Star until April 1981. Three Rivers Computer
Corporation shipped the **PERQ** first. When it reached customers in 1980 it
was the first commercial workstation with a bitmapped display and a mouse: not
a research machine on loan, not a prototype in a lab, but a product with a
price and a delivery date.

It did not stay an American story for long. **ICL**, Britain's national
computer company, took the PERQ on in 1981 and sold it into UK universities and
the Alvey research programme as the ICL PERQ — which is why, for a generation of
British computer scientists, the first graphical machine they ever touched was
not a Macintosh but this one.

## Significance

Open the cabinet and the PERQ's real argument is inside it.

There is no fixed instruction set in a PERQ. The CPU is a 16-bit datapath built
from bit-slice parts, and what it actually executes is **microcode** — and the
microcode is writable. Three Rivers wrote a microprogram that made the machine
execute **Q-codes**: a byte-code instruction set designed, from the top down, to
run compiled **Pascal** and nothing else in particular. The stack, the calling
sequence, the way a procedure finds its variables — all of it is the language's
shape, cut directly into the hardware.

So the PERQ's operating system is not written in Pascal the way a program is
written in a language. It is written in Pascal the way a building is made of
the bricks it was designed around. And because the microstore is writable, a
determined owner could load a *different* microprogram and have a different
machine by lunchtime — which is exactly what Carnegie Mellon did, and the other
half of this exhibit is the result.

Then there is the screen: **768 by 1024 pixels, standing on end.** A page, not
a television. The same decision the Alto made in 1973, for the same reason — the
work was documents — and the PERQ is one of a handful of machines you can buy
that ever committed to it. Beside the keyboard sits not a mouse but a **Kriz
tablet**, a graphics tablet with a puck, reporting an absolute position on a
surface rather than a direction of travel. And under the floor of the cabinet
turns a **14-inch Shugart hard disk**, a platter the size of a dinner plate,
which is what a personal computer's storage looked like before it got small.

## What you're looking at

**PERQ POS G.7** — the PERQ Operating System, Three Rivers' own, written in
Pascal at the company that built the machine. This is a late release of it,
from 1986, running on a PERQ 1.

POS is a single-user system that assumes the screen is the point. The shell
takes typed commands, and above and around it the windowing system draws the
machine's own tools: a screen-oriented editor, the Pascal compiler and the
environment that runs what it produces. It is not a desktop with icons — the
PERQ is a year older than the Star and does not pretend otherwise — but it is
unmistakably the same family of idea: a whole processor, a whole screen, and one
person.

<!-- CONDITIONAL — the coordinator trims this block once the lead reports the golden scene. Keep only what the checkpoint actually rests at. -->
What is one keystroke away on the exhibit's keyboard:

- **the POS shell prompt** — the machine's own command line, and the way into
  everything else on the disk. Ask it for a directory and it will tell you what
  a 1986 workstation kept on fourteen inches of platter.
- **the windowed editor** — POS's screen editor, drawn into a window on the
  portrait page. Watch what the software does with the extra height: this is
  what a screen shaped like paper is *for*.
<!-- /CONDITIONAL -->

The display is the machine's own 768×1024, portrait, one bit deep. There are no
greys on a PERQ.

## Legacy

Three Rivers renamed itself PERQ Systems, and by 1986 the company was finished;
ICL kept the machine going in Britain a little longer. The workstation market
the PERQ opened was won by Sun and Apollo, who arrived a year or two later with
Unix, Ethernet and a landscape screen, and who did not ask their customers to
love Pascal.

But the PERQ's most consequential legacy is not a product at all. At Carnegie
Mellon, thirty miles of thinking from where the machine was designed, the
**SPICE** project took PERQs and rewrote what ran on them — and that work, a
message-passing kernel called Accent, became Mach, and Mach is still the kernel
inside every Mac and every iPhone. The next tile along is that machine, booted
the other way.

One cabinet. Two operating systems. One of them is under your thumb right now.

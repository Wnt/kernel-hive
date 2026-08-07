---
title: Multitech Microprofessor II — MPF-II BASIC
subtitle: 1982 · Microprofessor II
hero: /posters/mpf2/desktop.webp
images:
  - src: /posters/mpf2/desktop.webp
    alt: The MPF-II banner and BASIC prompt on a black screen
    caption: The whole machine at rest — a banner, a prompt, and 64 KB waiting for a program.
---
## Origins

Multitech was five years old in 1982 and better known for distributing components than for building computers. The Microprofessor II was its bid for the home, and it arrived looking like nothing else: a low plastic slab, barely thicker than a book, with a small chiclet keyboard sunk into the lower half and no monitor of its own. It expected a television set.

Inside was a MOS 6502 running at one megahertz alongside 64 KB of memory and 16 KB of read-only memory holding a BASIC dialect closely modeled on the one Apple II owners knew. The resemblance was deliberate and only partial. The memory map differs, the keyboard is wired as its own matrix rather than the Apple's, and the graphics pages sit elsewhere, so software written for the American machine largely does not run here. What Multitech borrowed was the idea and the language, not the circuitry.

Taiwan had built parts for the computer industry for years. This was among the first machines the island sold under its own name to the wider world. The company that made it renamed itself Acer four years later.

## Significance

The most revealing thing about the Microprofessor II is what it lacks. There is no character generator chip — no dedicated hardware that turns a byte into a letter on screen. Every character you see is drawn by the processor itself, plotting a glyph pixel by pixel into the same bitmap that holds the graphics. The ROM contains the font as data and the routine that paints it.

This is why the display behaves the way it does. Scrolling a line of text is not a matter of nudging a pointer; it is the 6502 moving the picture, one region at a time, while everything else waits. The deliberateness is not a fault to be excused but the machine's honest cost of doing business, visible in a way that later hardware hides.

The economy bought something in return. The same bitmap serves text and graphics alike, so the display can carry 40 columns of characters, a coarse 48 by 40 grid of blocks, or 280 by 192 pixels in six colors, without separate hardware for each.

## What you're looking at

The banner and the `>` prompt are the whole of the machine's user interface at startup. There is no menu, no desktop, and no file listing — only BASIC, ready for a line number or a direct command. Programs arrived on audio cassette, and a floppy drive was available for those who could afford one.

There is no mouse, and no place to plug one in. The keyboard is the entire instrument: 48 keys, upper case only.

## Legacy

The Microprofessor II sold modestly and is remembered chiefly by collectors. Its importance is positional rather than commercial — an early, self-branded product from a country that had until then supplied other people's factories, made by a company on its way to becoming one of the largest computer manufacturers in the world.

It also preserves a moment when the boundary between hardware and software sat in a different place. A letter appearing on this screen is not a feature of a chip. It is a program, running.

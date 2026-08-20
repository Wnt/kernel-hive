---
title: Commodore CBM 610 — the business machine nobody bought
subtitle: 1982 · CBM 610 (BASIC 128, 6509)
hero: /posters/cbm2/desktop.webp
images:
  - src: /posters/cbm2/desktop.webp
    alt: A Commodore CBM 610 — a low, wide beige business machine with an integrated keyboard and a separate monochrome monitor sitting on top of it
    caption: Low-profile box, detached green screen, IEEE-488 on the back. This is what Commodore thought an office computer should look like in 1982.
---
## Origins

By 1982 Commodore had two successes and a problem. The PET had made it the machine of schools and laboratories; the VIC-20 was about to make it the machine of living rooms. What it did not have was the office, where a business would rather buy an IBM.

The answer was the CBM-II — the B series in the United States, the CBM 6x0 and 7x0 in Europe. The case carried a rumour with it: "Porsche PET," because Commodore was supposed to have Porsche design it. They did consult Porsche, and gave up when the price came in; the case that shipped was a rework of an original PET prototype. At its centre is a chip built for the occasion: the **MOS 6509**, a 6502 with two extra registers that page one of sixteen 64 KB banks into view, so a 1975 processor design, clocked at 2 MHz here, could address a full megabyte. Around it went 128 or 256 KB of RAM, an 80-column monochrome screen, a SID for sound, IEEE-488 for the business drives and printers Commodore already sold, and a full business keyboard with a numeric pad. The low-profile 6x0 models put that keyboard in the case and left the monitor detached; the 7x0 models bolted a screen on top.

The range was designed under Jack Tramiel and largely abandoned after him. It arrived expensive, incompatible with everything Commodore already sold, and into the teeth of the IBM PC. The higher-end P-series variants for the home were cancelled outright; the business machines were quietly discontinued, having sold in the tens of thousands rather than the millions.

## Significance

The CBM-II matters as the moment Commodore tried, seriously and expensively, to be a business computer company, and discovered that it could not.

Everything about the machine is a reasonable answer to the wrong question. Banking a megabyte through a 6502 was genuinely clever engineering, but the market had already decided that the future of the office was a 16-bit processor with a flat address space. IEEE-488 was the right bus for Commodore's own peripherals and the wrong one for everybody else's. Coprocessor boards — an 8088, a Z80 for CP/M — were announced for it, but apparently none reached production, which tells you plainly that the machine's own software library was not the argument for buying it.

What it left behind is more interesting than what it sold. The SID is the same chip the C64 was shipping that year, and the 80-column green screen reappears, years later, in the Commodore 128 of 1985 — which, like this machine, named itself for its 128 KB of RAM, but solved the memory problem with a dedicated management chip rather than in the CPU, and shared none of this one's hardware.

## What you're looking at

The machine as it wakes up, with nothing plugged into it. Green on black, eighty columns (a 6545 CRTC does the display), two lines:

`*** commodore basic 128, v4.0 ***` and `ready.`

That "128" is a coincidence, and worth pausing on: it counts kilobytes of RAM, three years before the Commodore 128 existed. This is not that machine, and shares no hardware, no ROM and no software with it.

It also is not the PET on the next plinth, however similar the screen looks. Behind this banner is a 6509 paging a megabyte, in a low business box with the monitor separate, sold to a market Commodore reached for and missed — where the 8032 is a 6502 with a flat 64 KB, an all-in-one bolted together for schools, and a machine that actually sold. Two green screens, two completely different bets.

Type at the prompt. BASIC 4.0's disk commands, the built-in machine-language monitor and the `BANK` command that switches those sixteen banks are all here, from cold, with no disk in the building.

## Legacy

The CBM-II was withdrawn quickly and is now among the rarest Commodore machines to find working. Its closest kin is the Commodore 128, which kept the 80-column screen and the number on the banner; its commercial lesson was one Commodore learned the expensive way and then acted on, retreating to the home market where the C64 was already making it more money than any business line ever would.

It is worth a plinth for the same reason a failed prototype is worth a case: it shows what the company believed the future of computing looked like in 1982, and how completely the industry disagreed.

---
title: VisiCorp Visi On 1.0
subtitle: 1983 · the IBM PC's first windowing desktop, two years before Windows 1.0
hero: /posters/vision/desktop.webp
images:
  - src: /posters/vision/desktop.webp
    alt: The Visi On desktop on an IBM PC XT — a stippled monochrome screen with the Services window open on Archives, its start/install/remove/Printing menu line, and a command strip along the bottom reading HELP, CLOSE, OPEN, FULL, FRAME, OPTIONS, TRANSFER, STOP
    caption: Visi On at rest, driven entirely with a serial mouse — the command strip along the bottom is the whole interface, and there is no command line anywhere.
---
## Origins

**VisiCorp** was the company that had sold **VisiCalc**, the spreadsheet that gave people a reason to buy an Apple II, and by 1982 it was looking for the thing that would do the same for the IBM PC. What it showed at Comdex in November 1982 was **Visi On**: a bitmapped screen, a mouse, windows you could move and resize and overlap, a menu strip along the bottom edge, and a suite of applications that all obeyed the same rules. Nothing like it had been demonstrated on a PC. Microsoft announced Windows the following year; Windows 1.0 did not ship until November 1985.

Underneath, Visi On was not really a PC program at all. VisiCorp's engineers wrote it in a dialect of C on a **Unix development host**, compiled it for a virtual machine of their own design — the **Visi Machine** — and shipped an interpreter for that machine on the PC. The idea was that Visi On and every application written for it would be portable: recompile the Visi Machine for the next architecture and the whole product follows. It is the same bet Java made a decade later, made by a spreadsheet company in 1982.

Visi On shipped at the end of 1983 and cost what it was worth to build. The **Application Manager** alone was $495; the mouse VisiCorp required — a Mouse Systems optical unit on a serial port, with its own metal pad — was another $250; **Visi On Calc**, **Visi On Word** and **Visi On Graph** were $195 to $395 each. It needed a **hard disk**, which in 1983 meant an IBM PC XT, and 512 KB or more of memory when the machine most offices had bought shipped with 64. Almost nobody could run it, and the few who could found it slow. VisiCorp was sold off within the year, and Visi On went with the rest of the assets to **Control Data Corporation** in 1984.

## Significance

Visi On is the first integrated windowing desktop that a member of the public could buy for an IBM PC, and it is the one that establishes that the ideas were not waiting on anybody's invention — they were waiting on hardware cheap enough to run them. Everything in the standard account of the mid-1980s GUI is already here: overlapping windows with a mouse, a consistent menu vocabulary shared by every application, cut and paste between programs, on-screen help as a first-class service rather than a manual on the desk.

It also failed in a way worth understanding, because the failure was not the design. A PC XT with 512 KB was a $5,000 machine before software; asking for that plus $495 plus a $250 mouse plus $395 for the spreadsheet, in order to run a spreadsheet that already ran fine in text mode for less, is a proposition that engineering excellence cannot rescue. Microsoft's answer two years later was cheaper, ran on a floppy-based PC, and let DOS applications go on being DOS applications. That is the lesson the PC industry actually took from Visi On.

The Visi Machine deserves its own note. Portable byte code, one language, applications that outlive the processor they were written for — VisiCorp got there in 1982, and got nowhere with it, because the interpreter's overhead was exactly what an 8088 could least afford.

## What you're looking at

An IBM PC of the XT class — an Intel **8088**, 640 KB of memory, a 10 MB hard disk, monochrome CGA graphics, and the **Mouse Systems serial mouse** Visi On will not run without: it drives the 8250 itself, with no DOS mouse driver anywhere in the loop. The system boots PC-DOS 2.00 from the hard disk and straight into the Application Manager; the golden state this exhibit restores opens with the **Services** window already on **Archives**, its `start install remove Printing` menu line ready.

The strip along the bottom is where everything starts: **HELP, CLOSE, OPEN, FULL, FRAME, OPTIONS, TRANSFER, STOP**. Point at a word and press the mouse button, and the strip changes to the next set of choices — the interface has no icons and no double-click, only a pointer and a sentence you build one word at a time. Windows are opened, moved and resized from those words rather than from a title bar, which is the part that feels most foreign today and was the most carefully reasoned thing in the product at the time.

This exhibit is mouse-first the way Visi On itself was in 1983: the pointer is the primary instrument and the copy-protected key disk that gates every start stays in drive A: the whole time you're here. A PC/XT keyboard is attached for the rare menu that wants text, but there is no command line to type into.

Reset returns the disk and the screen to the state above, so whatever you open belongs to your visit.

## Legacy

Nothing shipped on top of Visi On. Control Data did little with it, the third-party applications the Visi Machine was supposed to attract never arrived, and the product is remembered — when it is remembered — as the answer to a trivia question about what came before Windows. But the screen in front of you is the point: in 1983, on the same beige box that was running DOS 2.0 down the hall, somebody had already built the desktop, priced it honestly for what it cost to make, and found out that honest was too expensive. Every GUI that succeeded on the PC afterwards succeeded by being a cheaper version of this.

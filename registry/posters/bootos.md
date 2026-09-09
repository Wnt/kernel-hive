---
title: bootOS
subtitle: 2019 · an operating system in one 512-byte boot sector
hero: /posters/bootos/desktop.webp
images:
  - src: /posters/bootos/desktop.webp
    alt: Four bootOS screens on black — top left the 80x25 text console after `dir`, listing nineteen program names in grey under the bootOS banner and a $ prompt; top right five rows of rainbow-coloured space invaders above a row of cyan shields and a grey cannon; bottom left a blue Pac-Man-style maze with dots, a yellow player and three ghosts; bottom right the atomchess board drawn in letters, rnbqkbnr and a row of p over dots over a row of P and RNBQKBNR
    caption: Four one-sector programs from the exhibit's floppy — the shell's own `dir`, invaders, Pillman and Toledo Atomchess. Each of the three games fits in one 512-byte sector; so does the operating system that loaded it.
  - src: /posters/bootos/dir.webp
    alt: bootOS's text console straight after boot — SeaBIOS's "Booting from Floppy..." line, the bootOS banner, "$dir", and the nineteen file names fbird, pillman, invaders, basic, textmode, counter, data.bin, bootslide, atomchess, tetranglix, snake, mine, rogue, bricks, cubicdoom, sokoban, heart, pi and bootle, then a $ prompt with the caret
    caption: The whole user interface. A $ prompt, five built-in commands, and a directory that can hold thirty-two names because that is how many 16-byte entries fit in one sector.
  - src: /posters/bootos/invaders.webp
    alt: The invaders game in 640x400 graphics mode — five rows of eleven aliens in a rainbow of colours, a small red shot in flight, five cyan shields, and a grey cannon at the bottom
    caption: invaders, from the first book — a colour graphics-mode Space Invaders in 512 bytes. Its screen is 640 by 400, so on this exhibit it shows narrower than the 720-pixel text console.
  - src: /posters/bootos/hello.webp
    alt: The console after the type-in demo — the directory listing now ends with "hello", then "$hello", then "Hello, world" and a fresh $ prompt
    caption: The type-in demo's result. `enter` took three lines of hex and an empty line, `*hello` named the file, `dir` shows it on the disk, and running it prints Hello, world through bootOS's int 0x22 output service.
---
## Origins

bootOS was written by **Óscar Toledo Gutiérrez** — the Mexican programmer behind Toledo Nanochess and a string of prize-winning entries in the International Obfuscated C Code Contest — and the source file carries its own timeline: *creation date Jul/21/2019, 6pm–10pm*, a revision the next day for "optimization, corrections and comments", and a final one on 31 July that added a service table. It was published on 22 July 2019 under a BSD licence. It is an operating system, in the plain sense of the word, and it is 512 bytes long.

Those 512 bytes are the boot sector of a floppy disk. The BIOS reads the first sector of the disk into memory at address 7C00 and jumps to it, exactly as it has done since the original IBM PC of 1981. bootOS uses that moment to copy itself out of the way to 7A00, needs 768 bytes of working memory just below that, and then treats the just-vacated 7C00 as the place it will load *other* boot sectors into. That is the whole architectural idea: a program for bootOS is anything that would run as a boot sector, and the operating system is a thing that loads boot sectors on request instead of only once at power-on.

Because the machine it targets is the 8088 in that 1981 PC, the code is written for the 8086 instruction set — `cpu 8086` is the first directive in the file — and the disk layout is just as spare. The directory lives in the second sector of track 0: thirty-two entries of sixteen bytes, each holding a zero-terminated file name. Every file is one sector long, and its position in the directory is its address on the disk: the first name in the directory is stored at track 1, the second at track 2, up to track 32. Deleting a file means zeroing its sixteen-byte entry. There are no sizes, no dates, no attributes, no free-space map — there is no room for any.

## Significance

A 512-byte operating system is a stunt, and a good one, but bootOS is the centre of something larger. Toledo had already spent years in the *sizecoding* tradition of writing complete programs in a boot sector — Toledo Atomchess, a playable chess program in 512 bytes, is the best known — and he collected that work into two books, **Programming Boot Sector Games** and **More Boot Sector Games**, which teach 8086 assembly through exactly these programs: a number-guessing game, tic-tac-toe, a Mandelbrot set, F-Bird, invaders, Pillman, Atomchess, bootBASIC; then Follow the Lights, bootRogue, bricks, cubicDoom — and bootOS itself, the operating system written to give all of them a home.

That gave the boot-sector scene something it had never had: a disk. Before bootOS, each of these games was its own floppy, one sector long and alone on the medium. With it, a single 360K disk can carry the operating system and thirty-two programs, list them by name and run any one by typing it. The README's own delighted heading says it: *"bootOS programs: (Oh yes! we have software support)"* — and then, a little further down, *"Also our first 3rd party programs!!!"*: bootSlide and tetranglix by XlogicX, snake by pmikkelsen, bootMine by io12, sokoban from ish.works. An operating system with an ecosystem, in half a kilobyte.

The `enter` command is the other half of the argument. bootOS has no assembler, no editor and no compiler, but it can accept a program as lines of hexadecimal bytes typed at the keyboard, and save them as a file. The README shows the canonical example — three lines of hex, an empty line to finish, and the name `hello` — and this exhibit's type-in demo does exactly that. It is the same ritual as typing a machine-code listing out of a 1980s magazine, and it means that the system's whole software supply chain fits on the screen at once.

## What you're looking at

An 8088-compatible PC — under the exhibit, a KVM virtual machine with 64 MB it will never touch, one 360K floppy, standard VGA and a PC speaker — booting from that floppy. SeaBIOS prints *Booting from Floppy...*, bootOS prints its name, and you are at the `$` prompt in 80 by 25 text mode, 720 by 400 pixels. Everything on this screen comes from a program of at most 512 bytes.

There is no mouse, because bootOS reads the BIOS keyboard and nothing else. Type **`dir`** and you get the directory: nineteen names on this disk. Type a name to run it. The Toledo games are all here — **fbird**, **pillman**, **invaders**, **basic** (bootBASIC, a tiny interpreter with its own `>` prompt), **atomchess**, **rogue**, **bricks**, **cubicdoom** (a first-person raycaster), **heart**, **pi** and **bootle** — with the third-party **bootslide**, **tetranglix**, **snake**, **mine** and **sokoban** alongside them, and a few small utilities: **textmode** clears the screen, and **counter** keeps a running tally in **data.bin**, which is the save-file service being exercised. Several of these need a 286 or better and bootMine wants a Pentium II's `rdtsc`; the emulated CPU is modern, so all of them run.

A game that ends on its own comes back to the `$` prompt through bootOS's int 0x20. One that does not is left with **Ctrl+Alt+Del**, which warm-boots the floppy and puts bootOS back in a second. The other four commands are **`ver`**, **`del name`**, **`format`** (which you should not run: it wipes the directory) and **`enter`**. The stage menu's *Type in a hello-world program* runs the README's example for you: `enter`, three lines of hex at the `h` prompt, an empty line to say the listing is over, `hello` at the `*` prompt to name it, and `hello` to run it. Note the empty line — `enter` reads hex until it receives one.

The floppy is real, in the sense that `enter` and `del` write to it. It is also restored when the exhibit resets, so anything you type in belongs to your visit.

## Legacy

The hall's other PCs all begin the same way — a BIOS reads one sector off a disk — and then spend that sector loading something bigger: DOS, Windows, a Linux kernel, TempleOS's own loader. bootOS is the one machine here that stops at the first sector and calls it done. It is the smallest operating system in the building by a wide margin, and the only one that is exactly the size of the sector the BIOS loads.

Its afterlife is the scene it organises. Boot-sector games keep appearing, the two books remain the standard introduction to writing them, and a fork by laura240406 runs bootOS from a USB stick. The disk in this exhibit is Toledo's own `osall.img` from the project's repository; its programs load at 7C00 the way the BIOS would have loaded them, which is the point of the design, and the reason a 2019 operating system can be exhibited on the class of machine IBM shipped in 1981.

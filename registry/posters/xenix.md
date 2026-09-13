---
title: SCO Xenix System V/386 2.3.4
subtitle: 1989 · Microsoft's own Unix — for most of the 1980s, the most-installed Unix in the world
hero: /posters/xenix/desktop.webp
images:
  - src: /posters/xenix/desktop.webp
    alt: PLACEHOLDER hero for xenix — replaced with the station's real console frame
    caption: PLACEHOLDER — replaced with the real Xenix console frame.
---
## Origins

The strangest fact in this hall is that **Microsoft sold Unix before it sold DOS**. Microsoft licensed **Version 7 Unix** from AT&T at the end of the 1970s, and on **25 August 1980** announced a 16-bit microcomputer Unix of its own. AT&T would not license the *name*, so Microsoft invented one: **Xenix**.

It was not a side project. The first port shipped in January 1981 for the Zilog Z8001; an 8086 port followed for Altos in 1982, Intel sold whole machines with it, and when Tandy made **TRS-Xenix** the standard system for the TRS-80 Model 16, Tandy became the largest Unix vendor in the world in 1984. Microsoft did not sell Xenix to end users at all — it sold it to hardware makers, who put their own name on it, which is why a system this widespread left so little trace in public memory. Xenix 2.0 was still Version 7 underneath; 3.0 moved to System III; **Xenix System V** (5.0) moved to System V Release 2, and the version numbering that ends at the release in front of you begins there.

Microsoft had a porting partner in Santa Cruz, California — the **Santa Cruz Operation**, SCO — and after the Bell System breakup in 1984 AT&T began selling System V itself. Microsoft's interest moved to OS/2, the system it was building with IBM, and in **1987** it handed Xenix to SCO outright in a deal that left Microsoft holding just under 20% of the company. SCO then did the thing Microsoft had decided not to do: it ported Xenix to the **80386**. **Xenix System V Release 2.3.1** added i386, SCSI and TCP/IP support, and was the first 32-bit operating system you could buy for the x86.

**2.3.4** — the release this exhibit runs — is the last of that line, the end of a product that began at AT&T in 1979 and stopped being Microsoft's in 1987.

## Significance

By the numbers, Xenix won the 1980s. AT&T's own figures for 1988 put Xenix developers at **about half of the 500,000 Unix licences worldwide**: while Unix was still exotic inside companies, the Unix that was actually installed, on actual hardware, was more likely than not Microsoft's. It ran on machines with no hard disk budget and eight serial terminals hanging off the back, and it is the reason a generation of small businesses ran accounting packages on Unix without ever using the word.

Its most-copied invention is on this screen. **Multiscreen** — several independent full-screen sessions on one console, switched with **Alt+F1** through **Alt+F4** — gave a single-user PC the thing a Unix minicomputer had by definition and a PC did not: more than one place to be at once. Linux's virtual consoles work the same way, with the same keystrokes, and arrived a decade later.

The lineage then splits in two, and both halves are on this floor. SCO branched Xenix into **SCO UNIX System V/386** in 1989 and carried the code, the customers and eventually the name into the 1990s and into the litigation of the 2000s. Microsoft's own path went to OS/2 with IBM — the `os2warp` station — and, when that partnership broke, to Windows NT. The company that wrote this system ran its internal mail on it long after selling it: **all** of Microsoft's internal email transport ran on Xenix-based 386 and 486 machines until it moved to Exchange in **1996**.

Stand this next to `msdoswin1` and the shape of the decade is clear. In 1985 Microsoft was shipping MS-DOS, Windows 1.0 and a Unix, and had no public opinion about which of them was the future.

## What you're looking at

A plain ISA-bus AT-class PC — an **80386-compatible CPU**, 16 MB of memory, standard VGA, one IDE hard disk — booting SCO Xenix System V/386 2.3.4 from that disk to a **login:** prompt. There is no PCI bus and no PCI anything, because this system predates the bus by years and probes for hardware the way a 1989 kernel does: by asking the ISA card slots.

There is **no mouse**. A Xenix console is 80 columns by 25 rows of text, and everything here is done by typing. `uname -a` names the machine and the release; `who` shows who is logged in on which console; `ls /usr` shows the shape of a System V filesystem — `bin`, `lib`, `spool`, `tmp` — laid out the way every Unix laid it out before anyone thought to argue about it.

Then press **Alt+F2**. The screen switches to a second, entirely separate login — same machine, same kernel, a different session — and **Alt+F1** brings the first one back, exactly as you left it. That is Multiscreen, and it is the single feature worth the trip: the moment a PC stopped being one program at a time.

Whatever you type belongs to your visit. Reset returns the disk and the console to the state above.

## Legacy

Xenix is the most successful operating system that nobody remembers using. Its direct descendant, SCO UNIX, kept selling into the 1990s; its ideas — virtual consoles, a full System V on commodity x86 hardware, Unix as something a small business could afford — arrived in the mainstream a decade later wearing a penguin. AT&T's own System V Release 4 folded Xenix's changes back into the trunk alongside BSD and SunOS, which is the tidiest possible epitaph: the fork was absorbed by the thing it forked from.

And the company that built it went on to spend thirty years being the thing Unix was defined against. The system on this screen is the road Microsoft did not take, still booting.

## Sources

- Wikipedia, [Xenix](https://en.wikipedia.org/wiki/Xenix) — the 1980 announcement date, the port chronology (Z8001 January 1981, Altos 8086 1982, Tandy 1983–84), the System III and System V code bases, the 1987 transfer to SCO, 2.3.1's i386/SCSI/TCP-IP support, the AT&T 1988 licence figure, 2.3.4 as the last release, and the Microsoft internal-mail-until-1996 detail.
- [WinWorld: Xenix 386](https://winworldpc.com/product/xenix/386) — the shipped 386 releases (2.2.3b/c, 2.3.4q, 386GT 2.3.2f/2.3.4h, 386PS) and their media.
- Multiscreen/virtual-console behaviour: SCO Xenix and SCO UNIX documentation as summarised in the [Xenix talk page](https://en.wikipedia.org/wiki/Talk:Xenix) and [aplawrence's SCO FAQ](https://www.aplawrence.com/FAQ_scotec6appswitch.html).
- Machine facts (CPU class, memory, disk, console geometry) are this exhibit's own device set, recorded in `docs/lab/XENIX-WAVE.md`.

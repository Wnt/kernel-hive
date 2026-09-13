# Pre-2010 survey — notable operating systems the lineup still lacks

Written 2026-09-13 against the 101-entry registry after the five-station wave
(oberon, magiccap, perq, fmtowns, vision). Same scale as
[`os-media-catalog.md`](os-media-catalog.md): **MV** = museum value 1–5,
**Diff** = how far the exhibit sits from anything already on the floor (1–5),
**Feas** = feasibility with the fleet's tiers and licensing posture (1–5),
**Effort** in agent-hours on the fast path, and a **Tier**: QEMU, MAME
host-native, or `nspawn` (a stock host application, which must run inside the
container shape medley/lisa/perq/vision use). VOM = the Virtual OS Museum
carries a working configuration (reference only, never a source).

What the floor already tells: home micros of 1977–85 are dense; every Motif/CDE
workstation vendor is present; Windows 1.0→11 and the classic Mac from 7.5.3
onward are covered; PDP-11 Unix (`pdp11`), the three 1975 DEC monitors
(`decos`), Alto, Star, Lisa, Apollo, PERQ, Interlisp and Visi On give the
pre-1985 workstation story. The gaps are elsewhere: **the beginnings** (CP/M,
Linux 0.x, Minix, System 1, GS/OS), **handhelds**, **mainframes and
timesharing**, **Japan's PC-98/MSX**, **Microsoft's Unix**, and one legend
(Genera).

## Scored shortlist

| # | OS (year) | MV | Diff | Feas | Effort | Tier | Why it matters / what blocks it |
|---|---|---|---|---|---|---|---|
| 1 | ✅ LIVE `macsys1` — **Macintosh System 1.0 / Finder 1.0 on the Mac 128K (1984)** | 5 | 4 | 5 | 3 h | MAME `mac128k` | The original Macintosh desktop, black-and-white, MFS, the one every visitor has heard of; `macos753` starts eleven years later. ROM museum-private; boots to the Finder from a 400K System disk. |
| 2 | ✅ LIVE `minix2` — **Minix 2.0.4 (1997)** | 5 | 3 | 5 | 2 h | QEMU | Tanenbaum's teaching microkernel, the reason Linux exists; text console; trivially free. Shipped version is Minix 2.0.4 for the pre-2010 story. |
| 3 | **Linux 0.12 (Jan 1992) on a 386, Minix root** | 5 | 3 | 4 | 4 h | QEMU (TCG safest) | "The first Linux you can run": boot floppy + root floppy from the oldlinux archive; bash 1.x prompt. Pairs with `slackware` (1997) as the before/after. |
| 4 | ✅ LIVE `apple2gs` — **Apple IIGS — GS/OS 6.0.1 with the Finder (1992; platform 1986)** | 4 | 4 | 4 | 4 h | MAME `apple2gs` | The colour icon desktop Apple shipped on a 16-bit 8-bit successor, a year before Mac II colour; VOM runs it; ROM museum-private. |
| 5 | **Palm OS 3.5 / 4.1 (Palm III/m505)** | 5 | 5 | 3 | 8 h | MAME `pilot1000`/`palmiii` first, else CloudpilotEmu/POSE in `nspawn` | The first handheld OS that mattered, Graffiti stylus UI; a new form factor on the floor. MAME drivers are marked imperfect; ROMs from PalmDB are museum-private. Pointer = stylus taps, absolute. |
| 6 | **Psion Series 5 — EPOC32 R1 (1997)** | 4 | 5 | 4 | 5 h | MAME `psion5` (VOM uses it) | Keyboard clamshell handheld, Symbian's ancestor; touch + keyboard. Pairs with `sailfishos`/`android` as the mobile lineage. ROM museum-private. |
| 7 | **Symbolics Genera 8.3 (1990)** | 5 | 5 | 2 | 20 h+ | `nspawn` (portable Genera on Linux) or Open Genera on an Alpha emulator | The Lisp Machine: Dynamic Windows, the mouse-documentation line, Zmacs. VOM carries three Genera configs, so a path exists; licensing is the wall (Symbolics' successor still asserts rights) — research first, stage only if a defensible source exists. |
| 8 | **Multics MR12.8 (1998; system 1965–2000)** | 5 | 4 | 5 | 6 h | dps8m in `nspawn` (host app; DPS8/M simulator) | The system Unix was written against; released by Bull for non-commercial use; text (a 3270-style login). The emulator is a stock binary → container. |
| 9 | ✅ LIVE `xenix` — **Xenix 2.3.4 / SCO Xenix 386 (1989)** | 4 | 3 | 4 | 5 h | QEMU `isapc` | Microsoft's own Unix, once the most-installed Unix in the world; text + optional Multiscreen. Media on WinWorld/archive; PC-era 386 boots under QEMU with the right disk geometry. |
| 10 | **CP/M 2.2 on a Kaypro II or Altair (1982; CP/M 1977)** | 4 | 3 | 5 | 3 h | MAME `kaypro2` / `altair` | "The OS before DOS", the A> prompt, WordStar. Licensed free since 2022. Text; a home-micro cabinet that is not a game machine. |
| 11 | **MSX2 — MSX-DOS 2 + MSX-BASIC (1985)** | 4 | 3 | 5 | 3 h | MAME `hbf700p`/`nms8250` or openMSX (`nspawn`) | The standard that ran Japan and Europe's living rooms; joins `chokanji`/`fmtowns` in the Japanese wing. ROMs museum-private. |
| 12 | **NEC PC-9801 — MS-DOS 6.2 + Windows 3.1 (Japanese) (1993; platform 1982)** | 4 | 4 | 3 | 8 h | MAME `pc9801rs`/`pc9821` or np21 (`nspawn`) | Japan's PC for fifteen years, DOS/V never touched it; the "same Windows, different machine" exhibit. ROMs + Japanese Windows media are the sourcing cost. |
| 13 | **Newton OS 2.1 on a MessagePad 2100 (1997)** | 4 | 5 | 2 | 12 h | Einstein (`nspawn`) | The other 1990s handheld legend; Einstein needs a ROM dumped from a unit, and the Newton's pen UI needs the absolute pointer. Sourcing gates it. |
| 14 | ✅ LIVE `os213` — **OS/2 1.3 with Presentation Manager (1991; PM 1988)** | 3 | 3 | 4 | 5 h | QEMU | The Microsoft-IBM 16-bit era before Warp; `os2warp` shows the end of the story, this is the start. Media WinWorld. |
| 15 | **Mac OS X 10.0–10.4 (2001–2005) on a PowerPC Mac** | 4 | 3 | 3 | 10 h | QEMU `mac99` (TCG) | Aqua's birth, between `macos9` and today; TCG is slow (10.2 usable, 10.4 sluggish). Licensing posture as `macos9`. Not in VOM. |
| 16 | **Tandy CoCo 3 — OS-9 Level II (1986)** | 3 | 4 | 5 | 3 h | MAME `coco3` | Microware's real-time multiuser OS on a 6809 home computer — the only Unix-like on the 8-bit floor; VOM has 13 OS-9 configs. |
| 17 | **4.3BSD on a VAX-11/780 (1986)** | 4 | 3 | 5 | 4 h | Open SIMH (fleet has it) | Berkeley Unix with TCP/IP as the world got it; text; Caldera licence. `pdp11` and `sunos414` sit either side of it. |
| 18 | **MIT ITS on a KL10 (1970s)** | 4 | 4 | 4 | 4 h | KLH10 (`nspawn`) | Hacker culture's home: Emacs, DDT as shell, no passwords. Text. Free (MIT). |
| 19 | **IBM MVS 3.8j (TK4-/TK5) on a 370 (1978)** | 4 | 5 | 4 | 5 h | Hercules (`nspawn`) | The mainframe: JCL, TSO, a 3270 green screen. The floor has no mainframe. Public-domain MVS. |
| 20 | **RISC OS 3.11 on an Archimedes A3000 (1992)** | 3 | 2 | 4 | 4 h | MAME `aa3000` / Arculator (`nspawn`) | `riscos` is the 2022 release; the 1992 one is a different exhibit only in age. Low Diff. |
| 21 | **Novell NetWare 3.12 (1993)** | 3 | 3 | 3 | 6 h | QEMU | The LAN of the 1990s, a server console with MONITOR; needs a client guest to mean anything. |
| 22 | **Windows Vista / 7 (2007/2009)** | 3 | 1 | 3 | 4 h | QEMU (KVM) | Legendary in the wrong way; between `winxp` and `win11`. Operator supplies licensing (rule 13). |
| 23 | **Syllable Desktop 0.6.6 / AtheOS (2002)** | 3 | 3 | 5 | 2 h | QEMU | Independent BeOS-alike, live CD; already in the media catalog. |
| 24 | **DR GEM (OpenGEM 7) on DOS (1985)** | 3 | 2 | 5 | 2 h | QEMU | The GUI Apple sued over; `atarist` already shows GEM on its native home. |

Not scored, decided against: Windows 2.x/3.0/ME/NT 3.1 and OS/2 2.1 (rungs on
axes already dense); Plan 9 4th edition (`ninefront` is its living form);
SunView on a Sun-3 (no working emulator path); Amoeba, Chorus, Sprite (research
kernels with no desktop and no media); iPhone OS and Windows Mobile (not
legally or practically emulable); game-console firmware (not the museum's
subject).

## Recommended next wave (five, one per gap)

1. **Mac System 1.0** — the biggest name missing from the floor, cheapest tier.
2. **Palm OS** — first handheld, new form factor, pairs with the mobile wing.
3. **Minix 2.0 + Linux 0.12** as one "1991–92 origins" pair of stations.
4. **GS/OS** — the colour GUI nobody expects on an Apple II.
5. **Multics** or **MVS** — the floor's first mainframe/timesharing exhibit.

Landed 2026-09-13: macsys1, minix2, apple2gs, xenix, os213 (see docs/lab/<ID>-WAVE.md per station).

Genera is the prize; start its licensing research now, build it only if a
defensible source exists.

# Candidate: Sony NEWS-OS on a NEWS workstation (MAME `nws5000x`)

**Target: NEWS-OS 4.2.1aRD on `nws5000x` (MIPS R4400, APbus) under MAME
0.250.** Tier 3, host-native, ROM required. The driver has no local
framebuffer, so capture is planned around an Xvfb-hosted X server the guest
reaches over XDMCP, not a direct pixel read — see "Emulator, machine, and
capture shape" below.

**Status: nothing verified on this box.** No media or ROMs sourced, no boot
attempted, no primary source fetched. The no-framebuffer claim comes from a
secondary source (a search snippet); the XDMCP recipe and its parameters are
now corroborated by the Virtual OS Museum's own working install — see
"Evidence" below for exactly what backs each claim and what would confirm it
first-hand.

## What the exhibit is

Sony's NEWS (Network Engineering Workstation System) line: MIPS-based Unix
workstations from Sony Japan, running NEWS-OS, a BSD-derived Unix with an X11
desktop. Visually and historically this sits next to the lab's other 1990s
Unix workstations (IRIX, Solaris, Tru64, OpenVMS) but from a vendor and
market — Japanese enterprise/research — none of the current lineup
represents. That's the slot it earns, not novelty of "another Unix box."
The Virtual OS Museum's reference install is dated 1993 and credited to the
museum's own author.

## Why the capture shape is what it is

MAME's `news_r4k.cpp` driver (mainline PR #8854, briceonk) does not emulate
a framebuffer for the NWS-5000X. The GUI only exists as an X session reached
over the network — there is no local pixel surface for streamhost to read
directly, the way every other Tier-3 host-native station works. The Virtual
OS Museum's own install is consistent with this: MAME's window there shows
only a small upscaled console (integer-scaled ×2), not a workstation desktop
— the machine genuinely never paints a workstation-sized framebuffer
locally, XDMCP is the only place the desktop exists.

That doesn't rule the candidate out. Our converted MAME stations already run
Xvfb + emulator, host-native (`x11-runtime.sh`, as `tru64` does). Pointing
that same Xvfb at an XDMCP session from the NEWS-OS guest is still host-native
capture — no Debian kiosk guest, no bridge, no violation of the no-new-kiosks
rule. What changes from the usual Tier-3 shape is the **input plane**: keys
and pointer go to the X server via XTEST, not through `mamesock`/ctlsock, so
none of the keymap/`MAME_CTL_KEY_EXCL` machinery applies. A new input path is
needed in its place — that's the main open question now, in place of "does it
paint at all."

**This still needs primary-source confirmation.** The no-framebuffer claim
comes from one search-result summary of MAMEdev-adjacent commentary, not the
driver source or `briceonk/news-os`'s own docs. What would confirm it:
reading `nws5000x-mame.md` in `briceonk/news-os` directly, and/or booting the
driver in scratch MAME on CT950 with `-video none` and no network to check
whether anything paints locally at all.

## Evidence from the Virtual OS Museum

VOM ships a working NEWS-OS 4.2.1aRD install (`newsmips/.../news_os_4.2.1ard_config/`).
We take no media or scripts from it — facts only, in our own words, per the
media rule in [`AGENTS.md`](../../../AGENTS.md) and the licence note in
[`vom-reference.md`](vom-reference.md) (its launcher/scripts/config are CC
BY-NC-SA 4.0; this repo is MIT and public). Package metadata (dpkg file
lists on the host rootfs) plus the author's own screenshots give real
numbers, not just filenames:

- **MAME shape**: pinned at **version 0.250**, driver `nws5000x`, with
  `news_os_4.2.1ard.chd`, `nvram/nws5000x/`, and a `roms/` set. The machine
  configuration enables the **`hid` keyboard**, explicitly *disables* the
  serial-terminal keyboard, and sets a front-panel DIP switch. Networking
  runs over the machine's **`sonic`** Ethernet controller. The MAME window
  itself is a small console, integer-scaled ×2 — corroborating the
  no-local-framebuffer read from the driver.
- **The graphical session is the XDMCP shape this note already planned
  around, now with parameters**: a nested X server on display `:10`
  (VOM uses **Xephyr**, a nested *visible* server), the launcher waits for
  that server's socket, then an XDMCP client connects to the guest at its
  fixed address. The session runs at **SXGA (1280×1024), 8-bit colour**, and
  the host's local font path is extended with Sony's own bitmap fonts (the
  install ships a full X font tree including Sony-specific directories).
  VOM's screenshots (`00_Login_Window.png`, `01_Desktop_Applications.png`)
  are of that X session — this is the evidence the capture plan below is
  built on.
- The guest is also reachable over **telnet and FTP** at its fixed address —
  a working TCP/IP stack, independent of the XDMCP graphical path.
- VOM's `mame_nws5000x` emulator entry is a bare symlink to the generic
  `mame` entry (no NEWS-specific fields, no media/ROM notes) — nothing
  further to learn from that side.

## Media and ROMs

Neither sourced, and none of the above helps: VOM's parameters confirm the
*shape* of the install, not where the bits come from. Two things still
needed:

- NEWS-OS 4.2.1aRD distribution media.
- The NWS-5000X's PROM/firmware ROM set, which MAME's driver requires as a
  BIOS/ROM dependency like any other MAME system.

**Plausible source, unfetched:** `briceonk/news-os` on GitHub
(`nws5000x.md`, `nws5000x-mame.md`, `nws3260-mame.md`) documents installing
and running NEWS-OS 4.2.1aRD under this exact driver and appears to be the
primary community reference — likely names where the author's media/ROMs
came from, but that hasn't been checked. No archival source for either the
install media or the PROM set has been independently confirmed. This is an
open sourcing risk, not a solved problem, and VOM's guest disk (untaken, per
the media rule) doesn't change that.

## Graphical target

**Now known, from the VOM install: SXGA (1280×1024), 8-bit colour.** This is
the XDMCP session's geometry, not a MAME framebuffer mode — there is no
local framebuffer to configure. Both numbers are real constraints, not
niceties: an 8-bit session that gets treated as truecolor, or a missing
Sony font path, produces a desktop that *looks* broken (garbled fonts,
wrong palette) rather than failing outright, so both need to be set
correctly before first capture, not discovered by squinting at a screenshot.

## Input plane

The established host-native pattern (relative mouse via MAME's own input,
KEYDUMP-generated keymap, `MAME_CTL_KEY_EXCL`) does not apply here, because
input has to reach an X server via XTEST rather than the ctlsock keyboard
matrix. This is new work, not a checklist item borrowed from the other nine
converted MAME stations — nobody has built an XTEST-based input path for a
kernel-hive station yet.

## Capture plan

Tier 3, following `docs/lab/DEBRIDGE-CONVERSION-BRIEF.md`'s shared
`x11-runtime.sh` and `native.d` build stanza. Our own version differs from
VOM's in one respect: VOM nests a *visible* server (Xephyr) because it runs
on a desktop seat; we have no seat to attach to, so the host-native
equivalent is **Xvfb**, same headless pattern the already-converted MAME
stations use. streamhost then captures that Xvfb server's framebuffer, not
the emulator's own window — the XDMCP client inside it renders the guest's
SXGA/8-bit desktop, using the Sony bitmap fonts installed host-side, exactly
as VOM's install does.

MAME being pinned at 0.250 for this driver is itself a signal worth
carrying into our own build: `news_r4k.cpp` is recent (2020s-era PR) and its
behaviour may be version-sensitive, so this station should pin its MAME
build rather than track whatever version the rest of the fleet uses, at
least until proven otherwise.

`SAVEST golden` for the checkpoint is contingent on the `news_r4k` driver
setting `MACHINE_SUPPORTS_SAVE` — not checked yet. If save states aren't
supported, every session starts from cold boot, a separate viability question
from the capture shape above.

The guest's working telnet/FTP (confirmed in the VOM install) is worth
keeping in reserve as an orchestration or verification channel — e.g.
confirming the guest is up, or driving setup steps — independent of and in
addition to the XDMCP graphical path that actually gets captured.

## Caption honesty

The X-session shape is now confirmed by a real working install, not just
inferred: the exhibit is "NEWS-OS's desktop displayed on our X server"
rather than a machine's own framebuffer, unlike every other Tier-3 station
in the fleet — and MAME's own output being a small upscaled console rather
than a desktop underlines how real that distinction is, not a technicality.
Worth settling how that's captioned before building, not after.

## Effort, risk, open questions

**Effort**: high. New input plane, unsourced media and ROMs, a driver that's
recent enough (2020s-era PR) to still be rough, and a MAME version pin to
maintain.

**Open questions, in the order worth resolving:**

1. Does the no-framebuffer read hold up against the primary source
   (`nws5000x-mame.md`) and a scratch-MAME boot on CT950 — the fastest
   experiment available, and the one that either confirms or overturns the
   whole capture plan above?
2. What does an XTEST-based input path for this station actually look like,
   and does it fit the lab's existing keymap/pointer-calibration machinery
   at all, or does it need its own?
3. Where does archival, hashed install media for NEWS-OS 4.2.1 come from?
4. Where does the NWS-5000X PROM/ROM set come from?
5. Does the driver support `MACHINE_SUPPORTS_SAVE`, i.e. can the station have
   a checkpoint at all?
6. Is the "displayed on our X server" framing acceptable for this exhibit's
   caption, or does it need a different treatment than the other Tier-3
   stations?

**Fastest-resolving experiment:** read `briceonk/news-os`'s `nws5000x-mame.md`
in full, and if still ambiguous, boot the driver in scratch MAME on CT950
with `-video none` and no network to confirm directly whether anything paints
locally. That result settles question 1 and determines whether the rest of
this plan is worth building out.

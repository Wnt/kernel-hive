# Candidate notes — 90s graphical desktops that bring something different

Five short notes, written 2026-08-30 from an operator survey of the Virtual OS
Museum catalog (1703 installations, 922 families) cross-referenced against the
74-entry registry lineup and the open issues on the predecessor repo
`Wnt/osgallery`. These are **candidates, not commitments** — no media has been
fetched and no recipe has been run for any of them.

**Why these five.** 1991–2001 is already the densest era in the lineup
(`newsos` `aux` `irix` `indyr4400` `win311` `solaris` `sunos414` `nextstep`
`nt351` `win95` `hpuxvue` `macos753` `nt4` `os2warp` `rhapsody` `aix432`
`amigaos35` `w2kalpha` `win98se` `beos` `win2000` `macos9`), and every major
Motif/CDE workstation vendor is on the board. So "different" now means leaving
the Unix-workstation and Windows axes entirely, not adding another rung to them.

Media, licensing and boot recipes for the two rows that already exist in
[`os-media-catalog.md`](os-media-catalog.md) (PC/GEOS §2, UnixWare/SCO §5) are
there, not repeated here. The other three are new to this repo.

---

## 1. PC/GEOS — GeoWorks Ensemble 2.0 (1993) — *recommended first*

An object-oriented, preemptively multitasking graphical desktop that ran in
640 KB on a 286, with its own application suite (GeoManager, GeoWrite,
GeoDraw). Architecturally and visually unlike anything in the lineup — and
distinct from the C64 GEOS the `c64` station already runs, despite the shared
name and lineage.

- **Why it wins on effort:** native x86 KVM, no bridge, ~11 MB, Apache-2.0
  media (bluewaysw), and it installs onto a FreeDOS disk of the kind the
  `freedos` tile already builds. Recipe and URL: `os-media-catalog.md` §2.
- **It is a shelf, not a tile.** VOM carries five installs across the family —
  GeoWorks Pro 1.2.8, GeoWorks Ensemble 2.0, NewDeal Office 3.2a and 2000 4.0,
  Breadbox Ensemble 4.1.x — several hosted on DR-DOS/Novell DOS rather than
  FreeDOS. Pick one for the first station; the rest are cheap follow-ups.
- **Open question:** which of the five reads best on a gallery tile. Ensemble
  2.0 is the historically significant one; Breadbox 4.1.4 is the one still
  maintained and the easiest to source.

## 2. Magic Cap 3.1 (1994, General Magic) — *highest novelty, highest risk*

The single most different graphical environment that actually shipped in the
decade: no windows at all, but a spatial metaphor of rooms, hallways and a
physical desk you walk around. General Magic's communicator OS, and the
best-known "the future that didn't happen" artifact of the era.

- **Feasibility is the open question.** VOM files it under the platform
  "Hosted OSes (non-emulated)" — meaning it runs as a host binary rather than
  as an emulated machine. That is compatible in principle with the Tier-3
  host-native capture path, but **the actual host binary, its runtime
  requirements and its licensing posture are all unverified.** Establish that
  before scheduling any build work.
- **If it works**, it is the highest museum-value addition on this list.

## 3. FM Towns OS / Towns System Software 2.1 (1994)

Fujitsu's CD-multimedia GUI for the FM TOWNS — a colourful, mouse-driven
Japanese desktop with no visual debt to Windows or the Mac. Pairs with the
existing `chokanji` (BTRON3) station into a genuine Japanese-desktop wing,
which no other exhibit in the lineup speaks to.

- **Emulator:** VOM runs the FM TOWNS family on **Tsugaru**, a backend present
  in their launcher. Host-native Tier 3, per rule 12 — not a bridge kiosk.
- **VOM has two installs:** MS-DOS for FM Towns 3.1 L24 (Towns System Software
  1.1 L20) and 6.20 L10 (Towns System Software 2.1 L51). The later one is the
  richer desktop.
- **Main cost is media sourcing** (Towns system discs), not integration.

## 4. Amiga UNIX (AMIX) 2.1 (1990)

OPEN LOOK running on an Amiga 3000UX — Commodore's SVR4 port, vanishingly rare
and almost never seen running. The "wait, that existed?" tile.

- **We already own the hard part:** the UAE x11-capture path proven on
  `amigaos35` (see that station's notes for the three UAE traps). AMIX needs an
  A3000 with a 68030 MMU, which is a configuration question inside that same
  path rather than a new emulator.
- **Unverified:** which VOM backend actually runs it (`fs-uae` and `amiberry`
  are both present in their launcher, but the per-installation config lives in
  the guest-image VDI, not in their public repo), and whether the MMU
  configuration we need is reachable from the emulator build we ship.
- Note this is **OPEN LOOK**, not Motif — genuinely a different desktop from
  the CDE/VUE stations, despite also being a commercial Unix.

## 5. UnixWare 2.03 / SCO OpenServer 5.0.7 (1995) — *cheap, low novelty*

The "commercial x86 Unix that lost to Linux" story, which the lineup does not
currently tell. Native x86 KVM, no bridge, and UnixWare has an official free
90-day evaluation. Row, recipe and gotchas: `os-media-catalog.md` §5.

- **Take it for the history, not the visuals** — it is another Motif desktop,
  so it scores low on the "something different" axis that picked the other
  four. Worth doing only as a fast win alongside a slower one.

---

## Also considered, not recommended now

- **DESQview/X 2.1** (1992) — a DOS multitasker hosting X11 clients, a
  genuinely strange hybrid, and a trivial x86 install. VOM has it on MS-DOS
  6.22. The best of the runners-up; deferred only because PC/GEOS covers the
  "DOS-hosted GUI" slot more strikingly.
- **X68000 Ko-Window** (VOM backend `xm6`) — redundant with FM Towns if only
  one Japanese addition is wanted.
- **QNX 4.25 Photon** (1996), including the famous 1.44 MB demo floppy —
  largely covered by the existing `qnx` station (QNX 6.5 Photon).
- **Atari System V 1.0**, **Interactive System V/386**, **Windows CE HPC**,
  **Newton OS 2.1** — all in VOM, all either too close to an existing station
  or not a desktop.

## Two corrections this survey turned up

- **`Wnt/osgallery` #28 (HP-UX 11i) and #29 (SunOS 4.1.4) are stale** — both
  shipped, as `hpuxvue` and `sunos414`. They should be closed.
- **`os-media-catalog.md` §5 calls Tru64 a dead-end** ("qemu-system-alpha
  clipper has no SRM firmware; nothing boots"). That verdict predates the
  `tru64` station, which is live via the ES40 fork — see
  [`../lab/ES40-FORK-BRIEF.md`](../lab/ES40-FORK-BRIEF.md). Fix the row so a
  future agent does not skip a family on stale advice.

// GENERATED shard 3/3 of EXHIBIT_IDENTITIES — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./machineIdentity.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { ExhibitIdentity } from './machineIdentity';

export const EXHIBIT_IDENTITIES_3 = {
  // redhat62: a beige Pentium-class ATX tower of 2000 with a colour CRT at
  // 1024x768 — the SVGA card is the Cirrus GD5446 the emulator presents.
  // Registry red accent (Red Hat's own).
  // slackware: a Pentium-class beige tower with a Cirrus SVGA card driving
  // 1024x768 in 16-bit colour. Registry teal accent (fvwm95's desktop colour).
  slackware: {
    caseTint: '#c9c2ae', accentTint: '#008080', tintMix: 0.35,
    badge: 'PENTIUM PC', spec: 'SVGA 1024x768 • 1997', kit: 'office90',
  },
  // netbsd14: a late-1990s beige Pentium-class clone with a Cirrus SVGA card,
  // the kind of box NetBSD's i386 port was installed on with sysinst. The accent
  // is the registry's NetBSD flag orange.
  netbsd14: {
    caseTint: '#cfc6ae', accentTint: '#f26522', tintMix: 0.35,
    badge: 'PENTIUM PC', spec: 'CIRRUS GD5446 • NETBSD 1.4.1 • 1999', kit: 'office90',
  },
  // openbsd: a current amd64 SFF box running a 1990s desktop — the badge names
  // the hardware class, the spec the X server and the year. Registry accent is
  // the Puffy yellow.
  redhat62: {
    caseTint: '#c4b596', accentTint: '#cc0000', tintMix: 0.35,
    badge: 'ATX TOWER', spec: 'SVGA 1024x768 • 2000', kit: 'office90',
  },
  openbsd: {
    caseTint: '#a5aaa8', accentTint: '#f2c94c', tintMix: 0.35,
    badge: 'AMD64 SFF', spec: 'XENOCARA 1024x768 • 2026', kit: 'workstation',
  },
  // freebsd411: a mid-2000s beige Pentium-4-class mini-tower with a plain VGA
  // card running a 1024x768 KDE 3.3.2 desktop — the last 4.x FreeBSD on the
  // kind of box ISPs racked by the hundred. The accent is the registry's
  // FreeBSD daemon red.
  freebsd411: {
    caseTint: '#cfc6ae', accentTint: '#ab2b28', tintMix: 0.35,
    badge: 'PENTIUM 4 PC', spec: 'VESA SVGA 1024x768 • FREEBSD 4.11 • 2005', kit: 'office90',
  },
  debian22: {
    caseTint: '#d9cfb8', accentTint: '#d70a53', tintMix: 0.35,
    badge: 'DEBIAN GNU/LINUX 2.2', spec: 'POTATO • 2000', kit: 'office90',
  },
  suse64: {
    caseTint: '#d9d4c3', accentTint: '#6ea339', tintMix: 0.38,
    badge: 'PENTIUM III', spec: '17" CRT • 2000', kit: 'workstation',
  },
  // TODO(apple2e): exhibit finish copied from apple2 — set the real era cues.
  apple2e: {
    caseTint: '#c4ad7f', accentTint: '#66715d', tintMix: 0.42,
    badge: 'EDU MICRO', spec: '8-BIT • 1988', kit: 'eightBit',
  },
  // MGT built the SAM in Swansea in an off-white wedge with a dark keyboard
  // well and dark keycaps — the same two-tone the Spectrum +2 had made
  // familiar, but inverted: pale case, dark keys. The accent is that keyboard
  // well rather than a logo colour, because the machine's own front badge is
  // simply its name in dark lettering on the cream.
  samcoupe: {
    caseTint: '#cdc7b6', accentTint: '#2b2a29', tintMix: 0.46,
    badge: 'SAM COUPE', spec: '8-BIT • 1989', kit: 'eightBit',
  },
  // The XL wedge is the pale warm grey Atari used across the 1983 line, with
  // the keyboard sunk in a dark brown bezel and the rainbow fuji badge on the
  // front right. The accent is that bezel brown rather than any of the rainbow
  // stripes: the stripes are a logo, the brown is what half the case reads as
  // from across a room.
  atari800xl: {
    caseTint: '#cfc6b2', accentTint: '#4a3a2c', tintMix: 0.44,
    badge: 'ATARI 800XL', spec: '8-BIT • 1983', kit: 'eightBit',
  },
  // The first Amiga was off-white rather than beige — a pale desktop box with
  // the monitor sitting on top and a garage underneath for the keyboard. The
  // accent is the dark grey of that recess and of the keycaps, not the rainbow
  // badge: the shadow under the machine is what carries across a room.
  a1000: {
    caseTint: '#dcd6c8', accentTint: '#57544e', tintMix: 0.38,
    badge: 'A1000 CLASS', spec: '68000 • 1985', kit: 'workstation',
  },
  // a3000: Commodore's low desktop case, the same cream as the A3000UX (amix)
  // with the Workbench 2.0 grey-blue as the accent.
  a3000: {
    caseTint: '#cfc7b4', accentTint: '#5b7fa6', tintMix: 0.42,
    badge: 'A3000 CLASS', spec: '68030 • 1990', kit: 'office90',
  },
  // medley: the Xerox 1186 Daybreak that Medley shipped on — warm Xerox
  // putty with the red digital-X accent; a 1980s lab kit, not an office one.
  medley: {
    caseTint: '#d6cfbf', accentTint: '#b23a48', tintMix: 0.38,
    badge: '1186', spec: 'MESA • LISP', kit: 'workstation',
  },
  // TODO(sculpt): exhibit finish copied from serenityos — set the real era cues.
  sculpt: {
    caseTint: '#3f4344', accentTint: '#858b88', tintMix: 0.62,
    badge: 'HOBBY BUILD', spec: 'x86-64 • 2018', kit: 'modern',
  },
  // TODO(lisa): exhibit finish copied from amix — set the real era cues.
  lisa: {
    caseTint: '#cfc7b4', accentTint: '#7a8b99', tintMix: 0.42,
    badge: 'A3000UX', spec: '68030 • SVR4', kit: 'office90',
  },
  // domainos: Apollo DN3500 workstation, beige case like the other Unix towers
  // on the floor; the brown accent is the DM's pad0000 title bar, the machine's
  // own screen colour rather than a case moulding.
  domainos: {
    caseTint: '#c9c2ae', accentTint: '#8b5a2b', tintMix: 0.35,
    badge: 'APOLLO DN3500', spec: '68030 • DOMAIN/OS SR10.4.1 • 1989',
    kit: 'workstation',
  },
  // fmtowns: MAME's fmtownsftv — the FM Towns II FreshTV, Fujitsu's 486SX-33
  // CD-ROM desktop (src/mame/fujitsu/fmtowns.cpp: COMP(1994, fmtownsftv, ...,
  // "FM-Towns II FreshTV"), 6 MB RAM). Pale warm-grey Japanese consumer-PC
  // case; the accent is the TownsMENU desktop's own deep teal ground.
  fmtowns: {
    caseTint: '#d6d0c4', accentTint: '#1f6b76', tintMix: 0.40,
    badge: 'FM TOWNS II', spec: '486SX-33 • TOWNS OS V2.1 L51 • 1994',
    kit: 'office90',
  },
  oberon: {
    caseTint: '#cfc9ba', accentTint: '#3d6fb4', tintMix: 0.3,
    badge: 'ETH NATIVE OBERON', spec: 'i386 • Native Oberon 2.3.6 • 1999',
    kit: 'workstation',
  },
  // magiccap: a win98se-class beige tower running General Magic's Magic Cap
  // for Windows (pre-release build 327, 1995) as a hosted Windows app, not a
  // native OS. Registry accent is Magic Cap's own desktop blue.
  magiccap: {
    caseTint: '#c9c2ae', accentTint: '#3a7fc9', tintMix: 0.35,
    badge: 'GENERAL MAGIC PC', spec: 'MAGIC CAP • 1995', kit: 'office90',
  },
  perq: {
    caseTint: '#d6d2c4', accentTint: '#7fa8c9', tintMix: 0.38,
    badge: 'PERQ 1A', spec: '16K bit-slice • POS G.7', kit: 'workstation',
  },
  vision: {
    caseTint: '#d6cdb6', accentTint: '#7FB069', tintMix: 0.38,
    badge: 'IBM 5160', spec: '8088 • Visi On', kit: 'office90',
  },
  // TODO(minix2): exhibit finish copied from freedos — set the real era cues.
  minix2: {
    caseTint: '#b6ad98', accentTint: '#625f58', tintMix: 0.32,
    badge: '486 DX2', spec: 'DOS • 1994', kit: 'office90',
  },
  // TODO(macsys1): exhibit finish copied from apple2e — set the real era cues.
  macsys1: {
    caseTint: '#c4ad7f', accentTint: '#66715d', tintMix: 0.42,
    badge: 'EDU MICRO', spec: '8-BIT • 1988', kit: 'eightBit',
  },
  // The IIGS is the first Apple in PLATINUM — the warm beige of the //e was
  // dropped for a pale cool grey, and the GS wears it a year before the Mac II
  // does. The accent is the Apple six-colour stripe reduced to one hue, which
  // is the point of the exhibit: this is the 8-bit family's first colour desktop.
  apple2gs: {
    caseTint: '#d8d5cc', accentTint: '#3f7fbf', tintMix: 0.30,
    badge: 'Apple IIGS', spec: '65C816 • GS/OS 6', kit: 'eightBit',
  },
  xenix: {
    caseTint: '#cfc7b4', accentTint: '#4f8a8b', tintMix: 0.34,
    badge: 'SCO XENIX 386', spec: '80386 • SYSTEM V/386 2.3.4', kit: 'office90',
  },
  // OS/2 1.3 on an ISA i486 of 1990: IBM's own warm off-white plastics, an
  // IBM-blue accent for the Presentation Manager title bars, VGA-era office kit.
  os213: {
    caseTint: '#cfc5ab', accentTint: '#2d4f8e', tintMix: 0.3,
    badge: 'ISA 486 TOWER', spec: 'VGA • 1990', kit: 'office90',
  },
  // TODO(msx2): exhibit finish copied from samcoupe — set the real era cues.
  msx2: {
    caseTint: '#cdc7b6', accentTint: '#2b2a29', tintMix: 0.46,
    badge: 'SAM COUPE', spec: '8-BIT • 1989', kit: 'eightBit',
  },
  // cpm22: a Kaypro II luggable, 1982 -- the icon-blue steel case CP/M ran
  // on before the IBM PC won the market. Registry accent is the CP/M green
  // phosphor the 9" built-in monitor drew text in.
  cpm22: {
    caseTint: '#3b5b9e', accentTint: '#6b9d70', tintMix: 0.4,
    badge: 'KAYPRO II', spec: 'Z80 2.5MHZ • 64K • 1982', kit: 'eightBit',
  },
  // riscos3: Acorn's own off-white plastic with the red-and-white Acorn
  // roundel as the accent; the badge is what the case actually said.
  riscos3: {
    caseTint: '#dedacf', accentTint: '#c4262e', tintMix: 0.32,
    badge: 'ARCHIMEDES 310', spec: 'ARM2 8MHZ • 4MB • 1992', kit: 'eightBit',
  },
  // A VAX-11/780 is a pair of DEC cabinets in the blue-grey the company used
  // through the late 1970s, with a VT100 on the desk beside it -- not the
  // magenta PDP-11 console this row was scaffolded from.
  vax43bsd: {
    caseTint: '#b9bfc2', accentTint: '#67828f', tintMix: 0.34,
    badge: 'VAX-11/780', spec: '8 MB • 4.3BSD • 1986', kit: 'workstation',
  },
  // IBM's own machine-room blue-grey on the frame, with the 3279's green
  // phosphor as the accent — a colour 3270 is not a green screen, but green is
  // the colour the protected text on it actually was.
  mvs38: {
    caseTint: '#9aa3ab', accentTint: '#4fa36c', tintMix: 0.36,
    badge: 'System/370', spec: '16 MB • MVS 3.8j • 1981', kit: 'workstation',
  },
  // linux012: a plain beige 386 tower of 1992, the year the first public
  // Linux kernel (0.12) shipped — no distro branding to key off, so the
  // finish is the generic office-beige every 386/486 clone wore.
  linux012: {
    caseTint: '#c9c2ac', accentTint: '#4a4a48', tintMix: 0.3,
    badge: '386 TOWER', spec: '80386 • LINUX 0.12 • 1992', kit: 'office90',
  },
  its: {
    caseTint: '#9aa0a6', accentTint: '#b23a48', tintMix: 0.38,
    badge: 'PDP-10 (KS10)', spec: '256 KW • MIT ITS • 1967', kit: 'workstation',
  },
  // Honeywell/Bull mainframe bay: painted steel rather than beige plastic,
  // with the amber of the exhibit's own terminal as the accent.
  multics: {
    caseTint: '#8d9299', accentTint: '#c8892b', tintMix: 0.30,
    badge: 'DPS-8/M', spec: '16 MB • Multics MR12.8 • 1969', kit: 'workstation',
  },
  // macosx: the same graphite Power Mac G4 as macos9 — this exhibit is the
  // OTHER system that shipped on that machine, and the pair is the point. The
  // case tint is macos9's graphite; the accent is the registry's Aqua blue
  // rather than the classic platinum-purple, because Aqua is what changed.
  macosx: {
    caseTint: '#9b9ca6', accentTint: '#5d8fc7', tintMix: 0.4,
    badge: 'POWER MAC G4', spec: 'PowerPC G4 • MAC OS X 10.3 • 2003',
    kit: 'workstation',
  },
} as const satisfies Record<string, ExhibitIdentity>;

import type { ASSEMBLIES_BY_TILE } from './machines';

type StationKit = 'eightBit' | 'office90' | 'workstation' | 'modern' | 'mobile';

export interface ExhibitIdentity {
  caseTint: `#${string}`;
  accentTint: `#${string}`;
  /** Existing baked color remains dominant; this is a restrained exhibit finish shift. */
  tintMix: number;
  badge: string;
  spec?: string;
  kit: StationKit;
}

/**
 * Binding exhibit-finish table. Hardware names and era cues come from
 * HARDWARE-MATRIX.md; badges intentionally omit protected logos/trade dress.
 */
export const EXHIBIT_IDENTITIES = {
  freedos: {
    caseTint: '#b6ad98', accentTint: '#625f58', tintMix: 0.32,
    badge: '486 DX2', spec: 'DOS • 1994', kit: 'office90',
  },
  kolibrios: {
    caseTint: '#c4bca9', accentTint: '#70777a', tintMix: 0.32,
    badge: 'ATX 2004', spec: 'i586 • OPTICAL', kit: 'workstation',
  },
  toaruos: {
    caseTint: '#484c4d', accentTint: '#788084', tintMix: 0.6,
    badge: 'CORE 2', spec: 'x86 • 2011', kit: 'modern',
  },
  win311: {
    caseTint: '#bfb397', accentTint: '#536474', tintMix: 0.3,
    badge: '386 OFFICE', spec: 'VGA • 1992', kit: 'office90',
  },
  win95: {
    caseTint: '#cfb88e', accentTint: '#74695a', tintMix: 0.35,
    badge: 'PENTIUM', spec: 'FAMILY PC • 1995', kit: 'office90',
  },
  win98se: {
    caseTint: '#bda47f', accentTint: '#687174', tintMix: 0.4,
    badge: 'MMX ATX', spec: 'MULTIMEDIA • 1998', kit: 'office90',
  },
  win2000: {
    caseTint: '#afb2ae', accentTint: '#5f6668', tintMix: 0.4,
    badge: 'DESKPRO SFF', spec: 'MANAGED • 2000', kit: 'workstation',
  },
  winxp: {
    caseTint: '#adafac', accentTint: '#555b5e', tintMix: 0.34,
    badge: 'P4 8100', spec: 'SILVER • 2001', kit: 'workstation',
  },
  alpine: {
    caseTint: '#a5aaa8', accentTint: '#66706d', tintMix: 0.4,
    badge: 'OFFICE SFF', spec: 'REUSED • 2005', kit: 'workstation',
  },
  tinycore: {
    caseTint: '#c4aa7e', accentTint: '#756c58', tintMix: 0.4,
    badge: 'LEGACY 486', spec: '13" CRT • 2009', kit: 'office90',
  },
  ninefront: {
    caseTint: '#aea99d', accentTint: '#596b72', tintMix: 0.35,
    badge: 'PC TERMINAL', spec: '3-BUTTON • 2002', kit: 'workstation',
  },
  helenos: {
    caseTint: '#777a7b', accentTint: '#4d5559', tintMix: 0.42,
    badge: 'AMD64 LAB', spec: '5:4 LCD • 2006', kit: 'workstation',
  },
  solaris: {
    caseTint: '#aaa69b', accentTint: '#6d6878', tintMix: 0.4,
    badge: 'SPARC 5', spec: 'TYPE 5 • 1994', kit: 'workstation',
  },
  nt351: {
    caseTint: '#b6aa91', accentTint: '#656a6b', tintMix: 0.32,
    badge: 'PENTIUM WS', spec: 'PRO • 1995', kit: 'office90',
  },
  serenityos: {
    caseTint: '#3f4344', accentTint: '#858b88', tintMix: 0.62,
    badge: 'HOBBY BUILD', spec: 'x86-64 • 2018', kit: 'modern',
  },
  android: {
    caseTint: '#b9b5a7', accentTint: '#756c61', tintMix: 0.18,
    badge: 'SLIDER 2008', spec: '3.2" • QWERTY', kit: 'mobile',
  },
  postmarketos: {
    caseTint: '#4a4d4f', accentTint: '#607985', tintMix: 0.55,
    badge: 'MODULAR 2017', spec: 'REPAIRABLE', kit: 'mobile',
  },
  sailfishos: {
    caseTint: '#43494c', accentTint: '#587a7d', tintMix: 0.58,
    badge: 'SLAB 2013', spec: '4.5" • TOUCH', kit: 'mobile',
  },
  templeos: {
    caseTint: '#454849', accentTint: '#8a8372', tintMix: 0.6,
    badge: 'CORE 2 TOWER', spec: 'VGA CRT • 2013', kit: 'modern',
  },
  reactos: {
    caseTint: '#5b5e5f', accentTint: '#687886', tintMix: 0.48,
    badge: 'CORP SFF', spec: 'x86 • 2024', kit: 'modern',
  },
  haiku: {
    caseTint: '#404547', accentTint: '#5d7886', tintMix: 0.62,
    badge: 'AIRFLOW DIY', spec: 'x86-64 • 2024', kit: 'modern',
  },
  beos: {
    caseTint: '#d9d5c9', accentTint: '#3466a0', tintMix: 0.5,
    badge: 'BeBox', spec: 'x86 • 2000', kit: 'office90',
  },
  os2warp: {
    caseTint: '#aeb1aa', accentTint: '#536578', tintMix: 0.38,
    badge: 'PS/2 77', spec: 'BUSINESS • 1996', kit: 'office90',
  },
  aros: {
    caseTint: '#686a6c', accentTint: '#8a5450', tintMix: 0.45,
    badge: 'DIY 5:4', spec: 'x86 • 2024', kit: 'modern',
  },
  amigaos35: {
    caseTint: '#d3ccba', accentTint: '#b03a3a', tintMix: 0.42,
    badge: 'A4000 BIG BOX', spec: '68040 • 1999', kit: 'office90',
  },
  amix: {
    caseTint: '#cfc7b4', accentTint: '#7a8b99', tintMix: 0.42,
    badge: 'A3000UX', spec: '68030 • SVR4', kit: 'office90',
  },
  qnx: {
    caseTint: '#4b4f50', accentTint: '#8a514b', tintMix: 0.6,
    badge: 'FANLESS DEV', spec: 'I/O • 2010', kit: 'modern',
  },
  msdoswin1: {
    caseTint: '#c2ad83', accentTint: '#565551', tintMix: 0.4,
    badge: 'XT CLASS', spec: 'GREEN MONO', kit: 'office90',
  },
  c64: {
    caseTint: '#8b6746', accentTint: '#584333', tintMix: 0.45,
    badge: 'BREADBIN 64', spec: '64K • 1982', kit: 'eightBit',
  },
  atarist: {
    caseTint: '#aeb2b1', accentTint: '#596164', tintMix: 0.4,
    badge: '1040 STF', spec: '68000 • 1985', kit: 'eightBit',
  },
  apple2: {
    caseTint: '#c4ad7f', accentTint: '#66715d', tintMix: 0.42,
    badge: 'EDU MICRO', spec: '8-BIT • 1988', kit: 'eightBit',
  },
  amiga: {
    caseTint: '#d0c5aa', accentTint: '#7b5d56', tintMix: 0.3,
    badge: 'A500 CLASS', spec: '68000 • 1987', kit: 'eightBit',
  },
  win11: {
    caseTint: '#383d40', accentTint: '#526f82', tintMix: 0.65,
    badge: 'AIRFLOW PC', spec: '2021 • TPM', kit: 'modern',
  },
  riscos: {
    caseTint: '#b7b3a8', accentTint: '#607566', tintMix: 0.35,
    badge: 'A3000 CLASS', spec: 'ARM • EDU', kit: 'eightBit',
  },
  macos: {
    caseTint: '#a7aaa8', accentTint: '#5d6263', tintMix: 0.32,
    badge: 'ARM MINI', spec: '2024 • COMPACT', kit: 'modern',
  },
  redstar2: {
    caseTint: '#4b4d4b', accentTint: '#686d6b', tintMix: 0.6,
    badge: 'OEM TOWER', spec: 'INSTITUTIONAL', kit: 'workstation',
  },
  suse64: {
    caseTint: '#d9d4c3', accentTint: '#6ea339', tintMix: 0.38,
    badge: 'PENTIUM III', spec: '17" CRT • 2000', kit: 'workstation',
  },
  redstar3: {
    caseTint: '#55595b', accentTint: '#737a7b', tintMix: 0.52,
    badge: 'OEM SFF', spec: 'OFFICE • 2013', kit: 'modern',
  },
  amstradcpc: {
    caseTint: '#464a4b', accentTint: '#8d514b', tintMix: 0.45,
    badge: 'CPC 6128', spec: '128K • 1985', kit: 'eightBit',
  },
  nt4: {
    caseTint: '#b9b3a5', accentTint: '#566675', tintMix: 0.3,
    badge: 'PC 300 CLASS', spec: 'CORP • 1996', kit: 'office90',
  },
  openvms: {
    caseTint: '#aea895', accentTint: '#57716f', tintMix: 0.22,
    badge: 'VT TERMINAL', spec: 'DECWINDOWS', kit: 'workstation',
  },
  irix: {
    caseTint: '#c2c6c2', accentTint: '#2f7a72', tintMix: 0.34,
    badge: 'INDY R4600', spec: 'MIPS III • 1993', kit: 'workstation',
  },
  // The other Indy: same case, a colder blue-grey so the pair reads as two
  // machines rather than one exhibit drawn twice, and the badge carries the
  // only thing that actually differs — the processor.
  indyr4400: {
    caseTint: '#b6bec8', accentTint: '#3e6e9e', tintMix: 0.34,
    badge: 'INDY R4400', spec: 'MIPS III • 1993', kit: 'workstation',
  },
  mpf2: {
    caseTint: '#d8cfbb', accentTint: '#7d2e2a', tintMix: 0.38,
    badge: 'MPF-II', spec: '6502 • 1982', kit: 'eightBit',
  },
  // Same breadbin shell as c64, so the tint stays in that family; the cyan
  // accent is the VIC-20's own screen border.
  vic20: {
    caseTint: '#8b6746', accentTint: '#3fbfc7', tintMix: 0.45,
    badge: 'VIC-20', spec: '5K • 1980', kit: 'eightBit',
  },
  // Charcoal case, and the accent is the yellow the ROM suite draws in.
  plus4: {
    caseTint: '#4a4a4e', accentTint: '#c2cf5f', tintMix: 0.5,
    badge: 'PLUS/4', spec: '3-PLUS-1 • 1984', kit: 'eightBit',
  },
  // Commodore's late-8-bit beige, and the accent is the VDC's own 80-column
  // text colour rather than anything the gallery picked.
  c128: {
    caseTint: '#c6bda6', accentTint: '#7fd4c1', tintMix: 0.42,
    badge: 'C128', spec: '8502 + Z80 • 1985', kit: 'eightBit',
  },
  // Beige sheet metal, and the accent is the machine's own blue-white phosphor:
  // VICE's 2001-blueish palette, which is the 1977 machine's actual CRT.
  pet2001: {
    caseTint: '#b9b2a4', accentTint: '#aeb8f0', tintMix: 0.42,
    badge: 'PET 2001', spec: '8K • 1977', kit: 'eightBit',
  },
  // Commodore's office beige; the accent is the phosphor — #41ff00 is the
  // foreground of VICE's green.vpl, which is what xpet actually renders in.
  cbm8032: {
    caseTint: '#c8c0aa', accentTint: '#41ff00', tintMix: 0.42,
    badge: 'CBM 8032', spec: '32K • 80 COL • 1980', kit: 'eightBit',
  },
  // Cream business case; the accent is the 610's own phosphor, sampled from the
  // live station's framebuffer — a different green from the 8032's, which is part
  // of how the two are told apart.
  cbm2: {
    caseTint: '#cdc4ae', accentTint: '#55d544', tintMix: 0.42,
    badge: 'CBM 610', spec: '6509 • 1982', kit: 'eightBit',
  },
  // DEC's own magenta/purple operator-console panel, against the beige of the
  // terminal it drove.
  pdp11: {
    caseTint: '#cfc7b4', accentTint: '#9a4f96', tintMix: 0.38,
    badge: 'PDP-11/70', spec: '2.11BSD • 1975', kit: 'workstation',
  },
  // The accent is the VT11's phosphor: this is the only vector display in the
  // collection, and the only exhibit whose correct input device is a light pen.
  gt40: {
    caseTint: '#8e9491', accentTint: '#3be84b', tintMix: 0.38,
    badge: 'PDP-11/05 GT40', spec: 'VT11 VECTOR • 1973', kit: 'workstation',
  },
  // DEC cabinet grey-blue; the accent is the phosphor the station actually draws
  // in, not a colour the gallery chose.
  decos: {
    caseTint: '#5c6470', accentTint: '#33ff55', tintMix: 0.44,
    badge: 'PDP-11', spec: 'RT-11 / RSX / RSTS • 1970', kit: 'workstation',
  },
  // Sinclair black, and the accent is the first stripe of the rainbow flash
  // moulded into the case — which is also the machine's own non-bright red,
  // RGB 205,0,0, the colour MAME's spectrum driver actually puts on screen.
  zxspectrum: {
    caseTint: '#26262a', accentTint: '#cd0000', tintMix: 0.5,
    badge: 'ZX SPECTRUM', spec: '48K • 1982', kit: 'eightBit',
  },
  // Matt black plastic and the red ZX81 legend strip — the only machine here
  // that is not some shade of beige, grey or DEC blue.
  zx81: {
    caseTint: '#1c1a19', accentTint: '#d8462f', tintMix: 0.62,
    badge: 'ZX81', spec: '1 KB • MONO • 1981', kit: 'eightBit',
  },
  // Welsh-built beige, and the accent is the machine's own page colour — the
  // MC6847's bright green, sampled from this station's framebuffer at #30d200
  // rather than picked. It is the loudest screen in the collection and it is
  // Acorn's cream-beige, and the accent is the one flash of colour on the case:
  // the row of ten RED function keys along the top of the Model B's keyboard.
  // Not sampled from the screen, because the screen is white teletext on black.
  bbcmicro: {
    caseTint: '#d3cab4', accentTint: '#d8442f', tintMix: 0.36,
    badge: 'BBC MODEL B', spec: '6502A • 32K • 1981', kit: 'eightBit',
  },
  // what a visitor remembers about a Dragon.
  dragon32: {
    caseTint: '#c9c3b2', accentTint: '#30d200', tintMix: 0.4,
    badge: 'DRAGON 32', spec: '6809E • 32K • 1982', kit: 'eightBit',
  },
  // The Atmos is the darkest home micro in the collection — a matt black wedge
  // with a red stripe across the front, which is the accent. It shares its body
  // model with three beige wedges, so this tint is what stops it reading as one
  // of them.
  oricatmos: {
    caseTint: '#26262a', accentTint: '#d8402f', tintMix: 0.62,
    badge: 'ORIC ATMOS', spec: '48K • 1984', kit: 'eightBit',
  },
  // Anthracite plastic, the colour East German industrial equipment was
  // actually moulded in, and nothing like the beige of every Western machine
  // beside it. The accent is not chosen: a ppmhist of the station's own checkpoint
  // frame contains exactly TWO colours, RGB(0,0,160) and white, so #0000A0 is
  // literally the only colour this exhibit emits.
  kc854: {
    caseTint: '#3f4247', accentTint: '#0000a0', tintMix: 0.5,
    badge: 'KC 85/4', spec: 'CAOS 4.2 • 1988', kit: 'eightBit',
  },
  // Sinclair's matt black, and the accent is the QL's own screen: SuperBASIC
  // types in green on black in the command window, so that is the colour the
  // exhibit actually emits rather than one the gallery chose.
  sinclairql: {
    caseTint: '#2b2b2d', accentTint: '#2ee65a', tintMix: 0.5,
    badge: 'SINCLAIR QL', spec: '68008 QDOS • 1984', kit: 'eightBit',
  },
  // NeXT's matte-black magnesium, which is the whole visual identity of the
  // machine, and a neutral accent because the display itself is greyscale.
  nextstep: {
    caseTint: '#26262a', accentTint: '#8c8c8c', tintMix: 0.62,
    badge: 'NeXTcube', spec: '68040 • MEGAPIXEL • 1990', kit: 'workstation',
  },
  // Acorn's cream-beige again, because the case IS a BBC Micro — but the accent
  // is not bbcmicro's red function-key row, it is SAMPLED. A ppmhist of this
  // station's captured checkpoint contains exactly three colours: black, white, and pure
  // RGB(0,0,255), the reverse-video teletext field behind the ARM supervisor's
  // `A*` prompt. That blue is literally the only colour the exhibit emits, and
  // it is also the capture-time identity gate — a plain BBC Micro banner has zero
  // blue pixels — so it is the honest badge colour for "there is an ARM on the
  // other end of the Tube".
  armeval: {
    caseTint: '#d3cab4', accentTint: '#0000ff', tintMix: 0.36,
    badge: 'ARM EVALUATION SYSTEM', spec: 'ARM1 • 4M • 1986', kit: 'eightBit',
  },
  // PARC's pale office beige, and the accent is sampled rather than chosen:
  // ContrAlto lights a set pixel as 0xdffcff, a faintly blue-green white, which
  // is the only colour this exhibit emits. Everything else on its screen is the
  // absence of that.
  alto: {
    caseTint: '#cdc6b4', accentTint: '#dffcff', tintMix: 0.34,
    badge: 'XEROX ALTO II XM', spec: 'PAGE DISPLAY • 606x808 • 1973',
    kit: 'workstation',
  },
  // Xerox's own office grey-beige, a shade cooler and lighter than the PC
  // beiges around it. The accent is Xerox red — the only colour anywhere near
  // this machine, because the display itself emits exactly two: black and
  // white, with every mid-tone dithered out of them.
  daybreak: {
    caseTint: '#cdc8bd', accentTint: '#c8102e', tintMix: 0.34,
    badge: 'XEROX 6085', spec: 'MESA • VIEWPOINT • 1985', kit: 'workstation',
  },
  // The 8010 shipped in the earlier, warmer Xerox office grey — closer to putty
  // than the cooler shell the 6085 arrived in four years later. The accent is a
  // brighter Xerox red than its successor's, which also keeps the two Xerox
  // stations distinguishable at a glance on the rail.
  star: {
    caseTint: '#d5cec1', accentTint: '#d6001c', tintMix: 0.34,
    badge: 'XEROX 8010', spec: 'DANDELION • VIEWPOINT 2.0 • 1981', kit: 'workstation',
  },
  // Compaq's AlphaServer ivory-grey, a shade cooler than the PC beiges around
  // it; the accent is DEC's brand maroon — the one colour that says Digital —
  // on the machine running the last Windows DEC's architecture ever got.
  w2kalpha: {
    caseTint: '#b9bcc0', accentTint: '#862633', tintMix: 0.38,
    badge: 'ALPHASERVER ES40', spec: 'EV68 ALPHA • BUILD 2128 • 1999',
    kit: 'workstation',
  },
  // w2kalpha's sibling: the same AlphaServer ivory-grey pedestal, but where
  // that machine wears DEC's maroon for the Windows that never shipped, this
  // one takes Tru64's steel blue — DEC's own UNIX at home on its own iron.
  tru64: {
    caseTint: '#b9bcc0', accentTint: '#2f6a9b', tintMix: 0.38,
    badge: 'ALPHASERVER ES40', spec: 'EV68 ALPHA • TRU64 5.1B • 2003',
    kit: 'workstation',
  },
  // Apple's "platinum" — the warm grey every Mac wore from 1987 to the iMac.
  // A very low tintMix on purpose: the Quadra's whole visual identity IS the
  // uniform case colour, so an accent that reads as a stripe would be wrong.
  // The accent is the muted beige-grey of the case's own darker mouldings.
  macos753: {
    caseTint: '#cfccc2', accentTint: '#8c8a85', tintMix: 0.12,
    badge: 'MACINTOSH QUADRA 800', spec: '68040 25MHz • MAC OS 7.5.3 • 1996',
    kit: 'workstation',
  },
  // HP's Visualize B-class wore the mid-90s HP workstation two-tone: a light
  // warm-grey chassis with the darker slate-blue front bezel band, and the
  // "hp" badge in that same blue. Moderate tintMix so the band reads as HP's
  // stripe without swallowing the case.
  hpuxvue: {
    caseTint: '#c9c8c3', accentTint: '#5b7c99', tintMix: 0.34,
    badge: 'HP 9000 / 778 VISUALIZE B160L', spec: 'PA-7300LC 160MHz • HP-UX 10.20 • 1996',
    kit: 'workstation',
  },
  // aix432: IBM RS/6000 40P — IBM's warm beige with the AIX blue the registry
  // carries as this station's accent; the badge names the machine type because
  // "RS/6000" alone spans everything from this desktop to a rack.
  aix432: {
    caseTint: '#cfc9bb', accentTint: '#2f6ea8', tintMix: 0.32,
    badge: 'IBM RS/6000 40P (7020)', spec: 'PowerPC 601 66MHz • AIX 4.3.3 • 1994',
    kit: 'workstation',
  },
  // newsos: Sony NEWS — off-white Sony case with the muted violet NEWS-OS
  // accent this station carries in the registry; "SONY NEWS" badge.
  newsos: {
    caseTint: '#d6d3cc', accentTint: '#7a6f9b', tintMix: 0.3,
    badge: 'SONY NEWS NWS-3260', spec: 'R3000A 20MHz • NEWS-OS 4.1R • 1991',
    kit: 'workstation',
  },
  // sunos414: SPARCstation 5 — Sun's light warm-grey pizza box with the
  // purple Sun badge; the accent is the registry's OPEN LOOK violet.
  sunos414: {
    caseTint: '#cfcbc0', accentTint: '#7c3aed', tintMix: 0.28,
    badge: 'SUN SPARCSTATION 5', spec: 'microSPARC-II 70MHz • SUNOS 4.1.4 • 1994',
    kit: 'workstation',
  },
  // aux: the same platinum Quadra 800 as the macos753 station — Apple's warm
  // grey, so the same low tintMix applies (the uniform case colour IS the
  // identity). The accent is the slate of A/UX's X11 chrome rather than the
  // case mouldings, which is what tells the two Quadras apart on the floor.
  aux: {
    caseTint: '#cfccc2', accentTint: '#6f7f8c', tintMix: 0.14,
    badge: 'MACINTOSH QUADRA 800', spec: '68040 33MHz • A/UX 3.0.1 • 1993',
    kit: 'workstation',
  },
  // rhapsody: a plain beige Pentium II tower — Apple's Intel build ran on
  // whatever PC was on the desk. Muted NeXT-ish slate accent.
  rhapsody: {
    caseTint: '#d9d5c9', accentTint: '#7a8fb0', tintMix: 0.4,
    badge: 'Pentium II PC', spec: 'x86 • Rhapsody DR2 • 1998', kit: 'office90',
  },
  // chokanji: 超漢字 / B-right/V (BTRON3) — a period Japanese beige PC. Blue
  // accent echoes the kanji-watermark desktop; TRON badge for Sakamura's project.
  chokanji: {
    caseTint: '#cbc6b6', accentTint: '#2f6fb0', tintMix: 0.36,
    badge: 'TRON PC', spec: 'x86 • BTRON3 超漢字 • 2002', kit: 'office90',
  },
  // macos9: Power Mac G4 graphite — the smoke-grey polycarbonate of the 2001
  // towers, with the platinum-purple accent the registry carries. Moderate
  // tintMix: the G4's identity is the dark translucent front, not a stripe.
  macos9: {
    caseTint: '#9b9ca6', accentTint: '#9a9ad1', tintMix: 0.4,
    badge: 'POWER MAC G4', spec: 'PowerPC G4 • MAC OS 9.2.2 • 2001',
    kit: 'workstation',
  },
  // ravynos: an ordinary 2025 PC in modern aluminium-grey, with the slate accent
  // the registry carries. The badge names the hardware rather than the OS on
  // purpose — the desktop imitates a Mac, the machine underneath does not, and
  // the placard's whole subject is the gap between the two. Low-ish tintMix:
  // the identity of a minimal modern case is its uniform finish, not a stripe.
  ravynos: {
    caseTint: '#c6c8ca', accentTint: '#64748b', tintMix: 0.3,
    badge: 'x86-64 PC', spec: 'x86-64 • ravynOS 0.6.1 • 2025', kit: 'modern',
  },
  // bootos: an XT-class beige box (the OS is 8088-compatible by design) in
  // msdoswin1's warm case beige, with the registry's pale-blue accent. The
  // badge names the CPU class the code targets; the spec names the only
  // storage it has and the year it was written, four decades after the XT.
  bootos: {
    caseTint: '#c2ad83', accentTint: '#8ecae6', tintMix: 0.4,
    badge: 'XT 8088', spec: 'FLOPPY • 2019', kit: 'office90',
  },
  // pcgeos: a 386-class beige desktop with a colour VGA CRT — GEOS runs on a
  // 286 in 640 KB, but the 800x600 64K-colour VESA desktop this exhibit shows
  // wants a 1990s SuperVGA card, so the badge names the class that had one.
  // Registry orange accent (the canyon wallpaper's own colour).
  pcgeos: {
    caseTint: '#c9b995', accentTint: '#e08a3c', tintMix: 0.35,
    badge: '386 PC', spec: 'SVGA 800x600 • FreeDOS', kit: 'office90',
  },
  // slackware: a Pentium-class beige tower with a Cirrus SVGA card driving
  // 1024x768 in 16-bit colour. Registry teal accent (fvwm95's desktop colour).
  slackware: {
    caseTint: '#c9c2ae', accentTint: '#008080', tintMix: 0.35,
    badge: 'PENTIUM PC', spec: 'SVGA 1024x768 • 1997', kit: 'office90',
  },
  // pcbsd: a 2008 beige-going-grey office PC running FreeBSD 6.3 + KDE 3.5 at
  // 1024x768 on the vesa driver. Registry red accent (the PC-BSD/BSD daemon red).
  pcbsd: {
    caseTint: '#b9b7ae', accentTint: '#c8102e', tintMix: 0.4,
    badge: 'OFFICE PC', spec: 'x86 • 2008', kit: 'modern',
  },
  // ubuntu: a 2004 beige/black OEM minitower with a CRT — the class of PC the
  // live CD was made for. Registry accent: Ubuntu orange.
  ubuntu: {
    caseTint: '#c7c0b0', accentTint: '#dd4814', tintMix: 0.32,
    badge: 'OEM TOWER', spec: 'LIVE CD • 2004', kit: 'workstation',
  },
  // netbsd14: a late-1990s beige Pentium-class clone with a Cirrus SVGA card,
  // the kind of box NetBSD's i386 port was installed on with sysinst. The accent
  // is the registry's NetBSD flag orange.
  netbsd14: {
    caseTint: '#cfc6ae', accentTint: '#f26522', tintMix: 0.35,
    badge: 'PENTIUM PC', spec: 'CIRRUS GD5446 • NETBSD 1.4.1 • 1999', kit: 'office90',
  },
} as const satisfies Record<keyof typeof ASSEMBLIES_BY_TILE, ExhibitIdentity>;

const FALLBACK_IDENTITY: ExhibitIdentity = {
  caseTint: '#bdb6a5',
  accentTint: '#666c6c',
  tintMix: 0.2,
  badge: 'COMPUTER',
  kit: 'workstation',
};

export function identityForTile(tileId: string): ExhibitIdentity {
  return EXHIBIT_IDENTITIES[tileId as keyof typeof EXHIBIT_IDENTITIES]
    ?? FALLBACK_IDENTITY;
}

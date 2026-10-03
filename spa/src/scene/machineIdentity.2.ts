// GENERATED shard 2/3 of EXHIBIT_IDENTITIES — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./machineIdentity.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { ExhibitIdentity } from './machineIdentity';

export const EXHIBIT_IDENTITIES_2 = {
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
  // The other Indy: same case, a colder blue-grey so the pair reads as two
  // machines rather than one exhibit drawn twice, and the badge carries the
  // only thing that actually differs — the processor.
  indyr4400: {
    caseTint: '#b6bec8', accentTint: '#3e6e9e', tintMix: 0.34,
    badge: 'INDY R4400', spec: 'MIPS III • 1993', kit: 'workstation',
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
  // The 8010 shipped in the earlier, warmer Xerox office grey — closer to putty
  // than the cooler shell the 6085 arrived in four years later. The accent is a
  // brighter Xerox red than its successor's, which also keeps the two Xerox
  // stations distinguishable at a glance on the rail.
  star: {
    caseTint: '#d5cec1', accentTint: '#d6001c', tintMix: 0.34,
    badge: 'XEROX 8010', spec: 'DANDELION • VIEWPOINT 2.0 • 1981', kit: 'workstation',
  },
  // Xerox's own office grey-beige, a shade cooler and lighter than the PC
  // beiges around it. The accent is Xerox red — the only colour anywhere near
  // this machine, because the display itself emits exactly two: black and
  // white, with every mid-tone dithered out of them.
  daybreak: {
    caseTint: '#cdc8bd', accentTint: '#c8102e', tintMix: 0.34,
    badge: 'XEROX 6085', spec: 'MESA • VIEWPOINT • 1985', kit: 'workstation',
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
  beos: {
    caseTint: '#d9d5c9', accentTint: '#3466a0', tintMix: 0.5,
    badge: 'BeBox', spec: 'x86 • 2000', kit: 'office90',
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
  amigaos35: {
    caseTint: '#d3ccba', accentTint: '#b03a3a', tintMix: 0.42,
    badge: 'A4000 BIG BOX', spec: '68040 • 1999', kit: 'office90',
  },
  // aix432: IBM RS/6000 40P — IBM's warm beige with the AIX blue the registry
  // carries as this station's accent; the badge names the machine type because
  // "RS/6000" alone spans everything from this desktop to a rack.
  aix432: {
    caseTint: '#cfc9bb', accentTint: '#2f6ea8', tintMix: 0.32,
    badge: 'IBM RS/6000 40P (7020)', spec: 'PowerPC 601 66MHz • AIX 4.3.3 • 1994',
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
  amix: {
    caseTint: '#cfc7b4', accentTint: '#7a8b99', tintMix: 0.42,
    badge: 'A3000UX', spec: '68030 • SVR4', kit: 'office90',
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
} as const satisfies Record<string, ExhibitIdentity>;

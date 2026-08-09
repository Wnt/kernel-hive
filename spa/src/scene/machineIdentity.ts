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
  os2warp: {
    caseTint: '#aeb1aa', accentTint: '#536578', tintMix: 0.38,
    badge: 'PS/2 77', spec: 'BUSINESS • 1996', kit: 'office90',
  },
  aros: {
    caseTint: '#686a6c', accentTint: '#8a5450', tintMix: 0.45,
    badge: 'DIY 5:4', spec: 'x86 • 2024', kit: 'modern',
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
  // live tile's framebuffer — a different green from the 8032's, which is part
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
  // DEC cabinet grey-blue; the accent is the phosphor the tile actually draws
  // in, not a colour the gallery chose.
  decos: {
    caseTint: '#5c6470', accentTint: '#33ff55', tintMix: 0.44,
    badge: 'PDP-11', spec: 'RT-11 / RSX / RSTS • 1970', kit: 'workstation',
  },
  // Welsh-built beige, and the accent is the machine's own page colour — the
  // MC6847's bright green, sampled from this tile's framebuffer at #30d200
  // rather than picked. It is the loudest screen in the collection and it is
  // what a visitor remembers about a Dragon.
  dragon32: {
    caseTint: '#c9c3b2', accentTint: '#30d200', tintMix: 0.4,
    badge: 'DRAGON 32', spec: '6809E • 32K • 1982', kit: 'eightBit',
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

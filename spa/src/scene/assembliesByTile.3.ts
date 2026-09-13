// GENERATED shard 3/3 of ASSEMBLIES_BY_TILE — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./assembliesByTile.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { Assembly } from './machines';

export const ASSEMBLIES_BY_TILE_3 = {
  // slackware: a 1997 beige mini-tower under a colour SVGA CRT, with the
  // serial mouse the X server is told about (relative). Same tower family as
  // tinycore, the other small-Linux desktop in the hall.
  slackware: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
  // netbsd14: a 1999 beige PC clone under a colour SVGA CRT — same case family
  // as pcgeos, with the PS/2 mouse and 101-key board the X server is driven by.
  netbsd14: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  // openbsd: a 2020s small-form-factor amd64 box, but on a wider flat panel than
  // alpine's desk (same case family, distinct signature) — USB tablet pointer,
  // 101-key board.
  redhat62: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseC',
  },
  openbsd: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'lcdC',
    keyboard: 'keyboardA', mouse: 'paramMouseD',
  },
  // freebsd411: a 2005 beige Pentium-4-era mini-tower under a colour SVGA CRT,
  // with the PS/2 mouse and 101-key board KDE 3.3.2 on XFree86 4.4.0 is driven
  // by — a tower, not the flat 1990 desktop case pcgeos sits in.
  freebsd411: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtD',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  debian22: {
    kind: 'towerSetup', body: 'towerA', monitor: 'paramCrt',
    keyboard: 'keyboardB', mouse: 'paramMouseB',
  },
  suse64: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtA',
    keyboard: 'keyboardB', mouse: 'paramMouseC',
  },
  apple2e: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtD',
    mouse: 'paramMouseD',
  },
  samcoupe: {
    kind: 'homeMicro', body: 'amstradCpc', monitor: 'homeCrtD',
    },
  atari800xl: {
    kind: 'homeMicro', body: 'c64A', monitor: 'homeCrtC',
  },
  a1000: {
    kind: 'towerSetup', body: 'pizzaBoxB', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  a3000: {
    kind: 'towerSetup', body: 'paramTower', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  medley: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  sculpt: {
    kind: 'towerSetup', body: 'towerC', monitor: 'lcdB',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  lisa: {
    kind: 'pizzaBox', body: 'pizzaBoxB', monitor: 'compactA',
    keyboard: 'keyboardA', mouse: 'paramMouseC',
  },
  domainos: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  fmtowns: {
    kind: 'towerSetup', body: 'towerE', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
  oberon: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtD',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  magiccap: {
    kind: 'towerSetup', body: 'pizzaBoxB', monitor: 'crtC',
    keyboard: 'keyboardB', mouse: 'paramMouseB',
  },
  perq: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtF',
    keyboard: 'keyboardD', mouse: 'paramMouseB',
  },
  vision: {
    kind: 'pizzaBox', body: 'pizzaBoxD', monitor: 'crtD',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  minix2: {
    kind: 'pizzaBox', body: 'towerE', monitor: 'crtF',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // macsys1 — the Macintosh 128K is an ALL-IN-ONE: the 9-inch tube, the 68000 and
  // the floppy drive are one beige box, so the assembly carries NO separate body.
  // compactA alone is the machine (scaffolded as compactA|compactA, which put two
  // screen-bearing models in one assembly and failed the one-screen invariant).
  // keyboardG is the smallest board in the kit, the honest silhouette for the tiny
  // M0110; paramMouseF is the one-button mouse.
  macsys1: {
    kind: 'homeMicro', monitor: 'compactA',
    mouse: 'paramMouseF',
    keyboard: 'keyboardG',
  },
} as const satisfies Record<string, Assembly>;

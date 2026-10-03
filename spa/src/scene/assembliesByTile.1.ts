// GENERATED shard 1/3 of ASSEMBLIES_BY_TILE — rows in registry lineup order, written by
// scripts/dev/spa-scene-rows.py (the index is ./assembliesByTile.ts). Edit a ROW here if you must;
// never the layout, and never add a row by hand — the rebuild places it.
import type { Assembly } from './machines';

export const ASSEMBLIES_BY_TILE_1 = {
  freedos: {
    kind: 'pizzaBox', body: 'pizzaBoxB', monitor: 'crtA',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  kolibrios: {
    kind: 'towerSetup', body: 'paramTower', monitor: 'crtC',
    keyboard: 'keyboardB', mouse: 'paramMouseD',
  },
  toaruos: {
    kind: 'towerSetup', body: 'towerE', monitor: 'lcdB',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  win311: {
    kind: 'pizzaBox', body: 'pizzaBoxB', monitor: 'paramCrt',
    keyboard: 'keyboardB', mouse: 'paramMouseA',
  },
  win95: {
    kind: 'towerSetup', body: 'towerA', monitor: 'paramCrt',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
  win98se: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardB', mouse: 'paramMouseB',
  },
  win2000: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseD',
  },
  winxp: {
    kind: 'towerSetup', body: 'towerD', monitor: 'lcdA',
    keyboard: 'keyboardE', mouse: 'paramMouseD',
  },
  alpine: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'lcdA',
    keyboard: 'keyboardA', mouse: 'paramMouseD',
  },
  tinycore: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtA',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
  ninefront: {
    kind: 'towerSetup', body: 'paramTower', monitor: 'crtC',
    keyboard: 'paramKeyboard', mouse: 'paramMouseD',
  },
  helenos: {
    kind: 'towerSetup', body: 'towerD', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  solaris: {
    kind: 'pizzaBox', body: 'pizzaBoxC', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  nt351: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'paramKeyboard', mouse: 'paramMouseB',
  },
  serenityos: {
    kind: 'towerSetup', body: 'modernD', monitor: 'lcdB',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  android: { kind: 'phoneDock', body: 'phoneA' },
  postmarketos: { kind: 'phoneDock', body: 'phoneC' },
  sailfishos: { kind: 'phoneDock', body: 'phoneB' },
  templeos: {
    kind: 'towerSetup', body: 'towerE', monitor: 'paramCrt',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  reactos: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  haiku: {
    kind: 'towerSetup', body: 'modernTower', monitor: 'lcdB',
    keyboard: 'keyboardG', mouse: 'paramMouseE',
  },
  os2warp: {
    kind: 'pizzaBox', body: 'pizzaBoxD', monitor: 'crtC',
    keyboard: 'paramKeyboard', mouse: 'paramMouseB',
  },
  aros: {
    kind: 'towerSetup', body: 'towerD', monitor: 'lcdC',
    keyboard: 'keyboardE', mouse: 'paramMouseE',
  },
  qnx: {
    kind: 'industrial', body: 'industrialBox', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  msdoswin1: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtD',
    keyboard: 'keyboardD', mouse: 'paramMouseA',
  },
  c64: {
    kind: 'homeMicro', body: 'c64A', monitor: 'homeCrtB', mouse: 'paramMouseA',
  },
  atarist: {
    kind: 'homeMicro', body: 'atariSt', monitor: 'homeCrtC', mouse: 'paramMouseA',
  },
  apple2: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtD',
    mouse: 'paramMouseC',
  },
  amiga: {
    kind: 'homeMicro', body: 'amigaA', monitor: 'homeCrtA', mouse: 'paramMouseA',
  },
  win11: {
    kind: 'towerSetup', body: 'modernTower', monitor: 'lcdB',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  riscos: {
    kind: 'homeMicro', body: 'acornA3000', monitor: 'crtA', mouse: 'paramMouseG',
  },
  macos: {
    kind: 'pizzaBox', body: 'modernMini', monitor: 'lcdB',
    keyboard: 'keyboardG', mouse: 'paramMouseF',
  },
  redstar2: {
    kind: 'towerSetup', body: 'towerE', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
  redstar3: {
    kind: 'pizzaBox', body: 'pizzaBoxE', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseD',
  },
  amstradcpc: {
    kind: 'homeMicro', body: 'amstradCpc', monitor: 'homeCrtE',
  },
  nt4: {
    kind: 'pizzaBox', body: 'pizzaBoxF', monitor: 'paramCrt',
    keyboard: 'keyboardB', mouse: 'paramMouseB',
  },
  // The later registry addition remains a distinct DEC-terminal signature.
  openvms: { kind: 'terminal', body: 'terminalA' },
  // SGI Indy: same small blue Unix pizza-box family as solaris, paired with the
  // one unused compact CRT so the signature stays distinct without a new asset.
  irix: {
    kind: 'pizzaBox', body: 'pizzaBoxC', monitor: 'compactA',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // No mouse: the MPF-II has no pointing device and no port for one, so the
  // bench carries the machine and a television and nothing else.
  mpf2: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtD',
  },
  // The VIC-20 shares the breadbin shell with the c64 station because the real
  // machines did: the Commodore 64 reused the VIC-20's case, keyboard and port
  // layout wholesale. No mouse — the VIC-20's only other input was a joystick.
  vic20: {
    kind: 'homeMicro', body: 'c64A', monitor: 'homeCrtD',
  },
} as const satisfies Record<string, Assembly>;

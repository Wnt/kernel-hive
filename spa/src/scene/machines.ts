// ============================================================================
//  SCENE V2 — project-original parametric machine models
//  ---------------------------------------------------------------------------
//  Each entry declares its real-world target size; NormalizedModel measures
//  the file's actual bounds at load and rescales/grounds it, so authoring
//  scale never matters.
// ============================================================================

export interface MachineModel {
  url: string;
  /** Real-world height in meters the model gets scaled to. */
  targetH: number;
  /** When set, scale by WIDTH instead (flat things: keyboards, mice, cases). */
  targetW?: number;
  /**
   * Documented body width represented by targetW when cables, docks, mounting
   * ears, or detached peripherals make the complete GLB bounds wider.
   */
  sourceW?: number;
  /** Extra yaw (radians) if the model's "front" isn't -Z…+Z aligned. */
  yaw?: number;
  /** True when the file already includes monitor+case+peripherals. */
  combo?: boolean;
  /**
   * Viewable glass in normalized-model space. The plane faces +Z; rot tilts
   * it around local X (radians). Values include the model's yaw/scale/ground
   * transform, so screen placement never depends on source authoring units.
   */
  screen?: {
    center: [number, number, number];
    size: [number, number];
    rot?: number;
    /** Local-normal offset from a curved glass panel's rim to its apex. */
    surfaceOffset?: number;
  };
}

const BASE = '/assets/models/v2';

export const MODELS = {
  c64A: {
    url: `${BASE}/param/c64-a.glb`, targetH: 0.075, targetW: 0.404,
  },
  amigaA: {
    url: `${BASE}/param/amiga-a.glb`, targetH: 0.065, targetW: 0.47,
  },
  eightBitWedgeA: {
    url: `${BASE}/param/8bitwedge-a.glb`, targetH: 0.076, targetW: 0.4,
  },
  homeCrtA: {
    url: `${BASE}/param/homecrt-a.glb`, targetH: 0.32,
    screen: {
      center: [0, 0.172, 0.144], size: [0.264, 0.198], surfaceOffset: 0.016,
    },
  },
  homeCrtB: {
    url: `${BASE}/param/homecrt-b.glb`, targetH: 0.324,
    screen: {
      center: [-0.022, 0.19, 0.158], size: [0.25, 0.188], surfaceOffset: 0.016,
    },
  },
  homeCrtC: {
    url: `${BASE}/param/homecrt-c.glb`, targetH: 0.307,
    screen: {
      center: [-0.01, 0.172, 0.088], size: [0.236, 0.177], surfaceOffset: 0.026,
    },
  },
  homeCrtD: {
    url: `${BASE}/param/homecrt-d.glb`, targetH: 0.27,
    screen: {
      center: [-0.018, 0.145, 0.111], size: [0.25, 0.188], surfaceOffset: 0.019,
    },
  },
  homeCrtE: {
    url: `${BASE}/param/homecrt-e.glb`, targetH: 0.34,
    screen: {
      center: [-0.01, 0.205, 0.129], size: [0.274, 0.206], surfaceOffset: 0.014,
    },
  },
  lcdA: {
    url: `${BASE}/param/lcd-a.glb`, targetH: 0.3467,
    screen: { center: [0, 0.205, 0.067], size: [0.304, 0.228] },
  },
  lcdB: {
    url: `${BASE}/param/lcd-b.glb`, targetH: 0.398,
    screen: { center: [0, 0.245, 0.026], size: [0.527, 0.297] },
  },
  lcdC: {
    url: `${BASE}/param/lcd-c.glb`, targetH: 0.384,
    screen: { center: [0, 0.227, 0.051], size: [0.338, 0.27] },
  },
  compactA: {
    url: `${BASE}/param/compact-a.glb`, targetH: 0.296,
    screen: {
      center: [0, 0.194, 0.115], size: [0.18, 0.135], surfaceOffset: 0.018,
    },
  },
  keyboardA: { url: `${BASE}/param/keyboard-a.glb`, targetH: 0.04, targetW: 0.46 },
  keyboardB: { url: `${BASE}/param/keyboard-b.glb`, targetH: 0.044, targetW: 0.466 },
  keyboardD: { url: `${BASE}/param/keyboard-d.glb`, targetH: 0.038, targetW: 0.485 },
  keyboardE: { url: `${BASE}/param/keyboard-e.glb`, targetH: 0.025, targetW: 0.458 },
  keyboardF: { url: `${BASE}/param/keyboard-f.glb`, targetH: 0.024, targetW: 0.442 },
  keyboardG: { url: `${BASE}/param/keyboard-g.glb`, targetH: 0.016, targetW: 0.279 },
  keyboardH: { url: `${BASE}/param/keyboard-h.glb`, targetH: 0.044, targetW: 0.51 },
  towerA: { url: `${BASE}/param/tower-a.glb`, targetH: 0.38 },
  paramTower: { url: `${BASE}/param/tower-b.glb`, targetH: 0.42 },
  towerC: { url: `${BASE}/param/tower-c.glb`, targetH: 0.48 },
  towerD: { url: `${BASE}/param/tower-d.glb`, targetH: 0.491 },
  towerE: { url: `${BASE}/param/tower-e.glb`, targetH: 0.377 },
  crtA: {
    url: `${BASE}/param/crt-a.glb`, targetH: 0.305,
    screen: {
      center: [0, 0.1855, 0.1615], size: [0.244, 0.183], surfaceOffset: 0.01,
    },
  },
  paramCrt: {
    url: `${BASE}/param/crt-b.glb`, targetH: 0.325,
    screen: {
      center: [0, 0.2027, 0.1649], size: [0.2581, 0.1936], surfaceOffset: 0.009,
    },
  },
  crtC: {
    url: `${BASE}/param/crt-c.glb`, targetH: 0.343,
    screen: {
      center: [0, 0.2132, 0.1778], size: [0.2721, 0.2036], surfaceOffset: 0.007,
    },
  },
  crtD: {
    url: `${BASE}/param/crt-d.glb`, targetH: 0.28,
    screen: {
      center: [-0.025, 0.157, 0.122], size: [0.244, 0.183], surfaceOffset: 0.03,
    },
  },
  crtE: {
    url: `${BASE}/param/crt-e.glb`, targetH: 0.426,
    screen: {
      center: [0, 0.258, 0.174], size: [0.32, 0.24], surfaceOffset: 0.027,
    },
  },
  paramKeyboard: { url: `${BASE}/param/keyboard-c.glb`, targetH: 0.048, targetW: 0.492 },
  pizzaBoxA: { url: `${BASE}/param/pizzabox-a.glb`, targetH: 0.147, targetW: 0.5 },
  pizzaBoxB: { url: `${BASE}/param/pizzabox-b.glb`, targetH: 0.074, targetW: 0.31 },
  pizzaBoxC: { url: `${BASE}/param/pizzabox-c.glb`, targetH: 0.071, targetW: 0.409 },
  pizzaBoxD: { url: `${BASE}/param/pizzabox-d.glb`, targetH: 0.115, targetW: 0.36 },
  pizzaBoxE: { url: `${BASE}/param/pizzabox-e.glb`, targetH: 0.09, targetW: 0.318 },
  pizzaBoxF: { url: `${BASE}/param/pizzabox-f.glb`, targetH: 0.128, targetW: 0.45 },
  terminalA: {
    url: `${BASE}/param/terminal-a.glb`, targetH: 0.362, targetW: 0.4572, sourceW: 0.4572,
    screen: {
      center: [-0.026, 0.22, 0.0206], size: [0.292, 0.219], surfaceOffset: 0.008,
    },
  },
  terminalB: {
    url: `${BASE}/param/terminal-b.glb`, targetH: 0.283, targetW: 0.333, sourceW: 0.333,
    screen: {
      center: [0, 0.221, 0.0555],
      size: [0.232, 0.174],
      rot: -0.0698,
      surfaceOffset: 0.008,
    },
  },
  terminalC: {
    url: `${BASE}/param/terminal-c.glb`, targetH: 0.32, targetW: 0.36, sourceW: 0.36,
    screen: {
      center: [0, 0.2052, 0.0918],
      size: [0.235, 0.15],
      rot: -0.2269,
      surfaceOffset: 0.007,
    },
  },
  paramMouseA: {
    url: `${BASE}/param/mouse-a.glb`, targetH: 0.04, targetW: 0.063, sourceW: 0.063, yaw: Math.PI,
  },
  paramMouseB: {
    url: `${BASE}/param/mouse-b.glb`, targetH: 0.038, targetW: 0.06, sourceW: 0.06, yaw: Math.PI,
  },
  paramMouseC: {
    url: `${BASE}/param/mouse-c.glb`, targetH: 0.0345, targetW: 0.07, sourceW: 0.07, yaw: Math.PI,
  },
  paramMouseD: {
    url: `${BASE}/param/mouse-d.glb`, targetH: 0.039, targetW: 0.068, sourceW: 0.068, yaw: Math.PI,
  },
  paramMouseE: {
    url: `${BASE}/param/mouse-e.glb`, targetH: 0.038, targetW: 0.062, sourceW: 0.062, yaw: Math.PI,
  },
  paramMouseF: {
    url: `${BASE}/param/mouse-f.glb`, targetH: 0.022, targetW: 0.057, sourceW: 0.057, yaw: Math.PI,
  },
  paramMouseG: {
    url: `${BASE}/param/mouse-g.glb`, targetH: 0.05, targetW: 0.08, sourceW: 0.08, yaw: Math.PI,
  },
  phoneA: {
    url: `${BASE}/param/phone-a.glb`, targetH: 0.1177, targetW: 0.0605, sourceW: 0.0605,
    screen: { center: [0, 0.1069, 0.0018], size: [0.0404, 0.0544], rot: -0.3491 },
  },
  phoneB: {
    url: `${BASE}/param/phone-b.glb`, targetH: 0.1379, targetW: 0.0692, sourceW: 0.0692,
    screen: { center: [0, 0.0961, 0.0042], size: [0.0596, 0.1124], rot: -0.4189 },
  },
  phoneC: {
    url: `${BASE}/param/phone-c.glb`, targetH: 0.14, targetW: 0.079, sourceW: 0.079,
    screen: { center: [-0.0023, 0.0908, 0.0048], size: [0.0584, 0.1024], rot: -0.3491 },
  },
  modernTower: { url: `${BASE}/param/modern-a.glb`, targetH: 0.46 },
  modernMini: { url: `${BASE}/param/modern-b.glb`, targetH: 0.042, targetW: 0.18 },
  industrialBox: {
    url: `${BASE}/param/modern-c.glb`, targetH: 0.0675, targetW: 0.22, sourceW: 0.22,
  },
  modernD: { url: `${BASE}/param/modern-d.glb`, targetH: 0.46 },
  atariSt: { url: `${BASE}/param/atarist.glb`, targetH: 0.06, targetW: 0.47 },
  amstradCpc: { url: `${BASE}/param/amstradcpc.glb`, targetH: 0.06, targetW: 0.53 },
  acornA3000: { url: `${BASE}/param/acorn.glb`, targetH: 0.064, targetW: 0.49 },
  officeChairA: { url: `${BASE}/param/props-office-chair-a.glb`, targetH: 0.899 },
  officeChairB: { url: `${BASE}/param/props-office-chair-b.glb`, targetH: 0.899 },
  chairTubularRed: {
    url: `${BASE}/param/props-chair-tubular-red.glb`, targetH: 0.82,
  },
  chairPlywoodOrange: {
    url: `${BASE}/param/props-chair-plywood-orange.glb`, targetH: 0.79,
  },
  chairTaskBlue: {
    url: `${BASE}/param/props-chair-task-blue.glb`, targetH: 0.88,
  },
  deskPedestalWood: {
    url: `${BASE}/param/props-desk-pedestal-wood.glb`, targetH: 0.72,
  },
  cableRun: {
    url: `${BASE}/param/props-cable-run.glb`, targetH: 0.76,
  },
  shelfUnit: {
    url: `${BASE}/param/props-shelf-unit.glb`, targetH: 1.899,
  },
  deskClutter: {
    url: `${BASE}/param/props-desk-clutter.glb`,
    targetH: 0.117, targetW: 0.39, sourceW: 0.39,
  },
} satisfies Record<string, MachineModel>;

export type ModelKey = keyof typeof MODELS;

// Phones retain their authored real-world dimensions in MODELS. The repairable
// phoneC handset needs a larger museum-display dock presentation to read from
// the rail and in the diagnostic lineup.
export const PHONE_DOCK_DISPLAY_SCALE: Partial<Record<ModelKey, number>> = {
  phoneC: 1.65,
};

export const MONITOR_MODEL_KEYS = [
  'homeCrtA', 'homeCrtB', 'homeCrtC', 'homeCrtD', 'homeCrtE',
  'lcdA', 'lcdB', 'lcdC', 'compactA',
  'crtA', 'paramCrt', 'crtC', 'crtD', 'crtE',
  'terminalA', 'terminalB', 'terminalC',
] as const satisfies readonly ModelKey[];

// Assembly archetypes: which parts sit on the desk and where.
type AssemblyKind =
  | 'combo' // a single all-inclusive set model
  | 'allInOne' // compact machine + keyboard + mouse
  | 'pizzaBox' // flat case with monitor on top + keyboard + mouse
  | 'towerSetup' // tower beside/under the desk + monitor + keyboard + mouse
  | 'homeMicro' // flat home computer with a CRT behind it on the desk
  | 'terminal' // one terminal GLB, including its own keyboard when detached
  | 'phoneDock' // one handset GLB with its integrated museum dock
  | 'industrial' // small embedded host beside a conventional monitor
  | 'covered'; // dust-covered placeholder (kept as authentic dressing)

export interface Assembly {
  kind: AssemblyKind;
  combo?: ModelKey;
  body?: ModelKey; // all-in-one machine / flat case / tower
  monitor?: ModelKey;
  keyboard?: ModelKey;
  mouse?: ModelKey;
}

// Every registry lineup entry is bound explicitly. Keep entries that do not
// fit in today's 22 slots here so a future hall expansion requires no modeling
// fallback or index-cycle changes.
export const ASSEMBLIES_BY_TILE = {
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
  // The VIC-20 shares the breadbin shell with the c64 tile because the real
  // machines did: the Commodore 64 reused the VIC-20's case, keyboard and port
  // layout wholesale. No mouse — the VIC-20's only other input was a joystick.
  vic20: {
    kind: 'homeMicro', body: 'c64A', monitor: 'homeCrtD',
  },
  // The Plus/4 shares nothing with the breadbin: a charcoal wedge with cream
  // keys, not beige. Same wedge silhouette as apple2/mpf2, distinguished by its
  // identity tint below rather than by a bespoke asset.
  plus4: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtB',
  },
  // The C128 is not a breadbin: a wide, low wedge with a full numeric keypad,
  // closer in silhouette to the Amiga 500 than to the c64 tile's case. amigaA is
  // the widest wedge body in the kit, so it carries the machine; the identity
  // tint below is what keeps it from reading as an Amiga. Keyboard-only.
  c128: {
    kind: 'homeMicro', body: 'amigaA', monitor: 'homeCrtC',
  },
  // The PET 2001 is one sealed object — a 9-inch CRT, a chiclet keyboard and a
  // cassette deck in a single sheet-metal trapezoid — so it takes a terminal
  // assembly rather than a body with a separate monitor behind it.
  pet2001: { kind: 'terminal', body: 'terminalC' },
  // The CBM 8032 is not a home micro either: an all-in-one steel case with a
  // 12-inch green monitor and a business keyboard built in. No mouse — the PET
  // had no pointing device and no port for one.
  cbm8032: { kind: 'terminal', body: 'terminalB' },
  // The CBM 610 is the deliberate contrast to the 8032 above: a low-profile
  // business box with the keyboard in the chassis and a DETACHED office CRT on
  // top. The two machines stream near-identical green 80-column text, so the
  // 3D exhibit is what has to tell them apart — hence a different silhouette
  // and a boxy office monitor rather than another all-in-one.
  cbm2: {
    kind: 'homeMicro', body: 'amigaA', monitor: 'crtA',
  },
  // The three DEC minicomputers are RACK PLUS TERMINAL, not bare glass TTYs.
  // That is both historically right — a PDP-11 filled cabinets and you sat at a
  // VT in front of it — and forced: every exhibit needs a distinct hardware
  // signature, `terminalA/B/C` are already taken by openvms, cbm8032 and
  // pet2001, and three identical terminals would read as one exhibit cloned
  // three times. Each takes a different cabinet so they stay distinct from each
  // other too.
  //
  // openvms deliberately stays a bare terminal: it is x86 VMS on modern iron,
  // with no rack to draw.
  pdp11: { kind: 'towerSetup', body: 'towerC', monitor: 'terminalA' },
  // The GT40 is really one cabinet — a PDP-11/05, a VT11 and the CRT above it —
  // so the tower stands in for that cabinet and the round CRT for the vector
  // tube. No mouse: the pointing device was a LIGHT PEN, which the kit has no
  // model for, and which is the whole point of this exhibit.
  gt40: { kind: 'towerSetup', body: 'towerE', monitor: 'crtE' },
  // Three DEC operating systems behind one chooser, on the biggest rack.
  decos: { kind: 'towerSetup', body: 'towerD', monitor: 'terminalA' },
  // The Dragon 32 is a chunky sloped wedge with the keyboard in the lid and a
  // television behind it — the same silhouette family as apple2/mpf2/plus4, so
  // it takes the shared wedge body and the one home CRT that wedge has not yet
  // been paired with (homeCrtA is otherwise only under the Amiga's separate
  // desktop case). No keyboard and no mouse: the keys are in the machine, and
  // the Dragon's only other port took a pair of analogue joysticks.
  dragon32: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtA',
  },
} as const satisfies Record<string, Assembly>;

export function assemblyForTile(tileId: string): Assembly {
  return ASSEMBLIES_BY_TILE[tileId as keyof typeof ASSEMBLIES_BY_TILE] ?? { kind: 'covered' };
}

export function hasIntegratedKeyboard(assembly: Assembly): boolean {
  return assembly.kind === 'combo'
    || assembly.kind === 'homeMicro'
    || assembly.kind === 'terminal';
}

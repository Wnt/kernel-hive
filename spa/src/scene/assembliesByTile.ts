// =====================================================================  },
//  ASSEMBLIES_BY_TILE — split out of machines.ts (ts-src 600-line hard cap).
//  ---------------------------------------------------------------------------
//  Isolating this table also removes a recurring merge hazard: every new
//  tile appends to ASSEMBLIES_BY_TILE at the same spot, so two parallel tile
//  branches conflicted here on every merge while it lived inside the far
//  busier machines.ts. See machines.ts for MachineModel/MODELS, the
//  AssemblyKind/Assembly types, and assemblyForTile/hasIntegratedKeyboard.
// =====================================================================  },

import type { Assembly } from './machines';

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
  // The VIC-20 shares the breadbin shell with the c64 station because the real
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
  // closer in silhouette to the Amiga 500 than to the c64 station's case. amigaA is
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
  // The ZX Spectrum is the smallest object in the hall — a 23 cm rubber-keyed
  // slab that plugged into the family television. The kit has no body that
  // small, so it takes the smallest wedge (eightBitWedgeA, shared with
  // apple2/mpf2/plus4) paired with the LARGEST home CRT, which is the honest
  // relationship: the machine was tiny and the telly was not. That pairing is
  // free — amiga holds amigaA|homeCrtA — so the signature stays distinct, and
  // the black case and rainbow-flash red in machineIdentity.ts are what read as
  // Sinclair. No mouse and no keyboard model: the keyboard IS the machine, and
  // no pointing device was ever made for it.
  zxspectrum: { kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtA' },
  // The smallest object in the collection: a ZX81 is a black wedge the size of
  // a paperback with a printed membrane where the keys should be, plugged into
  // whatever television was free. eightBitWedgeA is the narrowest wedge in the
  // kit and homeCrtC the smallest set, which is as close as the parametric
  // assets get to that pairing; the black-plastic tint below is what stops it
  // reading as another beige home micro. No mouse and no joystick: the ZX81's
  // only other port was a cassette recorder.
  zx81: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtC',
  },
  // The Dragon 32 is a chunky sloped wedge with the keyboard in the lid and a
  // television behind it — the same silhouette family as apple2/mpf2/plus4, so
  // it takes the shared wedge body and the one home CRT that wedge has not yet
  // been paired with (homeCrtA is otherwise only under the Amiga's separate
  // desktop case). No keyboard and no mouse: the keys are in the machine, and
  // the Dragon's only other port took a pair of analogue joysticks.
  // The BBC Micro takes the Acorn wedge that riscos also uses, because it is
  // Acorn's own case language and the closest silhouette in the kit to a Model
  // B: a deep beige wedge with a full-travel keyboard in the chassis. The two
  // stay distinct through the monitor — riscos pairs it with the boxy office
  // crtA, this one with homeCrtE, the largest home CRT, which is what a
  // Microvitec Cub was next to a school BBC. No mouse: the Model B had no
  // pointing device and no port for one (its analogue port took joysticks).
  bbcmicro: {
    kind: 'homeMicro', body: 'acornA3000', monitor: 'homeCrtE',
  },
  // homeCrtE (the largest set) rather than homeCrtA: the Dragon was sold to be
  // plugged into the family television, and zxspectrum already holds
  // eightBitWedgeA|homeCrtA. Every exhibit needs a distinct hardware signature.
  dragon32: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'homeCrtE',
  },
  // The Oric Atmos is a small wedge — the same silhouette family as apple2,
  // mpf2 and plus4 — so it takes the generic 8-bit wedge body and is told apart
  // by the one home television nothing else is paired with (homeCrtA belongs to
  // the amiga's assembly, not to that CRT alone) and by its identity tint: a
  // BLACK case with a red stripe, which is what the Atmos actually looked like.
  // No mouse: the Atmos's other ports were tape, printer and expansion.
  // compactA keeps this distinct from the other wedge machines -- zxspectrum
  // holds homeCrtA, zx81 homeCrtC and dragon32 homeCrtE. A small set also
  // suits the Atmos, a compact machine sold against the Spectrum.
  oricatmos: {
    kind: 'homeMicro', body: 'eightBitWedgeA', monitor: 'compactA',
  },
  // KC 85/4: NOT a home-micro wedge. The Mühlhausen machine is a flat, dark
  // slab with its module slots on the right-hand side, a DETACHED keyboard on a
  // cable, and a monitor standing on top of the case — a pizza-box station, and
  // the only 8-bit one in the lineup, which is also what keeps its silhouette
  // distinct from the Commodore wedges. No mouse: the KC's pointing devices
  // were a light pen and a joystick module, neither of which this station streams.
  kc854: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'homeCrtA', keyboard: 'keyboardD',
  },
  // The Sinclair QL is a long, flat, matt-black wedge with the keyboard in the
  // chassis and two microdrive slots on the right cheek — much closer in
  // silhouette to the Atari ST body than to any Commodore breadbin, which is
  // why it takes atariSt rather than another eightBitWedge. The ST pairs that
  // body with homeCrtC; the QL takes the dedicated monitor homeCrtE, which is
  // also the exhibit's own subject matter: the first thing the machine asks is
  // whether it is plugged into a monitor or a television, and this one answered
  // monitor. No mouse — the QL shipped without a pointing device of any kind.
  sinclairql: { kind: 'homeMicro', body: 'atariSt', monitor: 'homeCrtE' },
  // The NeXTcube is a one-foot matte-black magnesium box with a separate
  // MegaPixel monitor, keyboard and two-button mouse — a workstation
  // silhouette, not a home micro and not a pizza box. towerE is the shortest
  // tower in the kit and the closest thing to a cube; crtE plus the wide Unix
  // keyboard and workstation mouse keep the signature distinct from gt40
  // (towerE|crtE and nothing else) and from solaris/irix, which share crtE but
  // sit on pizza-box bodies. The right long-term asset is a bespoke black cube.
  nextstep: {
    kind: 'towerSetup', body: 'towerE', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // The ARM Evaluation System IS a BBC Micro Model B — the ARM is a podule on
  // the far end of its Tube — so it takes the same Acorn wedge, and the pair
  // reading as the same case language is correct rather than a collision. What
  // separates them is the DESK: bbcmicro is the school machine with the largest
  // home set (a Microvitec Cub), and this one was a £4,500 developer's tool, so
  // it gets crtE, the boxy office monitor. That keeps the signature distinct
  // from both Acorn siblings (riscos holds acornA3000|crtA and has a mouse) and
  // from every crtE user (solaris pizzaBoxC, nextstep towerE). No keyboard and
  // no mouse for the same reason as bbcmicro: the keys are in the chassis and
  // the Model B had no pointing device or port for one.
  armeval: {
    kind: 'homeMicro', body: 'acornA3000', monitor: 'crtE',
  },
  // The second SGI Indy. It is the SAME machine as the irix station — the same
  // blue pizza-box, a different MIPS grade inside it — so it takes the same
  // pizzaBoxC body and the same SGI-flavoured wide keyboard and puck mouse
  // that irix and solaris share. What has to keep the two Indys apart on the
  // floor is the DESK: irix holds pizzaBoxC|compactA and solaris
  // pizzaBoxC|crtE, so this one takes crtA, the boxy office monitor nothing
  // has ever paired with a pizza box. The cooler blue tint in
  // machineIdentity.ts and the R4400 badge do the rest.
  indyr4400: {
    kind: 'pizzaBox', body: 'pizzaBoxC', monitor: 'crtA',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // Xerox 6085 "Daybreak": a low flat processor case that lived UNDER the desk,
  // a large landscape monochrome display, a wide keyboard whose left-hand column
  // carries the Level-V verb keys, and a two-button mouse. pizzaBox is the right
  // kind, and pizzaBoxD|crtD is a combination nothing else in the hall holds —
  // deliberately distinct from solaris (pizzaBoxC|crtE) and from nt351
  // (pizzaBoxD|crtC), which share one part each. keyboardE is the widest board
  // in the kit, which is what the Level-V column needs; paramMouseC keeps the
  // two-button silhouette away from the workstation mouse nextstep holds.
  // The one exhibit whose screen is TALLER than it is wide, which IS the
  // exhibit. crtF was modelled for this station and used by nothing else — a
  // portrait tube whose glass is a sheet of paper standing up — so the
  // signature cannot collide. The body is a floor cabinet because the Alto
  // proper was one: a beige box the size of a small fridge, under the desk.
  alto: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtF',
    keyboard: 'keyboardD', mouse: 'paramMouseC',
  },
  // Xerox 8010: a DESKSIDE cabinet beside the desk — the 6085 is what flattened
  // it into a pizza box — so the Star is a towerSetup where its successor is a
  // pizzaBox, and towerC|crtD is a pair nothing else holds.
  star: { kind: 'towerSetup', body: 'towerC', monitor: 'crtD', keyboard: 'keyboardD', mouse: 'paramMouseA' },
  // Xerox 6085 "Daybreak": a low flat processor case that lived UNDER the desk,
  // a large landscape monochrome display, a wide keyboard whose left-hand column
  // carries the Level-V verb keys, and a two-button mouse. pizzaBox is the right
  // kind, and pizzaBoxD|crtD is a combination nothing else in the hall holds —
  // deliberately distinct from solaris (pizzaBoxC|crtE) and from nt351
  // (pizzaBoxD|crtC), which share one part each. keyboardE is the widest board
  // in the kit, which is what the Level-V column needs; paramMouseC keeps the
  // two-button silhouette away from the workstation mouse nextstep holds.
  daybreak: {
    kind: 'pizzaBox', body: 'pizzaBoxD', monitor: 'crtD',
    keyboard: 'keyboardE', mouse: 'paramMouseC',
  },
  // Compaq AlphaServer ES40: a wide pedestal server, not a desktop PC — towerD
  // already reads as DEC on the floor (decos holds towerD|terminalA). The glass
  // is crtE, the big workstation tube gt40 and nextstep hold; towerD|crtE is a
  // pair nothing else in the hall has, so the one Windows machine on non-Intel
  // iron cannot be mistaken for the PC towers around it. Workstation
  // keyboard/mouse (keyboardH|paramMouseG) because the ES40 console was DEC
  // glass, not a family-PC set.
  w2kalpha: {
    kind: 'towerSetup', body: 'towerD', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // The SAME iron as w2kalpha — an AlphaServer ES40 pedestal — running the
  // UNIX it was designed for, so the same towerD body reads as the sibling it
  // is. The tube differs (paramCrt, the parametric workstation CRT) so the
  // pair towerD|paramCrt stays distinct from w2kalpha's towerD|crtE on the
  // floor; same DEC glass-terminal keyboard/mouse set.
  tru64: {
    kind: 'towerSetup', body: 'towerD', monitor: 'paramCrt',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // Quadra 800: a compact MINI-tower, not a full pedestal — towerA is the
  // shortest body in the kit (0.38) and reads correctly beside the PC towers
  // without pretending to be one. The glass is crtE, the big workstation tube,
  // because this station runs the Apple 21-inch 1152x870 mode and a small CRT
  // would make the exhibit's own resolution look like a mistake. towerA|crtE is
  // a pair nothing else in the hall holds. keyboardH is the widest keyboard in
  // the kit, which is the honest silhouette for the Apple Extended Keyboard II,
  // and paramMouseF is the least-used mouse — fitting for the one machine here
  // whose mouse has a single button.
  macos753: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseF',
  },
  // HP 9000/778 (Visualize B160L): a low, wide desktop workstation — a pizza
  // box, like solaris and irix, but HP's box was the broad flat one, so it takes
  // pizzaBoxA. crtE is the big workstation tube (the station runs the 1280x1024
  // ceiling of the Artist framebuffer). pizzaBoxA|crtE is a pair nothing else
  // in the hall holds: solaris is pizzaBoxC|crtE, the other pizzaBoxA users sit
  // under crtD and homeCrtA. keyboardH/paramMouseG is the shared Unix
  // workstation set — HP's HIL keyboard and three-button mouse read the same.
  hpuxvue: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // beos: BeOS R5, the original behind haiku — a beige 2000 tower rather than
  // haiku's modern DIY case; CRT era, so crtC.
  beos: {
    kind: 'towerSetup', body: 'modernTower', monitor: 'crtC',
    keyboard: 'keyboardG', mouse: 'paramMouseE',
  },
  // newsos: Sony NWS-3260 — the NEWS line's portable, an R3000 pizza-box
  // slab under a monochrome LCD lid; the shared Unix-workstation keyboard/mouse.
  newsos: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'lcdA',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // sunos414: SPARCstation 5 — Sun's 1994 pizza box, the same slab family as
  // the solaris station (pizzaBoxC) with the shared Unix Type-5 keyboard and
  // three-button mouse. What separates the two Suns is the tube: solaris sits
  // under the 20-inch crtE, while the SS5 era's desk monitor was the small
  // 16-inch one (crtD, the shortest tube in the kit) — which is also the
  // honest match for the 1152x900 cg3 framebuffer this station runs.
  sunos414: {
    kind: 'pizzaBox', body: 'pizzaBoxC', monitor: 'crtD',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // aux: Macintosh Quadra 800 — the same 68040 Quadra as the macos753 station,
  // so the same Apple kit reads correctly: towerA is the Quadra's upright
  // mini-tower case, keyboardH the Extended Keyboard II silhouette, and
  // paramMouseF the one-button Apple mouse (shared only by the
  // Apple-family stations). It is separated from macos753 by the display: the Mac OS
  // station holds the big crtE, this one the smaller crtD.
  aux: {
    kind: 'towerSetup', body: 'towerA', monitor: 'crtD',
    keyboard: 'keyboardH', mouse: 'paramMouseF',
  },
  // rhapsody: Rhapsody DR2 for Intel — a 1998 beige PC tower (the Intel build
  // ran on commodity hardware, not a Mac), CRT era, so crtC and the PC
  // keyboard/mouse set. towerC is the taller beige AT-era tower, which keeps
  // it off beos's silhouette: beos is the squarer modernTower under the same
  // crtC, and the two sit next to each other in binding order.
  rhapsody: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardG', mouse: 'paramMouseE',
  },
  // chokanji: 超漢字 / B-right/V (BTRON3) — a 2002 Japanese desktop PC. The 超漢字
  // VM shipped to run on commodity PC/AT hardware, so a beige AT-era tower + CRT
  // (Cirrus 800x600). Shares the towerC/crtC silhouette of the beige-PC era;
  // its blue TRON accent (machineIdentity) sets it apart.
  chokanji: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
  // macos9: Power Mac G4 (2001) — Apple's graphite minitower under a big
  // Studio Display CRT. towerD is the taller rounded tower silhouette, crtE
  // the large-desktop CRT; keyboardG the compact modern board and paramMouseF
  // the one-button Apple mouse (the Apple Pro Mouse kept the one-button faith).
  macos9: {
    kind: 'towerSetup', body: 'towerD', monitor: 'crtE',
    keyboard: 'keyboardG', mouse: 'paramMouseF',
  },
  // amigaos35: Amiga 4000 (1992 hardware, 1999 OS) — the classic line's big-box
  // tower under a multisync CRT. towerC/crtC beige-tower silhouette; its Amiga
  // red accent (machineIdentity) separates it from the PC-clone towers.
  amigaos35: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  // aix432: the RS/6000 40P is a low, wide beige desktop box, not a pedestal —
  // a PReP machine assembled from PC parts, and it looked it. Beige CRT above,
  // keyboard and mouse on the PS/2 ports the emulated machine actually has.
  aix432: {
    kind: 'pizzaBox', body: 'pizzaBoxD', monitor: 'crtE',
    keyboard: 'keyboardH', mouse: 'paramMouseG',
  },
  // ravynos: the newest station in the hall, and the only one whose silhouette
  // is an argument. ravynOS is FreeBSD on a commodity 2025 x86-64 PC that has
  // been dressed as a Mac — so the parts are deliberately mixed. modernD is the
  // plain minimal modern tower (its only other user, serenityos, sits under
  // lcdB, so modernD|lcdC is this station's alone), lcdC the big flat panel
  // that reads as a modern desktop display, and keyboardG the compact board the
  // Apple-family stations (macos, macos9) carry — the one borrowed part, for
  // the machine whose whole point is borrowed clothes. The mouse is the
  // ordinary modern paramMouseE and NOT the one-button paramMouseF that marks
  // the real Apple hardware here: this is a PC, and the exhibit says so.
  ravynos: {
    kind: 'towerSetup', body: 'modernD', monitor: 'lcdC',
    keyboard: 'keyboardG', mouse: 'paramMouseE',
  },
  // amix: the Amiga 3000 is a low desktop box, not a tower — the machine
  // Commodore sold as the A3000UX workstation. Same pizzaBoxD shell as
  // amigaos35's sibling A-series entries, under the ordinary crtC: this one
  // drives an A2410 board at 1024x768 in colour, so it is NOT the mono
  // setup its chipset X server would imply.
  amix: {
    kind: 'pizzaBox', body: 'pizzaBoxD', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  // bootos: 8088-compatible on purpose, so the exhibit is an XT-class desktop
  // box — pizzaBoxA, the same wide beige case msdoswin1 sits in, but under
  // crtA rather than msdoswin1's green-mono crtD (bootOS boots in colour VGA
  // text mode) with the keyboardD XT board. NO mouse: bootOS reads the BIOS
  // keyboard and nothing else, and the station has no pointer device, so the
  // desk is honest about it. pizzaBoxA|crtA|keyboardD|none is unique.
  bootos: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtA',
    keyboard: 'keyboardD',
  },
  // pcgeos: a 386-class beige desktop box under a colour VGA CRT, with the
  // PS/2 mouse the desktop is built around (CTMOUSE + genmouse.geo, relative).
  // Same wide beige case family as bootos, but a mouse and the 101-key board.
  pcgeos: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtA',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
  // pcbsd: a 2008 office mini-tower under a 4:3 LCD, PS/2 keyboard and a plain
  // two-button PS/2 mouse (the station forwards a relative pointer; FreeBSD 6.3's
  // X never moved on a USB tablet). Distinct from reactos's SFF pizza-box kit.
  pcbsd: {
    kind: 'towerSetup', body: 'towerD', monitor: 'lcdC',
    keyboard: 'keyboardF', mouse: 'paramMouseD',
  },
  // ubuntu: a 2004 beige-and-black minitower under a CRT — the ShipIt-CD PC
  // Warty was posted to. USB tablet in the guest, so a mouse on the desk.
  ubuntu: {
    kind: 'towerSetup', body: 'towerE', monitor: 'crtD',
    keyboard: 'keyboardF', mouse: 'paramMouseE',
  },
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
  // freebsd411: a 2005 beige Pentium-4-era mini-tower under a colour SVGA CRT,
  // with the PS/2 mouse and 101-key board KDE 3.3.2 on XFree86 4.4.0 is driven
  // by — a tower, not the flat 1990 desktop case pcgeos sits in.
  freebsd411: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtD',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
} as const satisfies Record<string, Assembly>;


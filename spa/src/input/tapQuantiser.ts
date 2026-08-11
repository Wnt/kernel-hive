// ============================================================================
//  input/tapQuantiser — what counts as a TAP, measured in the units a hand
//  actually moves in.
//  ---------------------------------------------------------------------------
//  A touch or S-Pen behaves like a mouse here (button DOWN on contact, MOVE while
//  held, UP on release — no deferral, no long-press automation, no synthetic
//  clicks). That is only true if the guest sees a tap as a POINT. A hand does
//  not: measured on IRIX, two taps 190 ms apart landed 4-12 guest px apart and
//  each one wandered while down, so the guest saw press-drag-release and shuffled
//  the icon sideways instead of opening it. This state machine is what turns a
//  wobble back into a point, and it is driven by BOTH input paths (the touch
//  recognizer, and the stylus path via input/penContact) so there is exactly one
//  definition of a tap.
//
//  EVERY THRESHOLD IS IN CSS PIXELS. This is the fix of 2026-08-05 and the whole
//  reason the file exists: the thresholds used to be in GUEST pixels, but a hand
//  wobbles in physical space, and the guest→CSS ratio changes with every station.
//  IRIX at 1288x1024 in a 411 px-wide rect is 3.13 guest px per CSS px, so the
//  old 24 guest px slop was ~7.7 CSS px — about 1.3 mm of finger travel — while
//  the same constant on win311 (~2.5x) was half again as forgiving. One station was
//  usable and the other was not, from one number. A CSS px is ~1/96", so in this
//  space a threshold means a physical distance and behaves the same everywhere.
//  Guest pixels appear only in what is SENT.
//
//  Two gates, because distance alone cannot catch a wobble that happens to be
//  large: a DISTANCE gate (`tapPx`) and a TIME gate (`tapHoldMs`). See below.
// ============================================================================

/** One contact sample in both spaces at once.
 *
 *  `x,y` are GUEST px — the only thing ever sent to the emulator. `cx,cy` are
 *  viewport CSS px — the space every threshold below is measured in. Callers
 *  already hold both (the letterbox map runs on the client point), so nothing
 *  needs converting back. */
export interface TapPoint {
  x: number;
  y: number;
  cx: number;
  cy: number;
}

/** Tap quantisation. CSS px and ms — never guest px; see the header.
 *
 *  SIZED FOR A MOVING HAND, not the bench. Every measurement behind these came
 *  from deliberate taps with a steady hand in a calm room, and that is the easy
 *  case: one-handed on a bus, the same gesture scatters several times as far.
 *  The failure is silent and total (the double-click simply does not happen),
 *  while the cost of being generous is only that a very small, very slow drag
 *  reads as a tap — so these are deliberately loose. */
export const TAP = {
  /** "Did this contact move?" Under it nothing is forwarded and the release
   *  lands on the press point, so a tap is a point however shaky the hand.
   *
   *  ~3 mm. Above the wobble of a hand-held stylus (measured 1-5 px CSS with a
   *  steady hand) and in the same family as Android's own 8dp touch slop, which
   *  is the number every native app on the device is already tuned to. */
  tapPx: 12,
  /** Travel that is unambiguously a DRAG. Crossing it forwards immediately and
   *  cancels the hold below, so a deliberate drag is never delayed — only the
   *  ambiguous first few millimetres are.
   *
   *  ~8 mm. Nobody moves this far while meaning to tap; everybody moves further
   *  than this within a few ms of meaning to drag. */
  dragEscapePx: 30,
  /** How long a fresh contact refuses to become a drag on distance alone.
   *
   *  The distance gate is necessary but not sufficient: a hectic hand can cross
   *  ANY plausible radius during a tap, and the moment it does, every later
   *  sample flows and the click is lost — silently, because the press already
   *  landed. Time is the second, independent signal, and it is cheap: measured
   *  pen taps last 37-52 ms from contact to lift, so 200 ms holds every real tap
   *  comfortably while a drag that means it escapes on distance instead. Only a
   *  SLOW drag pays, and it pays at most this once, at the start. */
  tapHoldMs: 200,
  /** A second contact this soon after the previous tap LIFTED is a double-tap.
   *
   *  Rough guest defaults: Windows (3.x through 11) ~500 ms, macOS ~500 ms,
   *  GTK 400 ms, Qt 400 ms, and Xt/Motif — CDE and IRIX 4Dwm — as low as
   *  200-250 ms. 500 matches the most common and is the ceiling worth having:
   *  OUR window only decides whether to snap the second tap onto the first, and
   *  the GUEST still has to pair them with its own timer. On a Motif desktop a
   *  leisurely double-tap can therefore be snapped by us and still refused
   *  there — a guest-side limit, not something the client can paper over. */
  doubleMs: 500,
  /** …and this close to the first tap's contact point.
   *
   *  ~5 mm, and the one threshold with a HARD ceiling: it must stay inside one
   *  icon, because a second tap beyond the icon was aimed at the neighbour and
   *  snapping it backwards would open the wrong thing. An IRIX icon is ~64 guest
   *  px ≈ 20 CSS px at 3.13x, so this is that icon and no more. Calm pen scatter
   *  measured 4-12 guest px; a moving hand needs the rest of the headroom. */
  doublePx: 20,
};

/** What a contact resolves to once quantised. Guest px — this is what is sent. */
interface TapPress {
  x: number;
  y: number;
  /** This is the 2nd tap of a double-tap (it was snapped onto the 1st). */
  double: boolean;
}

/** The tap-quantisation state machine, shared by BOTH input paths.
 *
 *  It is not inside the touch recognizer because a stylus never reaches it:
 *  `pointerType` is `'pen'`, which is neither `'touch'` nor one of the touch-
 *  ARCHETYPE stations, so on an ordinary desktop exhibit the pen is handled by the
 *  mouse path in useStreamInput. Two fixes shipped to the recognizer changed
 *  nothing on win311/IRIX for exactly that reason. */
export interface TapQuantiser {
  /** Contact went down. Returns where to press, and whether to double it. */
  down(p: TapPoint, t: number, button: number): TapPress;
  /** Movement while held. false = swallow it (wobble, or still inside the hold). */
  forward(p: TapPoint, t: number): boolean;
  /** Contact lifted. Returns where to release, and whether it was a TAP at all
   *  (a drag is not, and nothing downstream should treat it as one). */
  up(p: TapPoint, t: number): { x: number; y: number; tapped: boolean };
  /** Contact lost (pinch takeover, cancel) — drop the anchor. */
  cancel(): void;
}

/** The previous completed TAP (not drag), the anchor a double-tap snaps onto. */
interface LastTap {
  x: number; // guest px, as reported for that press (already snapped)
  y: number;
  cx: number; // …and the same point in CSS px, which is what gets compared
  cy: number;
  t: number;
  button: number;
}

export function createTapQuantiser(): TapQuantiser {
  let anchor: LastTap | null = null; // previous TAP, the double-tap anchor
  let ox = 0, oy = 0, ocx = 0, ocy = 0, button = 0; // REPORTED press point (snapped on a double)
  let rcx = 0, rcy = 0; // where the contact ACTUALLY landed, in CSS px
  let downT = 0; // contact time, for the hold
  let moved = false; // gate opened: samples now flow to the guest
  let wander = 0; // furthest this contact has strayed from where it landed (CSS px)

  return {
    down(p, t, btn) {
      button = btn;
      const near = anchor
        && anchor.button === btn
        && t - anchor.t <= TAP.doubleMs
        && Math.hypot(p.cx - anchor.cx, p.cy - anchor.cy) <= TAP.doublePx;
      ox = near ? anchor!.x : p.x;
      oy = near ? anchor!.y : p.y;
      // Keep the CSS anchor on the FIRST tap of a run, exactly like the guest
      // one, so a third tap is judged against where the run started rather than
      // drifting a doublePx radius per tap.
      ocx = near ? anchor!.cx : p.cx;
      ocy = near ? anchor!.cy : p.cy;
      // Wander is measured from where the contact REALLY landed, never from the
      // snapped point. On a second tap those differ by up to the whole doublePx
      // radius, so measuring from the snap made every wobble read as "past the
      // slop" — the guest cursor was then dragged off the pixel the double-click
      // was aimed at, and the second click became a drag (2026-08-05).
      rcx = p.cx;
      rcy = p.cy;
      downT = t;
      moved = false;
      wander = 0;
      return { x: ox, y: oy, double: !!near };
    },
    forward(p, t) {
      wander = Math.max(wander, Math.hypot(p.cx - rcx, p.cy - rcy));
      if (moved) return true;
      // A clear drag opens the gate at once — the hold must never add latency to
      // a gesture that has already declared itself.
      if (wander > TAP.dragEscapePx) { moved = true; return true; }
      if (wander <= TAP.tapPx) return false; // inside the slop: wobble
      // Past the slop but not clearly a drag. THIS is the band a shaky tap lands
      // in, so it is decided on time instead: hold until the contact has lasted
      // longer than any real tap does.
      if (t - downT < TAP.tapHoldMs) return false;
      moved = true;
      return true;
    },
    up(p, t) {
      // `moved` is the whole answer: if nothing was forwarded, the guest cursor
      // never left the press point, so this WAS a tap — release there and anchor
      // it. Deriving both from one flag is what keeps the release position and
      // the double-tap anchor from ever disagreeing.
      const tapped = !moved;
      anchor = tapped ? { x: ox, y: oy, cx: ocx, cy: ocy, t, button } : null;
      return tapped ? { x: ox, y: oy, tapped } : { x: p.x, y: p.y, tapped };
    },
    cancel() {
      anchor = null;
      moved = false;
      wander = 0;
    },
  };
}

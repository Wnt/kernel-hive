// ============================================================================
//  input/trackpad — PURE trackpad-mode pointer engine (T-3)
//  ---------------------------------------------------------------------------
//  Touch stations whose guest wants RELATIVE motion (qnx/freedos/msdoswin1) are
//  broken under the direct absolute-pointer path: a finger reports an absolute
//  guest coordinate, but the guest draws its OWN cursor from deltas, so a tap
//  teleports it. Trackpad mode fixes that (and is an opt-in laptop-style pointer
//  for absolute stations too):
//    - REL stations → a finger DRAG accumulates a scaled delta and ships it as a
//      RelMotion (control.sendMouseMoveRel); a still TAP is a click. The guest
//      renders its own cursor — no local sprite.
//    - ABS stations → the SAME drag drives a LOCAL virtual cursor (clamped to the
//      guest bounds) and forwards control.sendMouseMove(absX,absY) at the sprite;
//      a tap clicks at the cursor. OnScreenCursor.tsx paints the sprite.
//  DOM-free + timer-free (the hook owns the long-press setTimeout) so the whole
//  delta / DPR / clamp / tap vocabulary is exhaustively unit-testable, exactly
//  like the sibling touchGestures recognizer. Ops map onto the SAME
//  StreamControlHandle primitives the recognizer uses (plus sendMouseMoveRel).
//
//  TAP-THEN-HOLD IS A DRAG (2026-08-05), the laptop idiom — because this became
//  the DEFAULT finger model and a pointer that cannot drag cannot use these
//  guests at all: a Motif window is moved by its title bar, a scrollbar by its
//  thumb, text by a sweep. Direct mode gets drag for free (contact IS the
//  button), so shipping trackpad as the default without it would have taken a
//  capability away.
//
//  THE TAP'S BUTTON-UP IS DEFERRED, and that is what makes the idiom work here.
//  Sending it immediately put a complete click in front of the drag's press, and
//  the guest paired those three edges into a double-click — measured on win311,
//  which is right to do it: a press that follows a click inside the guest's
//  double-click window IS a double-click-drag, and Windows 3.1's window is
//  ~450 ms. So a tap sends only its DOWN and holds the up back for
//  TAP_RELEASE_MS. What arrives next decides what the gesture was:
//
//    * nothing → the up goes out on the deadline. An ordinary click, a touch
//      slower to release than a mouse and otherwise identical.
//    * another contact → it INHERITS the button that is already down. The guest
//      never sees an up, so there is no pair to match and no double-click: it
//      sees one press that starts moving. That is a drag.
//    * …and if that second contact turns out to be a tap after all, the visitor
//      meant a double-click, so the held click is closed and a second one sent.
//      Both still land inside the guest's window.
//
//  Nothing is guessed in advance and nothing has to be taken back — the deferral
//  is short enough to be invisible and long enough to see the next contact.
// ============================================================================

interface Vec2 {
  x: number;
  y: number;
}

/** Guest framebuffer bounds the abs virtual cursor is clamped into. */
interface TrackpadBounds {
  w: number;
  h: number;
}

/** One primitive op the hook expands onto the StreamControlHandle. */
export type TrackpadOp =
  | { kind: 'rel'; dx: number; dy: number }
  | { kind: 'move'; x: number; y: number }
  | { kind: 'button'; button: number; down: boolean; x?: number; y?: number };

// ---- tuning (one place) ---------------------------------------------------
/** Crosshair travel per unit of finger travel, measured ON GLASS. 1 = the
 *  crosshair keeps exact pace with the fingertip, whatever the exhibit's
 *  resolution or the panel's density.
 *
 *  It used to be 1.6 guest px per CSS px × devicePixelRatio, which was blind to
 *  both: the same swipe sent the cursor 1.3× the finger's travel on a 1288 px
 *  IRIX and 2.7× on a 640 px Win 1.01 — the lower the resolution, the wilder it
 *  got — and 3× further again on a dense phone panel than on a 1× display,
 *  though CSS px are already density-normalised. Speed is a property of the
 *  hand, not of the guest's framebuffer. */
const GAIN = 1;
const TAP_SLOP_PX = 8; // total CSS travel under which a release is a tap (not a drag)
const TAP_MS = 320; // …and within this long → a click

/** Scale a raw CSS-pixel finger delta into guest-motion units. `track` is how
 *  many guest px one CSS px of the displayed picture covers, so it is what makes
 *  the gain mean the same thing on every exhibit; `gain` is the on-glass
 *  acceleration factor. */
function scaleDelta(dxCss: number, dyCss: number, gain: number, track: number): Vec2 {
  const k = gain * (track > 0 ? track : 1);
  return { x: dxCss * k, y: dyCss * k };
}

/** Clamp an absolute cursor to the guest framebuffer [0..w-1]×[0..h-1]. */
function clampCursor(x: number, y: number, b: TrackpadBounds): Vec2 {
  return {
    x: b.w > 0 ? Math.min(Math.max(x, 0), b.w - 1) : x,
    y: b.h > 0 ? Math.min(Math.max(y, 0), b.h - 1) : y,
  };
}

/** Stateful (but DOM/timer-free) trackpad engine. Create one per stream surface. */
export interface Trackpad {
  /** `right` = the on-screen arm was set → this contact uses button 2, for a
   *  right click or (held) a right press-drag-release. There is deliberately NO
   *  long-press right-click: the hold means GRAB, and right-click is the ⊕ badge,
   *  the same affordance direct mode uses. */
  begin(id: number, cx: number, cy: number, t: number, right?: boolean): TrackpadOp[];
  move(id: number, cx: number, cy: number): TrackpadOp[];
  end(id: number, t: number): TrackpadOp[];
  /** The deferred-release deadline elapsed (the hook's setTimeout calls this):
   *  no second contact came, so close the tap's click. A no-op if the button was
   *  already taken over by a drag or released. */
  tapRelease(): TrackpadOp[];
  /** A button is DELIBERATELY down right now — a live drag, or a tap whose
   *  release is still pending. The hook's stuck-button self-heal has to ask,
   *  because between contacts this engine looks exactly like a leak. */
  holds(): boolean;
  /** The active touch was cancelled (e.g. a 2nd finger stole it for a pinch). */
  cancel(): TrackpadOp[];
  /** Current ABS virtual cursor (null on rel stations — the guest owns its cursor). */
  cursor(): Vec2 | null;
  setBounds(b: TrackpadBounds): void;
  /** How many GUEST px one CSS px of the displayed picture covers — the
   *  exhibit's resolution divided by the width it is drawn at. This is what
   *  keeps the pointer's speed a property of the hand: without it the gain is
   *  quoted in guest px, so the same swipe crosses a 640-px exhibit four times
   *  faster than it crosses a 2560-px one. Re-read per contact, since a guest
   *  can change resolution and the stage can be resized or rotated. */
  setTrack(guestPerCssPx: number): void;
  /** Current local pinch-zoom magnification of the picture (1 = unzoomed).
   *
   *  The cursor is driven by CSS-px finger deltas, but what those deltas MEAN on
   *  screen depends on the zoom: at 2× a guest pixel is twice as wide, so an
   *  unadjusted delta sends the crosshair across the magnified picture twice as
   *  fast. Zooming in is how a visitor asks for precision — it has to buy finer
   *  control, not coarser. Dividing the gain by the scale keeps the crosshair
   *  moving with the finger on GLASS, at any magnification. */
  setScale(s: number): void;
  /** Place the virtual cursor (guest px) and publish it to the sprite.
   *
   *  Used when the surface switches INTO trackpad mode (input/pointerModeAuto):
   *  the guest's pointer is wherever the stylus left it, so the sprite has to
   *  appear THERE. Seeding centre instead would put the visible cursor and the
   *  guest's own cursor in two different places, and the first tap would land at
   *  neither. No-op on rel stations, which have no local cursor to place. */
  setCursor(c: Vec2): void;
}

export interface TrackpadConfig {
  /** rel stations ship RelMotion + a guest-drawn cursor; abs stations drive a sprite. */
  rel: boolean;
  gain?: number;
  /** Guest px per CSS px of the displayed picture — see setTrack. */
  track?: number;
  onCursor?: (c: Vec2) => void;
  /** A contact took over the deferred click and is DRAGGING. Touch shows no
   *  cursor and gives no feedback of its own, so the sprite has to say that the
   *  button is down — otherwise a drag that took and one that did not look the
   *  same, since the finger moves either way. */
  onHold?: (held: boolean) => void;
}

/** How long a tap's button-UP is held back, waiting to see whether another
 *  contact arrives to inherit the press (see the header). Long enough to catch a
 *  deliberate re-press, short enough that a plain click still feels immediate. */
export const TAP_RELEASE_MS = 250;

export function createTrackpad(cfg: TrackpadConfig): Trackpad {
  const gain = cfg.gain ?? GAIN;
  let track = cfg.track ?? 1;
  const rel = cfg.rel;
  let bounds: TrackpadBounds = { w: 0, h: 0 };
  let scale = 1; // local pinch-zoom magnification (see setScale)
  let activeId: number | null = null;
  let lastX = 0;
  let lastY = 0;
  let startT = 0;
  let travel = 0; // accumulated CSS travel (tap vs drag arbiter)
  let remX = 0; // fractional rel remainder — PS/2 RelMotion needs integers
  let remY = 0;
  let moved = false; // travelled past the slop → a drag, and kills the long-press
  let cursor: Vec2 | null = null; // abs virtual cursor (rel stations keep it null)
  let dragging = false; // this contact inherited the held button: it is dragging
  let pendingUp = false; // a tap's DOWN went out; its UP is waiting (see header)
  // Which button this contact drives — 2 when the ⊕ arm was set, so an armed
  // hold is a right press-drag-release. That is the only way to pull an IRIX
  // spring-loaded root menu onto an item without a stylus.
  let button = 0;
  // The guest pointer is known to sit AT `cursor` (a move op put it there), so a
  // button needs no coordinates. Repeating them would make the daemon re-position
  // before every edge, which re-arms its warpd button-guard and pulls the halves
  // of a double-click apart — measured on win311, where 4 px of drift is enough
  // to lose the pair (see ui/grid/StreamView/useTouchGestures).
  let synced = false;

  // The abs cursor persists across gestures; seed it centred on first use so the
  // sprite has a defined home before the very first drag — and PUBLISH it, so the
  // sprite is visible from the first touch instead of only after motion.
  //
  // NOT UNTIL THE GUEST'S SIZE IS KNOWN, though. Centring an unknown framebuffer
  // gave (1,1) — a fabricated corner dressed as a real position, which the first
  // tap would then forward. There is nothing to centre in yet, so the honest
  // answer is "no cursor", and a button with no cursor carries no coordinates at
  // all (see buttonEdge). The next contact seeds it properly, since the hook
  // re-reads the resolution per contact.
  const seedIfNeeded = () => {
    if (rel || cursor) return;
    if (bounds.w <= 0 || bounds.h <= 0) return;
    cursor = { x: bounds.w / 2, y: bounds.h / 2 };
    synced = false; // nothing has been sent yet: the first button must carry it
    cfg.onCursor?.(cursor);
  };

  // One edge of a button at the CURRENT cursor. Rel stations omit coords entirely —
  // the guest clicks wherever its own cursor sits, so a forwarded abs px would
  // teleport it (the exact bug trackpad mode exists to fix). A coordinate-free
  // edge survives all the way to the wire: streamClient/inputWire writes it as a
  // short record the daemon applies no position from.
  const buttonEdge = (button: number, down: boolean): TrackpadOp => {
    if (rel) return { kind: 'button', button, down };
    if (synced || !cursor) return { kind: 'button', button, down };
    synced = true;
    return { kind: 'button', button, down, x: Math.round(cursor.x), y: Math.round(cursor.y) };
  };

  const buttonTap = (button: number): TrackpadOp[] =>
    [buttonEdge(button, true), buttonEdge(button, false)];

  const begin = (id: number, cx: number, cy: number, t: number, right = false): TrackpadOp[] => {
    activeId = id;
    lastX = cx;
    lastY = cy;
    startT = t;
    travel = 0;
    remX = 0;
    remY = 0;
    moved = false;
    seedIfNeeded();
    if (pendingUp) {
      // The previous tap's button is STILL DOWN: this contact takes it over and
      // becomes a drag. Nothing is sent — and nothing needs to be, which is
      // exactly why the guest cannot read a double-click here (see the header).
      pendingUp = false;
      dragging = true;
      cfg.onHold?.(true);
      return [];
    }
    dragging = false;
    button = right ? 2 : 0;
    return []; // a fresh contact commits nothing until it ends
  };

  const move = (id: number, cx: number, cy: number): TrackpadOp[] => {
    if (activeId !== id) return [];
    const dxCss = cx - lastX;
    const dyCss = cy - lastY;
    lastX = cx;
    lastY = cy;
    travel += Math.hypot(dxCss, dyCss);
    // The tap/drag slop stays in raw CSS px: it measures HAND WOBBLE, which is a
    // physical quantity and does not care what the picture is magnified to.
    if (!moved && travel > TAP_SLOP_PX) moved = true;
    const d = scaleDelta(dxCss, dyCss, gain / scale, track);
    if (rel) {
      // Accumulate through the tap slop so no motion is lost, but hold emission
      // until it is clearly a drag — a tap must not twitch the guest cursor.
      remX += d.x;
      remY += d.y;
      if (!moved) return [];
      const idx = Math.trunc(remX);
      const idy = Math.trunc(remY);
      remX -= idx;
      remY -= idy;
      return idx || idy ? [{ kind: 'rel', dx: idx, dy: idy }] : [];
    }
    // ABS: leave the cursor (and the sprite) still until it is a drag, so a tap
    // clicks exactly under the visible cursor.
    if (!moved) return [];
    const c = clampCursor((cursor?.x ?? 0) + d.x, (cursor?.y ?? 0) + d.y, bounds);
    cursor = c;
    synced = true; // this move IS the guest's position now
    cfg.onCursor?.(c);
    return [{ kind: 'move', x: Math.round(c.x), y: Math.round(c.y) }];
  };

  const end = (id: number, t: number): TrackpadOp[] => {
    if (activeId !== id) return [];
    activeId = null;
    const tap = !moved && t - startT <= TAP_MS;
    if (dragging) {
      dragging = false;
      cfg.onHold?.(false);
      // A second TAP means the visitor was double-clicking, not reaching for a
      // drag: close the click that is still open and send a second one. Both
      // land inside the guest's double-click window, which is the one case where
      // it SHOULD pair them.
      if (tap) return [buttonEdge(button, false), ...buttonTap(button)];
      return [buttonEdge(button, false)]; // released where the finger left it
    }
    if (!tap) return [];
    // A tap sends its DOWN and holds the UP back for TAP_RELEASE_MS — the hook's
    // timer calls tapRelease() if no contact arrives to inherit it.
    pendingUp = true;
    return [buttonEdge(button, true)];
  };

  const tapRelease = (): TrackpadOp[] => {
    if (!pendingUp) return [];
    pendingUp = false;
    return [buttonEdge(button, false)];
  };

  const cancel = (): TrackpadOp[] => {
    activeId = null;
    // A stolen touch (a second finger starting a pinch) must not strand a button
    // in the guest — and BOTH ways of holding one count: a live drag, and a tap
    // whose release is still waiting. The pending one has no contact on the
    // glass to release it, so only this can.
    if (dragging) {
      dragging = false;
      cfg.onHold?.(false);
      return [buttonEdge(button, false)];
    }
    return tapRelease();
  };

  return {
    begin,
    move,
    end,
    tapRelease,
    holds: () => pendingUp || dragging,
    cancel,
    cursor: () => cursor,
    setBounds: (b) => {
      bounds = b;
    },
    setScale: (s) => {
      scale = s > 0 ? s : 1;
    },
    setTrack: (n) => {
      track = n > 0 ? n : 1;
    },
    setCursor: (c) => {
      if (rel) return;
      cursor = clampCursor(c.x, c.y, bounds);
      // Best ESTIMATE of where the guest pointer is, not proof — the next click
      // carries its coordinates so a wrong guess corrects itself.
      synced = false;
      cfg.onCursor?.(cursor);
    },
  };
}

// Unit coverage for the tap quantiser — the shared answer to "was that a tap?".
// Both input paths drive it (the touch recognizer, and the stylus path in
// useStreamInput via penContact), so this is where the policy is pinned.
//
// Coordinates are built from a CSS point through a guest/CSS SCALE, the way the
// real letterbox map produces them. That is the point of the whole file: the
// thresholds live in CSS px, so the same physical gesture must behave the same
// on a 1288-wide IRIX station and a 640-wide DOS one.
import { describe, expect, it } from 'vitest';
import { createTapQuantiser, TAP, type TapPoint } from './tapQuantiser';

/** IRIX: 1288 guest px displayed across a 411 CSS px rect (measured 2026-08-05). */
const IRIX = 3.13;

/** A contact at a CSS point, mapped to guest px by `scale` — as the caller does. */
const at = (cx: number, cy: number, scale = IRIX): TapPoint =>
  ({ x: Math.round(cx * scale), y: Math.round(cy * scale), cx, cy });

describe('tap quantiser — a tap is a point', () => {
  it('swallows wobble, then releases where it pressed', () => {
    const q = createTapQuantiser();
    const down = at(100, 100);
    expect(q.down(down, 0, 0)).toEqual({ x: down.x, y: down.y, double: false });
    expect(q.forward(at(101, 102), 30)).toBe(false); // ~2 CSS px of hand wobble
    expect(q.up(at(101, 102), 94)).toEqual({ x: down.x, y: down.y, tapped: true });
  });

  it('doubles the second contact and snaps it onto the first', () => {
    const q = createTapQuantiser();
    const first = at(100, 100);
    q.down(first, 0, 0);
    q.up(at(101, 101), 45);
    // 4 CSS px away, 190 ms later — the measured S-Pen double-tap. Reported at
    // the FIRST tap's guest pixel, so the guest pairs the two clicks itself.
    expect(q.down(at(103, 103), 190, 0)).toEqual({ x: first.x, y: first.y, double: true });
  });

  it('does not double a different button, a late tap, or a far one', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    q.up(at(100, 100), 40);
    expect(q.down(at(101, 101), 100, 2).double).toBe(false); // right button
    q.up(at(101, 101), 140);
    q.down(at(100, 100), 200, 0);
    q.up(at(100, 100), 240);
    expect(q.down(at(101, 101), 1200, 0).double).toBe(false); // too late
    q.up(at(101, 101), 1240);
    q.down(at(100, 100), 1300, 0);
    q.up(at(100, 100), 1340);
    expect(q.down(at(140, 140), 1400, 0).double).toBe(false); // too far
  });
});

// THE 2026-08-05 FIX. The thresholds used to be in guest px, so an identical
// hand movement was judged 3.13x more harshly on IRIX than on a 1:1 station — the
// same code was usable on win311 and unusable on IRIX purely because of the
// station's resolution. Nothing about a hand changes with the guest's resolution.
describe('tap quantiser — thresholds are physical, not per-tile', () => {
  const wobble = (scale: number) => {
    const q = createTapQuantiser();
    const d = at(100, 100, scale);
    q.down(d, 0, 0);
    const fwd = q.forward(at(107, 104, scale), 30); // ~8 CSS px: a shaky tap
    return { fwd, up: q.up(at(107, 104, scale), 60), press: d };
  };

  it('treats one gesture identically on a 3.13x tile and a 1:1 one', () => {
    for (const scale of [IRIX, 2.5, 1]) {
      const r = wobble(scale);
      expect(r.fwd).toBe(false); // swallowed on every station…
      expect(r.up.tapped).toBe(true); // …and still a tap on every station
      expect(r.up).toEqual({ x: r.press.x, y: r.press.y, tapped: true });
    }
  });

  it('an IRIX icon still fits inside the double-tap radius', () => {
    // A 64 guest px icon is ~20 CSS px at 3.13x — the ceiling doublePx is sized
    // against, so two taps anywhere on one icon pair, and the neighbour never does.
    expect(TAP.doublePx).toBeLessThanOrEqual(64 / IRIX);
  });
});

// The second gate. Distance alone cannot catch a wobble that happens to be
// large: a hectic hand crosses any plausible radius during a tap, and the moment
// it does, every later sample flows and the click is silently lost.
describe('tap quantiser — the tap hold', () => {
  it('a shaky contact that lifts inside the hold forwards nothing and is a tap', () => {
    const q = createTapQuantiser();
    const d = at(100, 100);
    q.down(d, 0, 0);
    // 18 CSS px — past tapPx, nowhere near a deliberate drag.
    expect(q.forward(at(118, 100), 60)).toBe(false);
    expect(q.forward(at(115, 103), 120), 'still held').toBe(false);
    expect(q.up(at(115, 103), 160)).toEqual({ x: d.x, y: d.y, tapped: true });
    // …and it anchors, so the second half of the double-tap still pairs.
    expect(q.down(at(102, 101), 330, 0)).toEqual({ x: d.x, y: d.y, double: true });
  });

  it('the same distance AFTER the hold is a drag', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    expect(q.forward(at(118, 100), 60)).toBe(false); // inside the hold
    expect(q.forward(at(118, 100), TAP.tapHoldMs + 1)).toBe(true); // hold expired
    expect(q.up(at(118, 100), 400).tapped).toBe(false);
  });

  it('a clear drag escapes the hold immediately — no added latency', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    // 40 CSS px, 8 ms in: past dragEscapePx, so it forwards on the very sample
    // that crosses it rather than waiting out the hold.
    const far = at(140, 100);
    expect(q.forward(far, 8)).toBe(true);
    expect(q.forward(at(141, 100), 16)).toBe(true); // …and nothing is filtered after
    expect(q.up(far, 24)).toEqual({ x: far.x, y: far.y, tapped: false });
  });

  it('a drag leaves no anchor to snap the next press backwards', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    q.forward(at(140, 100), 8);
    q.up(at(140, 100), 60);
    expect(q.down(at(141, 101), 100, 0).double).toBe(false);
  });

  it('a cancelled contact leaves no anchor behind', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    q.cancel();
    expect(q.down(at(101, 101), 60, 0).double).toBe(false);
  });
});

// Regression: the second tap of a double-tap is REPORTED at the snapped pixel,
// but its samples arrive where the contact actually landed — up to doublePx
// away. Measuring wobble from the snapped point made every one of those samples
// look like a drag, so the guest cursor was dragged off the double-click pixel
// and the second click stopped counting (win311, 2026-08-05).
describe('tap quantiser — wobble is measured from the real contact point', () => {
  it('does not forward wobble on a SNAPPED second tap', () => {
    const q = createTapQuantiser();
    const first = at(100, 100);
    q.down(first, 0, 0);
    q.up(first, 40);
    // Second contact 15 CSS px away: reported at the anchor, but sampled here.
    expect(q.down(at(115, 100), 180, 0)).toEqual({ x: first.x, y: first.y, double: true });
    // 1-2 CSS px of wobble around the REAL landing point is still just wobble —
    // even though it is ~17 px from the reported press point.
    expect(q.forward(at(116, 101), 200)).toBe(false);
    expect(q.up(at(116, 101), 220).tapped).toBe(true);
  });

  it('still detects a real drag that starts from a snapped second tap', () => {
    const q = createTapQuantiser();
    q.down(at(100, 100), 0, 0);
    q.up(at(100, 100), 40);
    q.down(at(110, 100), 180, 0); // snapped back to (100,100)
    expect(q.forward(at(160, 100), 200)).toBe(true); // 50 CSS px from where it landed
    expect(q.up(at(160, 100), 260).tapped).toBe(false);
  });
});

// Hover muting is module state in input/penContact, driven by the same contacts
// the quantiser sees. Measured cause (win311, 2026-08-05): the daemon applied
// queued hover moves BETWEEN the buttons of a double-click burst — atMove
// advanced 1072/1074/1076/1079 — which re-armed its button guard and dragged
// the cursor off the pixel the pair was aimed at.
describe('pen hover muting around a contact', () => {
  it('mutes on press and keeps muting past the release', async () => {
    const { penHoverMuted, penPress, penRelease } = await import('./penContact');
    const sent: string[] = [];
    const control = {
      sendMouseButton: (b: number, down: boolean) => sent.push(`${down ? 'down' : 'up'}${b}`),
    } as never;
    const q = createTapQuantiser();

    penPress(control, q, 0, at(10, 10), 1000);
    expect(penHoverMuted(1100)).toBe(true); // during the contact
    penRelease(control, q, 0, at(10, 10), 1040);
    // The second tap of a double-tap lands ~160-200 ms after this release —
    // exactly the window that must stay quiet.
    expect(penHoverMuted(1200)).toBe(true);
    expect(penHoverMuted(1539)).toBe(true); // still inside the double-tap window
    expect(penHoverMuted(1600)).toBe(false); // …and hover resumes after it closes

    // A DRAG is not a tap: no double-click can follow it, and it is exactly when
    // the pen is moving — so the release must CLEAR the mute, not extend it.
    penPress(control, q, 0, at(10, 10), 2000);
    q.forward(at(200, 200), 2020); // travels far past dragEscapePx
    penRelease(control, q, 0, at(200, 200), 2050);
    expect(penHoverMuted(2060)).toBe(false);
  });
});

// A native `contextmenu` is either the S-Pen BARREL or Android's own long-press,
// and getting it wrong breaks a different interaction each way: treat them all
// as barrel presses and a right button lands in the middle of a legitimate left
// drag (the guest sees buttons 1+3 and 4Dwm abandons the drag — measured as
// mask=0x05 in the daemon telemetry, 2026-08-05); treat none of them as a barrel
// and a stylus can never open IRIX's spring-loaded root menu.
describe('contextmenu — barrel press vs Android long-press', () => {
  // Every case here is a PEN. `pointerType` is stated explicitly because it is
  // the first thing the decision reads: a finger takes the separate path below.
  const base = {
    pointerType: 'pen', heldContact: true, sinceContactMs: 0, sincePointerRightMs: Infinity,
  };

  it('a contextmenu right after contact is the BARREL — convert the contact', async () => {
    const { contextMenuAction, BARREL_WINDOW_MS } = await import('./penRightClick');
    // A barrel-held tap fires as soon as the tip registers: the barrel was
    // already down before the pen touched.
    expect(contextMenuAction({ ...base, sinceContactMs: 0 })).toBe('convert');
    expect(contextMenuAction({ ...base, sinceContactMs: 100 })).toBe('convert');
    expect(contextMenuAction({ ...base, sinceContactMs: BARREL_WINDOW_MS })).toBe('convert');
  });

  // THE BUG THAT SHIPPED. The first attempt fed this an EVENT-timeStamp delta,
  // and Chrome-Android gives a long-press contextmenu the timeStamp of the
  // pointerdown it was synthesized from — captured live on the user's device as
  // ["d",131704,...] followed by ["X",131704,...] across a 3-SECOND contact. So
  // every long-press measured 0 ms and converted, which is exactly what the user
  // saw. The caller must read performance.now() in the handler; this test is
  // what fails if someone reaches for e.timeStamp again.
  it('0 ms is only the barrel because the clock is handler-read, not the event', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    // A real half-second hold, measured properly, is NOT a barrel press…
    expect(contextMenuAction({ ...base, sinceContactMs: 500 })).toBe('ignore');
    // …and the same gesture measured off the copied timeStamp would look like 0.
    expect(contextMenuAction({ ...base, sinceContactMs: 0 })).toBe('convert');
  });

  it('a contextmenu deep into a contact is Android long-press — ignore it', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    // ~500 ms is Android's own gesture. Injecting a right button here is what
    // made "grab a window, hold still, then move" let go of the window.
    expect(contextMenuAction({ ...base, sinceContactMs: 500 })).toBe('ignore');
    expect(contextMenuAction({ ...base, sinceContactMs: 2000 })).toBe('ignore');
  });

  it('a barrel press with nothing held is a standalone right-click', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    expect(contextMenuAction({ ...base, heldContact: false })).toBe('synth');
  });

  it('never doubles a real mouse right-click, which fires both events', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    expect(contextMenuAction({ ...base, heldContact: false, sincePointerRightMs: 10 })).toBe('ignore');
    expect(contextMenuAction({ ...base, heldContact: false, sinceCtxSynthMs: 10 })).toBe('ignore');
  });

  // A UA that dispatches contextmenu as a plain MouseEvent (no pointerType) is a
  // desktop mouse: the pen logic is what it always was, so nothing regresses on
  // a browser that does not tag the event.
  it('an untagged contextmenu keeps the pre-pointerType behaviour', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    const untagged = { ...base, pointerType: undefined };
    expect(contextMenuAction({ ...untagged, heldContact: false })).toBe('synth');
    expect(contextMenuAction({ ...untagged, sinceContactMs: 0 })).toBe('convert');
    expect(contextMenuAction({ ...untagged, sinceContactMs: 900 })).toBe('ignore');
  });
});

// THE FINGER. Reported live on Android at /os/rhapsody (2026-08-23): a long tap
// performed a secondary click in the guest. A finger has no barrel button, so
// there is no gesture it can make that SHOULD produce one — the arm badge is
// the only touch route to a right button, and that one never reaches this
// function at all. What made it fire was the shape of `heldContact`: it is
// `penDownBtn.size > 0` in the caller and a finger contact lives in the touch
// recognizer instead, so a long-press looked identical to a hovering pen and
// took the `synth` shortcut BEFORE the 250 ms barrel gate was consulted.
describe('contextmenu — a finger never produces a right button', () => {
  const finger = {
    pointerType: 'touch', heldContact: false, sinceContactMs: 0, sincePointerRightMs: Infinity,
  };

  // The exact shape captured on the operator's device: the contextmenu arrived
  // 593 ms into a live contact, with the contact untracked here so heldContact
  // was false. This is the regression case — it returned 'synth' before the fix.
  it('a long-press during an untracked finger contact is ignored', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    expect(contextMenuAction({ ...finger, sinceContactMs: 593 })).toBe('ignore');
  });

  // Even when a pen contact happens to be tracked concurrently, a TOUCH
  // contextmenu is still the OS gesture and must not convert that contact.
  it('a long-press while a contact IS tracked is ignored, not converted', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    expect(contextMenuAction({ ...finger, heldContact: true, sinceContactMs: 600 })).toBe('ignore');
    // And not even inside the barrel window: 0 ms from a finger is still a finger.
    expect(contextMenuAction({ ...finger, heldContact: true, sinceContactMs: 0 })).toBe('ignore');
  });

  // A fast tap that still trips the OS gesture, and a very long hold: no timing
  // a finger can produce is a barrel press.
  it('no finger timing is ever a barrel press', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    for (const sinceContactMs of [0, 100, 250, 500, 593, 3000]) {
      expect(contextMenuAction({ ...finger, sinceContactMs })).toBe('ignore');
      expect(contextMenuAction({ ...finger, heldContact: true, sinceContactMs })).toBe('ignore');
    }
  });

  // Same input arriving as auxclick rather than contextmenu.
  it('a finger auxclick is ignored too', async () => {
    const { contextMenuAction } = await import('./penRightClick');
    expect(contextMenuAction({ ...finger, sinceContactMs: 593, sinceCtxSynthMs: Infinity }))
      .toBe('ignore');
  });
});

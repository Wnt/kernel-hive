// Unit coverage for the PURE trackpad engine (T-3): relative-motion delta
// accumulation scaled by the picture's own resolution, the abs virtual-cursor
// integrator with clamping, tap-at-cursor, the deferred tap release that makes
// tap-then-hold a drag, and the ⊕ armed right button. DOM-free — the hook only
// supplies the release timer, the measurements and the control handle.
import { describe, expect, it } from 'vitest';
import { createTrackpad } from './trackpad';

const ID = 1;

describe('trackpad — relative (guest draws its own cursor)', () => {
  it('a drag past the slop ships a scaled RelMotion; a still tap is a bare click', () => {
    const tp = createTrackpad({ rel: true, gain: 2, track: 1 });
    tp.begin(ID, 0, 0, 0);
    // 20px travel > 8px slop → a drag; delta 20 × gain 2 → dx 40.
    expect(tp.move(ID, 20, 0)).toEqual([{ kind: 'rel', dx: 40, dy: 0 }]);
    // rel tiles never carry coords on the click — the guest owns its cursor.
    const tp2 = createTrackpad({ rel: true });
    tp2.begin(ID, 10, 10, 0);
    expect(tp2.end(ID, 90)).toEqual([{ kind: 'button', button: 0, down: true }]);
    expect(tp2.tapRelease()).toEqual([{ kind: 'button', button: 0, down: false }]);
    expect(tp2.cursor()).toBeNull();
  });

  it('the picture scale sets the speed, so a swipe covers the same GLASS anywhere', () => {
    // 3 guest px to a CSS px (a 1288-wide exhibit on a phone): 10 px of finger
    // is 30 guest px, which is 10 px of picture. The same swipe on a 640-wide
    // exhibit sends 16 — also 10 px of picture. Before this, both sent the same
    // guest delta and the low-res tile's pointer bolted.
    const tp = createTrackpad({ rel: true, gain: 1, track: 3 });
    tp.begin(ID, 0, 0, 0);
    expect(tp.move(ID, 10, 0)).toEqual([{ kind: 'rel', dx: 30, dy: 0 }]);
    const low = createTrackpad({ rel: true, gain: 1, track: 1.6 });
    low.begin(ID, 0, 0, 0);
    expect(low.move(ID, 10, 0)).toEqual([{ kind: 'rel', dx: 16, dy: 0 }]);
  });

  it('setTrack re-reads it per contact (a guest can change resolution)', () => {
    const tp = createTrackpad({ rel: true, gain: 1, track: 1 });
    tp.setTrack(4);
    tp.begin(ID, 0, 0, 0);
    expect(tp.move(ID, 10, 0)).toEqual([{ kind: 'rel', dx: 40, dy: 0 }]);
  });

  it('accumulates the fractional remainder so sub-pixel motion is never dropped', () => {
    const tp = createTrackpad({ rel: true, gain: 0.5, track: 1 });
    tp.begin(ID, 0, 0, 0);
    expect(tp.move(ID, 20, 0)).toEqual([{ kind: 'rel', dx: 10, dy: 0 }]); // crosses slop
    expect(tp.move(ID, 23, 0)).toEqual([{ kind: 'rel', dx: 1, dy: 0 }]); // 3×0.5=1.5 → 1, rem .5
    expect(tp.move(ID, 26, 0)).toEqual([{ kind: 'rel', dx: 2, dy: 0 }]); // .5 + 1.5 = 2.0 → 2
  });

  it('holds motion emission until past the slop (a tap does not twitch the cursor)', () => {
    const tp = createTrackpad({ rel: true, gain: 4, track: 1 });
    tp.begin(ID, 0, 0, 0);
    expect(tp.move(ID, 2, 0)).toEqual([]); // 2px < 8px slop → nothing yet
  });

  it('an armed contact taps with the RIGHT button (no coords — the guest owns its cursor)', () => {
    const tp = createTrackpad({ rel: true });
    tp.begin(ID, 5, 5, 0, true);
    expect(tp.end(ID, 100)).toEqual([{ kind: 'button', button: 2, down: true }]);
    expect(tp.tapRelease()).toEqual([{ kind: 'button', button: 2, down: false }]);
  });

  it('a long hold is not a click at all — a tap is short and still', () => {
    const tp = createTrackpad({ rel: true });
    tp.begin(ID, 5, 5, 0);
    expect(tp.end(ID, 5000)).toEqual([]);
    expect(tp.tapRelease()).toEqual([]); // …and nothing is left pending
  });
});

describe('trackpad — absolute (local virtual cursor + sprite)', () => {
  it('seeds the cursor centred and drives sendMouseMove at the clamped sprite', () => {
    const seen: { x: number; y: number }[] = [];
    const tp = createTrackpad({ rel: false, gain: 1, track: 1, onCursor: (c) => seen.push({ ...c }) });
    tp.setBounds({ w: 100, h: 100 });
    tp.begin(ID, 50, 50, 0);
    expect(tp.cursor()).toEqual({ x: 50, y: 50 }); // centred seed
    expect(tp.move(ID, 52, 50)).toEqual([]); // 2px < slop → cursor unmoved
    expect(tp.cursor()).toEqual({ x: 50, y: 50 });
    expect(tp.move(ID, 60, 50)).toEqual([{ kind: 'move', x: 58, y: 50 }]); // +8 past slop
    expect(tp.cursor()).toEqual({ x: 58, y: 50 });
    // The seed is PUBLISHED too, so the sprite is visible before the first drag.
    expect(seen).toEqual([{ x: 50, y: 50 }, { x: 58, y: 50 }]);
  });

  it('setCursor places the sprite where the guest pointer is (a mode switch)', () => {
    const seen: { x: number; y: number }[] = [];
    const tp = createTrackpad({ rel: false, onCursor: (c) => seen.push({ ...c }) });
    tp.setBounds({ w: 100, h: 100 });
    tp.setCursor({ x: 900, y: 20 }); // clamped into the guest bounds
    expect(tp.cursor()).toEqual({ x: 99, y: 20 });
    expect(seen).toEqual([{ x: 99, y: 20 }]);
    // …and the first click carries that position, since nothing has been sent.
    tp.begin(ID, 0, 0, 0);
    expect(tp.end(ID, 50)[0]).toEqual({ kind: 'button', button: 0, down: true, x: 99, y: 20 });
  });

  it('rel tiles have no local cursor to place', () => {
    const tp = createTrackpad({ rel: true });
    tp.setCursor({ x: 10, y: 10 });
    expect(tp.cursor()).toBeNull();
  });

  it('zooming in buys FINER control: the gain divides by the magnification', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 1000, h: 1000 });
    tp.setScale(2); // pinched to 2× — a guest px is twice as wide on glass
    tp.begin(ID, 0, 0, 0);
    // 40 CSS px of finger → 20 guest px, so the crosshair keeps up with the
    // finger ON GLASS instead of running away across the magnified picture.
    expect(tp.move(ID, 40, 0)).toEqual([{ kind: 'move', x: 520, y: 500 }]);
  });

  it('a bad scale can never divide the gain away', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 1000, h: 1000 });
    tp.setScale(0);
    tp.begin(ID, 0, 0, 0);
    expect(tp.move(ID, 40, 0)).toEqual([{ kind: 'move', x: 540, y: 500 }]);
  });

  it('clamps the cursor to the guest bounds', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 80 });
    tp.begin(ID, 0, 0, 0); // cursor seeds to (50,40)
    expect(tp.move(ID, 400, -400)).toEqual([{ kind: 'move', x: 99, y: 0 }]);
  });

  it('a tap clicks at the current cursor (not at the fingertip)', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tp.begin(ID, 10, 10, 0);
    expect(tp.end(ID, 80)).toEqual([{ kind: 'button', button: 0, down: true, x: 50, y: 50 }]);
    // The release carries NO coords: the guest pointer is already there, and
    // re-stating it re-arms the daemon's button guard between the halves of a
    // double-click.
    expect(tp.tapRelease()).toEqual([{ kind: 'button', button: 0, down: false }]);
  });

  it('re-states the position only when the cursor moved since the last send', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tp.begin(ID, 0, 0, 0);
    tp.move(ID, 20, 0); // a move op puts the guest AT the cursor…
    tp.end(ID, 400); // …too slow for a tap → no click
    tp.begin(ID, 0, 0, 500);
    // …so this click needs no coords at all
    expect(tp.end(ID, 550)).toEqual([{ kind: 'button', button: 0, down: true }]);
    expect(tp.tapRelease()).toEqual([{ kind: 'button', button: 0, down: false }]);
  });
});

describe('trackpad — tap-then-hold is a drag, on a DEFERRED release', () => {
  const tap = (tp: ReturnType<typeof createTrackpad>, t: number) => {
    tp.begin(ID, 10, 10, t);
    return tp.end(ID, t + 60);
  };

  it('a tap sends its DOWN and nothing else until the deadline', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    expect(tap(tp, 0)).toEqual([{ kind: 'button', button: 0, down: true, x: 50, y: 50 }]);
    expect(tp.tapRelease()).toEqual([{ kind: 'button', button: 0, down: false }]);
    expect(tp.tapRelease()).toEqual([]); // …and only once
  });

  it('the next contact INHERITS the held button — the guest never sees a pair', () => {
    // The regression this exists for (win311, 2026-08-05): releasing the tap
    // immediately put down/up/down at one spot inside the guest's double-click
    // window, and it read a double-click-and-drag. Deferring the up removes the
    // middle edge, so there is nothing to pair.
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tap(tp, 0);
    expect(tp.begin(ID, 10, 10, 200)).toEqual([]); // no up, no second down
    expect(tp.move(ID, 30, 10)).toEqual([{ kind: 'move', x: 70, y: 50 }]); // drags
    expect(tp.end(ID, 900)).toEqual([{ kind: 'button', button: 0, down: false }]);
    expect(tp.tapRelease()).toEqual([]); // the pending release was consumed
  });

  it('…but a second TAP is a double-click, so the held click is closed + repeated', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tap(tp, 0);
    tp.begin(ID, 10, 10, 200);
    expect(tp.end(ID, 260)).toEqual([
      { kind: 'button', button: 0, down: false }, // closes click 1
      { kind: 'button', button: 0, down: true },  // …and click 2 in full
      { kind: 'button', button: 0, down: false },
    ]);
  });

  it('a contact that arrives after the release is an ordinary tap', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tap(tp, 0);
    tp.tapRelease(); // the deadline passed with nobody waiting
    expect(tp.begin(ID, 10, 10, 900)).toEqual([]);
    expect(tp.end(ID, 960)).toEqual([{ kind: 'button', button: 0, down: true }]);
  });

  it('the ⊕ arm chooses what the drag holds (right press-drag-release)', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tp.begin(ID, 10, 10, 0, true); // armed
    expect(tp.end(ID, 60)).toEqual([{ kind: 'button', button: 2, down: true, x: 50, y: 50 }]);
    tp.begin(ID, 10, 10, 200);
    expect(tp.move(ID, 30, 10)).toEqual([{ kind: 'move', x: 70, y: 50 }]);
    expect(tp.end(ID, 900)).toEqual([{ kind: 'button', button: 2, down: false }]);
  });

  it('a STOLEN touch releases the button — dragging or merely pending', () => {
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    tap(tp, 0);
    tp.begin(ID, 10, 10, 200); // now dragging
    expect(tp.cancel()).toEqual([{ kind: 'button', button: 0, down: false }]);
    expect(tp.cancel()).toEqual([]);
    // …and a pinch that steals the glass between the tap and its release: no
    // contact remains to close that click, so cancel has to.
    tap(tp, 1000);
    expect(tp.cancel()).toEqual([{ kind: 'button', button: 0, down: false }]);
  });

  it('reports that it is holding a button, so the stuck-button guard leaves it alone', () => {
    // The hook heals a stranded button at every contact, and between a tap and
    // its deferred release this engine looks exactly like one. Healing it blind
    // sent the up that tap-then-hold exists to withhold — the drag then held
    // nothing and only glided the cursor.
    const tp = createTrackpad({ rel: false, gain: 1, track: 1 });
    tp.setBounds({ w: 100, h: 100 });
    expect(tp.holds()).toBe(false);
    tap(tp, 0);
    expect(tp.holds()).toBe(true); // …the pending release
    tp.begin(ID, 10, 10, 200);
    expect(tp.holds()).toBe(true); // …now a live drag
    tp.end(ID, 900);
    expect(tp.holds()).toBe(false);
  });

  it('publishes the held state so the sprite can show the drag took', () => {
    const held: boolean[] = [];
    const tp = createTrackpad({ rel: false, onHold: (h) => held.push(h) });
    tp.setBounds({ w: 100, h: 100 });
    tap(tp, 0);
    expect(held).toEqual([]); // a plain tap is not a drag
    tp.begin(ID, 10, 10, 200);
    tp.end(ID, 900);
    expect(held).toEqual([true, false]);
  });

  it('rel tiles drag the same way, with no coordinates', () => {
    const tp = createTrackpad({ rel: true, gain: 1, track: 1 });
    tp.begin(ID, 0, 0, 0);
    expect(tp.end(ID, 60)).toEqual([{ kind: 'button', button: 0, down: true }]);
    tp.begin(ID, 0, 0, 200);
    expect(tp.move(ID, 20, 0)).toEqual([{ kind: 'rel', dx: 20, dy: 0 }]);
    expect(tp.end(ID, 400)).toEqual([{ kind: 'button', button: 0, down: false }]);
  });
});

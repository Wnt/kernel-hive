// Unit coverage for the DIRECT touch/pen pointer engine: press → button down,
// move while held, release → button up (mouse-like, so drawing/dragging just
// works), the one-shot right-click arm + S-Pen barrel, the intent → primitive-op
// mapping, and the two-finger pinch-vs-scroll arbitration. All DOM-free.
import { describe, expect, it } from 'vitest';
import {
  classifyTwoFinger,
  createRecognizer,
  intentToOps,
  scrollWheelDelta,
  type GestureIntent,
} from './touchGestures';

const ID = 1;
const types = (i: GestureIntent[]) => i.map((x) => x.type);

/** Guest px per CSS px — the recognizer is fed both, and the tap quantiser it
 *  drives measures in CSS. 3 is IRIX-like (1288 guest px across a 411 px rect),
 *  so `tapPx` 12 CSS = 36 guest and `dragEscapePx` 30 CSS = 90 guest here. */
const SCALE = 3;
/** A sample at a GUEST point, carrying the CSS point the letterbox mapped from. */
const s = (x: number, y: number, t: number, id = ID) =>
  ({ id, x, y, cx: x / SCALE, cy: y / SCALE, t });

describe('recognizer — direct press/move/release', () => {
  it('press sends button-0 DOWN immediately; move drags; release sends UP', () => {
    const r = createRecognizer();
    expect(r.begin(s(100, 50, 0))).toEqual([
      { type: 'down', button: 0, x: 100, y: 50 }, // button held on contact (draw starts here)
    ]);
    expect(r.move(s(400, 52, 10))).toEqual([{ type: 'move', x: 400, y: 52 }]);
    expect(r.move(s(440, 54, 20))).toEqual([{ type: 'move', x: 440, y: 54 }]);
    expect(r.end(s(440, 54, 30))).toEqual([
      { type: 'up', button: 0, x: 440, y: 54 },
    ]);
  });

  it('a tap (no movement) is a clean down+up at the same px — never stuck', () => {
    const r = createRecognizer();
    r.begin(s(12, 12, 0));
    expect(r.end(s(12, 12, 40))).toEqual([{ type: 'up', button: 0, x: 12, y: 12 }]);
  });

  // Two quick taps stay two real clicks — but QUANTISED onto one pixel, which is
  // what the guest's own timer needs to pair them (measured win311/IRIX).
  it('two quick taps are two real clicks on one pixel', () => {
    const r = createRecognizer();
    expect(types(r.begin(s(5, 5, 0)))).toEqual(['down']);
    expect(types(r.end(s(5, 5, 40)))).toEqual(['up']);
    expect(types(r.begin(s(6, 5, 120)))).toEqual(['down']);
    expect(types(r.end(s(6, 5, 150)))).toEqual(['up']);
  });

  // The pen caveat: real S-Pen samples from an IRIX session (clientlog drag-tel,
  // 2026-08-05). Two taps 191 ms apart landed 4 px apart and each wandered while

  it('quantises a real S-Pen double-tap onto one pixel', () => {
    const r = createRecognizer();
    // Tap 1: contact [1136,753], wobbles to [1136,755], lifts.
    expect(r.begin(s(1136, 753, 0))).toEqual([
      { type: 'down', button: 0, x: 1136, y: 753 },
    ]);
    expect(r.move(s(1136, 754, 30))).toEqual([]); // wobble, not a drag
    expect(r.move(s(1136, 755, 60))).toEqual([]);
    expect(r.end(s(1136, 755, 94))).toEqual([
      { type: 'up', button: 0, x: 1136, y: 753 }, // lifts where it landed
    ]);
    // Tap 2: contact [1138,759] — 4 px away, 191 ms later. Snaps onto tap 1, so
    // the guest gets two clicks on ONE pixel and pairs them itself.
    expect(r.begin(s(1138, 759, 191))).toEqual([
      { type: 'down', button: 0, x: 1136, y: 753 },
    ]);
    expect(r.end(s(1138, 759, 241))).toEqual([
      { type: 'up', button: 0, x: 1136, y: 753 },
    ]);
  });

  it('snaps the widest measured pen scatter (12 px) but not a deliberate move', () => {
    const r = createRecognizer();
    r.begin(s(1140, 751, 0));
    r.end(s(1139, 751, 81));
    // 12 px away, 188 ms later — the pair-B sample. Still one double-click.
    expect(r.begin(s(1151, 748, 188))[0]).toEqual(
      { type: 'down', button: 0, x: 1140, y: 751 },
    );
    r.end(s(1151, 750, 240));
    // A tap somewhere else entirely is its own click, not a snapped one.
    expect(r.begin(s(1400, 300, 300))).toEqual([
      { type: 'down', button: 0, x: 1400, y: 300 },
    ]);
  });

  it('a slow second tap is a separate click, not a double', () => {
    const r = createRecognizer();
    r.begin(s(500, 500, 0));
    r.end(s(500, 500, 50));
    expect(r.begin(s(502, 501, 1200))).toEqual([
      { type: 'down', button: 0, x: 502, y: 501 },
    ]);
  });

  // The property the 2026-07 revert protects: a drag must not be deferred.
  it('a drag still moves on the first sample past the slop, and lands under the pointer', () => {
    const r = createRecognizer();
    r.begin(s(100, 100, 0));
    expect(r.move(s(102, 100, 8))).toEqual([]); // 2 px: wobble
    // Past dragEscapePx 8 ms in — the very sample that crosses it is forwarded,
    // unaltered, without waiting out the tap hold.
    expect(r.move(s(300, 100, 16))).toEqual([{ type: 'move', x: 300, y: 100 }]);
    // …and from here nothing is filtered, however small the step.
    expect(r.move(s(301, 100, 24))).toEqual([{ type: 'move', x: 301, y: 100 }]);
    expect(r.end(s(301, 100, 32))).toEqual([
      { type: 'up', button: 0, x: 301, y: 100 },
    ]);
  });

  it('a press right after a DRAG is never snapped backwards', () => {
    const r = createRecognizer();
    r.begin(s(10, 10, 0));
    r.move(s(300, 300, 20));
    r.end(s(300, 300, 40));
    expect(r.begin(s(305, 302, 80))).toEqual([
      { type: 'down', button: 0, x: 305, y: 302 },
    ]);
  });

  it('a right-click tap does not anchor a following left double-tap', () => {
    const r = createRecognizer();
    r.begin(s(60, 60, 0), true);
    r.end(s(60, 60, 30));
    expect(r.begin(s(63, 61, 100))).toEqual([
      { type: 'down', button: 0, x: 63, y: 61 },
    ]);
  });

  it('a cancelled touch leaves no anchor behind', () => {
    const r = createRecognizer();
    r.begin(s(70, 70, 0));
    r.cancel();
    expect(r.begin(s(72, 71, 60))).toEqual([
      { type: 'down', button: 0, x: 72, y: 71 },
    ]);
  });

  it('an S-Pen barrel press (right=true) sends button 2', () => {
    const r = createRecognizer();
    expect(r.begin(s(3, 3, 0), true)).toEqual([
      { type: 'down', button: 2, x: 3, y: 3 },
    ]);
    expect(r.end(s(3, 3, 20))).toEqual([{ type: 'up', button: 2, x: 3, y: 3 }]);
  });

  it('arming right-click makes the NEXT press a one-shot button-2, then disarms', () => {
    let armChanges = 0;
    const r = createRecognizer({ onChange: () => { armChanges++; } });
    r.setArm('right-click');
    expect(r.getArm()).toBe('right-click');
    expect(r.begin(s(8, 8, 0))).toEqual([{ type: 'down', button: 2, x: 8, y: 8 }]);
    expect(r.getArm()).toBe('none'); // consumed
    expect(r.end(s(8, 8, 20))).toEqual([{ type: 'up', button: 2, x: 8, y: 8 }]);
    expect(armChanges).toBeGreaterThan(0); // onChange fired for the badge
  });

  it('cancel releases the held button at its last px (2nd finger stole it for a pinch)', () => {
    const r = createRecognizer();
    r.begin(s(40, 40, 0));
    r.move(s(240, 40, 20));
    expect(r.cancel()).toEqual([{ type: 'up', button: 0, x: 240, y: 40 }]);
    expect(r.cancel()).toEqual([]); // nothing left to release
  });

  it('move/end for a different pointer id are ignored (only the held touch matters)', () => {
    const r = createRecognizer();
    r.begin(s(0, 0, 0));
    expect(r.move(s(5, 5, 10, 99))).toEqual([]);
    expect(r.end(s(5, 5, 20, 99))).toEqual([]);
    expect(r.end(s(0, 0, 30))).toEqual([{ type: 'up', button: 0, x: 0, y: 0 }]);
  });
});

describe('intentToOps', () => {
  it('maps down/up with the carried button, and move straight through', () => {
    expect(intentToOps({ type: 'down', button: 0, x: 3, y: 4 })).toEqual([
      { kind: 'button', button: 0, down: true, x: 3, y: 4 },
    ]);
    expect(intentToOps({ type: 'up', button: 2, x: 3, y: 4 })).toEqual([
      { kind: 'button', button: 2, down: false, x: 3, y: 4 },
    ]);
    expect(intentToOps({ type: 'move', x: 3, y: 4 })).toEqual([{ kind: 'move', x: 3, y: 4 }]);
  });
});

describe('classifyTwoFinger — pinch vs scroll arbitration', () => {
  const A = { x: 100, y: 100 };
  const B = { x: 200, y: 100 };

  it('is undecided in the first few ms with no meaningful movement', () => {
    expect(classifyTwoFinger(A, B, A, B, 5)).toBe('undecided');
  });

  it('classifies a spreading pinch (distance change dominates)', () => {
    const a1 = { x: 70, y: 100 };
    const b1 = { x: 230, y: 100 };
    expect(classifyTwoFinger(A, B, a1, b1, 50)).toBe('pinch');
  });

  it('classifies a parallel two-finger drag as scroll (translation dominates)', () => {
    const a1 = { x: 100, y: 140 };
    const b1 = { x: 200, y: 140 };
    expect(classifyTwoFinger(A, B, a1, b1, 50)).toBe('scroll');
  });

  it('stays PINCH when the two signals are ambiguous (conservative default)', () => {
    const a1 = { x: 92, y: 118 };
    const b1 = { x: 214, y: 118 };
    expect(classifyTwoFinger(A, B, a1, b1, 50)).toBe('pinch');
  });
});

describe('scrollWheelDelta', () => {
  it('fingers moving UP produce a positive deltaY (mouse-wheel-down sense)', () => {
    const d = scrollWheelDelta({ x: 0, y: 100 }, { x: 0, y: 60 });
    expect(d.y).toBeGreaterThan(0);
    expect(d).toEqual({ x: 0, y: 40 });
  });

  it('fingers moving DOWN produce a negative deltaY', () => {
    expect(scrollWheelDelta({ x: 0, y: 60 }, { x: 0, y: 100 }).y).toBeLessThan(0);
  });
});

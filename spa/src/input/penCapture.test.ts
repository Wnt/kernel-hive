// REAL HAND DATA, replayed. Every other test in this directory is hand-written
// from a theory of how a stylus behaves; this one replays 824 contacts and 457
// taps actually captured from the user's S-Pen on win311 and IRIX (harvested out
// of the live clientlog, 2026-08-05 — see __fixtures__/pen-capture.json).
//
// It exists so the thresholds can never again be tuned by feel alone: a change
// that makes taps easier to lose shows up here as a number, without anyone
// having to sit and reproduce clicks on a phone.
//
// What the fixture carries per contact is what a threshold decision actually
// needs — `rw`, the CSS-px extent the contact wandered, and `dur`, how long it
// lasted. `rw` is null when the contact forwarded NOTHING, i.e. it was already a
// clean tap. The replay drives the real createTapQuantiser rather than restating
// its rules, and it puts the wander at the END of the contact, which is both
// realistic (a hand drifts progressively) and the least favourable reading for
// the hold — so every number below is a lower bound.
import { describe, expect, it } from 'vitest';
import capture from './__fixtures__/pen-capture.json';
import { createTapQuantiser, TAP } from './tapQuantiser';

interface Contact { tile: string; dur: number; raw: number; fwd: number; rw: number | null }

const contacts = capture.contacts as Contact[];
const taps = capture.taps as { tile: string; dbl: boolean; gapMs: number | null }[];

/** Replay one captured contact through the real quantiser; did it stay a tap? */
function replay(c: Contact): boolean {
  const q = createTapQuantiser();
  q.down({ x: 0, y: 0, cx: 0, cy: 0 }, 0, 0);
  if (c.rw != null) q.forward({ x: 0, y: 0, cx: c.rw, cy: 0 }, c.dur);
  return q.up({ x: 0, y: 0, cx: c.rw ?? 0, cy: 0 }, c.dur).tapped;
}

const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

describe('captured S-Pen contacts — the thresholds, against real hands', () => {
  it('the fixture is the real capture, not a stub', () => {
    expect(contacts.length).toBeGreaterThan(800);
    expect(taps.length).toBeGreaterThan(400);
    expect(new Set(contacts.map((c) => c.tile))).toContain('irix');
  });

  // THE HEADLINE. These are contacts that leaked movement to the guest under the
  // old guest-pixel thresholds — every one of them a chance for an icon to slide
  // instead of open. Most were never meant as drags.
  it('rescues most of the contacts that used to leak movement into the guest', () => {
    const leaked = contacts.filter((c) => c.fwd > 0);
    const rescued = leaked.filter(replay);
    expect(leaked.length).toBeGreaterThan(500); // the capture really is full of them
    // 77% at the shipped thresholds. Pinned a little under, so ordinary drift in
    // the numbers is allowed but a real tightening of tapPx/tapHoldMs fails here.
    expect(rescued.length / leaked.length).toBeGreaterThan(0.75);
  });

  // …and the other half of the bargain: a quantiser that swallows everything
  // would score 100% above and make the gallery undraggable.
  it('never swallows a deliberate drag', () => {
    const deliberate = contacts.filter((c) => c.rw != null && c.rw > 2 * TAP.dragEscapePx);
    expect(deliberate.length).toBeGreaterThan(50);
    expect(deliberate.filter(replay)).toEqual([]);
  });

  it('a contact that both travels and lasts is a drag, however it started', () => {
    const slow = contacts.filter((c) => c.rw != null && c.rw > TAP.dragEscapePx && c.dur >= TAP.tapHoldMs);
    expect(slow.length).toBeGreaterThan(50);
    expect(slow.filter(replay)).toEqual([]);
  });

  it('the contacts still read as drags are long and far, not near-misses', () => {
    const stillDrag = contacts.filter((c) => c.fwd > 0 && !replay(c));
    expect(median(stillDrag.map((c) => c.rw!))).toBeGreaterThan(2 * TAP.tapPx);
    expect(median(stillDrag.map((c) => c.dur))).toBeGreaterThan(TAP.tapHoldMs);
  });
});

// The double-tap window is NOT the binding constraint, and this is the evidence.
// Our doubleMs only decides whether to snap the second tap onto the first; the
// GUEST still has to pair the two clicks with its own timer, and IRIX's Motif is
// ~200-250 ms — tighter than the human gaps measured here at the top end.
describe('captured double-taps — where the remaining limit actually is', () => {
  const gaps = taps.filter((t) => t.dbl && t.gapMs != null).map((t) => t.gapMs!);

  it('every recognised double-tap fits inside our own window', () => {
    expect(gaps.length).toBeGreaterThan(100);
    expect(Math.max(...gaps)).toBeLessThanOrEqual(TAP.doubleMs);
  });

  it('a real double-tap is ~180 ms, which Motif can only just pair', () => {
    expect(median(gaps)).toBeGreaterThan(120);
    expect(median(gaps)).toBeLessThan(260);
    // The tail is the part no client change reaches: these were snapped onto one
    // pixel by us and can still be refused by a 200 ms guest timer. If IRIX
    // double-clicks stay marginal after this work, the fix is the guest's own
    // mouse setting, not another threshold here.
    expect(gaps.filter((g) => g > 200).length).toBeGreaterThan(0);
  });
});

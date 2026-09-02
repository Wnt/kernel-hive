import { describe, expect, it } from 'vitest';
import { LossLedger, REORDER_GRACE_MS, REOPEN_BACKSTEP, MAX_PENDING } from './lossLedger';

/** Feed a contiguous run of frame_ids at one instant. */
function run(l: LossLedger, from: number, to: number, at: number) {
  for (let id = from; id <= to; id++) l.note(id, at);
}

describe('LossLedger — the join window', () => {
  it('never bills the primed-key → first-IDR hole (the 2026-09-02 first line)', () => {
    // transport/mod.rs: the daemon sends its cached key (423) and then discards
    // every AU until the next real IDR (453). That is 29 frame_ids the client
    // was never sent — and used to report as 86.7 % loss on its first interval.
    const l = new LossLedger();
    l.note(423, 0);
    l.note(453, 10); // the forced IDR
    run(l, 454, 460, 20);
    l.settle(1000);
    expect(l.takeInterval()).toEqual({ received: 9, missed: 0 });
    expect(l.droppedTotal).toBe(0);
  });

  it('closes the join window after the second AU — a later hole IS billed', () => {
    const l = new LossLedger();
    l.note(423, 0);
    l.note(453, 10);
    expect(l.inJoinWindow).toBe(false);
    l.note(458, 20); // 454..457 genuinely missing
    l.settle(20 + REORDER_GRACE_MS);
    expect(l.takeInterval().missed).toBe(4);
  });
});

describe('LossLedger — reordering', () => {
  it('does not bill a hole that fills itself in within the grace', () => {
    const l = new LossLedger();
    run(l, 100, 101, 0);
    l.note(103, 5);          // 102 not here yet
    expect(l.pendingCount).toBe(1);
    l.settle(10);            // still inside the grace
    expect(l.takeInterval()).toEqual({ received: 3, missed: 0 });
    l.note(102, 20);         // late arrival — the decoder will refuse it, the
    expect(l.pendingCount).toBe(0); // ledger must not call it loss
    l.settle(20 + REORDER_GRACE_MS);
    expect(l.takeInterval()).toEqual({ received: 1, missed: 0 });
    expect(l.droppedTotal).toBe(0);
  });

  it('bills a hole that never fills, once the grace expires', () => {
    const l = new LossLedger();
    run(l, 100, 101, 0);
    l.note(105, 5); // 102,103,104 gone for good
    l.settle(5 + REORDER_GRACE_MS - 1);
    expect(l.takeInterval().missed).toBe(0);
    l.settle(5 + REORDER_GRACE_MS);
    expect(l.takeInterval().missed).toBe(3);
    expect(l.droppedTotal).toBe(3);
  });

  it('bills an implausibly large hole immediately rather than tracking it', () => {
    const l = new LossLedger();
    run(l, 100, 101, 0);
    l.note(101 + MAX_PENDING + 50, 5);
    expect(l.pendingCount).toBe(0);
    expect(l.takeInterval().missed).toBe(MAX_PENDING + 49);
  });
});

describe('LossLedger — encoder reopen', () => {
  it('drops the pending set when frame_id restarts at 0 (encode/worker.rs:223)', () => {
    const l = new LossLedger();
    run(l, 5000, 5001, 0);
    l.note(5005, 5);            // holes pending
    expect(l.pendingCount).toBe(3);
    l.note(0, 10);              // reopen: fresh IDR, frame_id back to 0
    expect(l.pendingCount).toBe(0);
    l.settle(10 + REORDER_GRACE_MS);
    expect(l.takeInterval().missed).toBe(0);
    // and the new stream is accounted from the new baseline
    run(l, 1, 3, 20);
    l.settle(20 + REORDER_GRACE_MS);
    expect(l.takeInterval().missed).toBe(0);
  });

  it('treats a small backwards step as reordering, not a reopen', () => {
    const l = new LossLedger();
    run(l, 100, 110, 0);
    l.note(110 - (REOPEN_BACKSTEP - 1), 5); // still "behind", but plausibly late
    l.settle(5 + REORDER_GRACE_MS);
    expect(l.takeInterval().missed).toBe(0);
  });
});

describe('LossLedger — a clean LAN reads zero', () => {
  it('reports no loss at all across a contiguous session', () => {
    const l = new LossLedger();
    for (let t = 0; t < 20; t++) {
      run(l, 1 + t * 10, 10 + t * 10, t * 100);
      l.settle(t * 100);
      expect(l.takeInterval().missed).toBe(0);
    }
    expect(l.droppedTotal).toBe(0);
  });

  it('un-bills frames the server later admits it skipped on purpose', () => {
    const l = new LossLedger();
    run(l, 1, 2, 0);
    l.note(10, 5);
    l.settle(5 + REORDER_GRACE_MS);
    expect(l.droppedTotal).toBe(7);
    l.creditServerSkips(7);
    expect(l.droppedTotal).toBe(0);
    l.creditServerSkips(99); // never negative
    expect(l.droppedTotal).toBe(0);
  });
});

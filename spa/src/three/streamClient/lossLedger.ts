// ============================================================================
//  streamClient/lossLedger — what a frame_id gap is ALLOWED to mean.
//  ---------------------------------------------------------------------------
//  Video AUs travel on RELIABLE QUIC uni-streams (transport/egress.rs
//  `send_au` opens one stream per AU). A stream that is opened is delivered or
//  the connection dies — so on this wire a frame_id gap is almost never
//  "packet loss". It is one of exactly four things, and only the last one is
//  congestion:
//
//    1. THE JOIN WINDOW. On subscribe the daemon sends its freshest CACHED key
//       (transport/mod.rs `primed`), then discards every AU until the next real
//       IDR (the `JoinGate`, transport/mod.rs ~L620-680). Measured on freedos:
//       primed id=423, first broadcast id=453 — a 29-frame hole the client used
//       to bill as 96 % loss on its very first interval. That is the
//       `loss86.7/w86.7n30`, `w50.0n12`, `w71.4n7` first line in the 2026-09-02
//       dossier: 26 phantom misses out of 30 samples, on a 4 ms LAN.
//       The daemon does NOT count these in its skip counter, so skipCredit
//       cannot cover them; the client has to know the shape itself.
//
//    2. REORDERING. One uni-stream per AU means AUs COMPLETE in retransmit
//       order, not frame_id order. Seeing 100 then 102 does not mean 101 is
//       lost — it usually lands a few ms later (and `auGate.isStaleAu` then
//       correctly refuses to DECODE it, which is a different question from
//       whether it ARRIVED). Billing it immediately turned every reorder into
//       loss, and the busier the station the more of them there are — which is
//       why a SECOND viewer made the first viewer's client report 93-96 %.
//
//    3. AN ENCODER REOPEN. frame_id restarts at 0 on every reopen
//       (encode/worker.rs:223). Everything still pending from before the
//       restart will never arrive and is not loss.
//
//    4. A SERVER-INTENTIONAL SKIP (backlog gate / broadcast Lagged). Counted by
//       the daemon and credited back through skipCredit.ts — see there.
//
//  So: a gap is PENDING, not missed. It is confirmed only after
//  REORDER_GRACE_MS with no arrival; anything that turns up in the meantime is
//  retired for free. The join window is never billed at all, and a frame_id
//  restart drops the whole pending set.
//
//  Pure + injectable (auGate.ts / scoring.ts precedent): no VideoDecoder, no
//  StreamClient, no clock of its own — vitest drives it under plain Node.
// ============================================================================

/**
 * How long a missing frame_id may stay missing before it is billed as loss.
 * Long enough to cover per-AU uni-stream completion reordering on a loaded
 * server (measured worst case on a 12 ms LAN with two viewers: tens of ms),
 * short enough that real congestion still shows up inside the 3 s reporting
 * window in abr.ts.
 */
export const REORDER_GRACE_MS = 500;

/**
 * A backwards frame_id step at least this large is an encoder reopen
 * (frame_id → 0), not a reordered AU. Anything smaller is ordinary reordering.
 */
export const REOPEN_BACKSTEP = 64;

/** Hard cap on tracked pending ids — a wild id must not grow the map without
 *  bound. Beyond this the gap is billed immediately (it is not reordering). */
export const MAX_PENDING = 512;

/** What the ABR tick takes off the ledger for the just-closed interval. */
export interface LedgerInterval {
  received: number;
  missed: number;
}

export class LossLedger {
  /** Highest frame_id seen on the wire (received, not necessarily decoded). */
  private highest = -1;
  /** frame_id → performance.now() when the hole was first observed. */
  private pending = new Map<number, number>();
  /**
   * True until the SECOND AU of this session. The gap between AU #1 (the
   * daemon's primed cached key) and AU #2 (the forced IDR that opens the join
   * gate) is a server-side discard, never loss.
   */
  private joining = true;

  private received = 0;
  private missed = 0;

  /** Cumulative confirmed misses — the `dr` field / T_STATS frames_dropped. */
  droppedTotal = 0;

  /** Frames currently waiting out the reorder grace (diagnostics/tests). */
  get pendingCount(): number { return this.pending.size; }
  /** True while the join window is still open (diagnostics/tests). */
  get inJoinWindow(): boolean { return this.joining; }

  /**
   * Record one arriving AU. MUST be called for every AU that reaches the
   * client, including ones the decode gate will refuse as stale — a late AU
   * that is not fed to the decoder still proves nothing was lost.
   */
  note(frameId: number, now: number): void {
    this.received++;
    if (this.highest < 0) {
      // First AU of the session: the primed key. Baseline only.
      this.highest = frameId;
      return;
    }
    // (3) encoder reopen — frame_id restarted; nothing older can still arrive.
    if (frameId <= this.highest - REOPEN_BACKSTEP) {
      this.pending.clear();
      this.highest = frameId;
      this.joining = false;
      return;
    }
    // (2) a hole we were already holding just filled itself in. Free.
    if (this.pending.delete(frameId)) return;
    if (frameId <= this.highest) {
      // Duplicate or a reordered AU from before our baseline — no new hole.
      return;
    }
    const gap = frameId - this.highest - 1;
    if (gap > 0) {
      if (this.joining) {
        // (1) the daemon's join gate. Never billed.
      } else if (gap > MAX_PENDING || this.pending.size + gap > MAX_PENDING) {
        // Far too big to be reordering: bill it now rather than track it.
        this.missed += gap;
        this.droppedTotal += gap;
      } else {
        for (let id = this.highest + 1; id < frameId; id++) this.pending.set(id, now);
      }
    }
    this.highest = frameId;
    this.joining = false;
  }

  /**
   * Promote holes older than the reorder grace to confirmed misses. Called once
   * per ABR tick, before the interval is taken.
   */
  settle(now: number): void {
    if (this.pending.size === 0) return;
    for (const [id, at] of this.pending) {
      if (now - at >= REORDER_GRACE_MS) {
        this.pending.delete(id);
        this.missed++;
        this.droppedTotal++;
      }
    }
  }

  /** Take + reset the per-interval counters. */
  takeInterval(): LedgerInterval {
    const out = { received: this.received, missed: this.missed };
    this.received = 0;
    this.missed = 0;
    return out;
  }

  /**
   * Un-bill `n` frames the SERVER has since admitted it skipped on purpose
   * (skipCredit.ts). The cumulative drop counter must not keep claiming them.
   */
  creditServerSkips(n: number): void {
    if (n > 0) this.droppedTotal = Math.max(0, this.droppedTotal - n);
  }
}

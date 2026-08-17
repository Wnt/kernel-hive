// ============================================================================
//  streamClient/telemetry — the DIAGNOSTIC record behind the Ctrl+N overlay.
//  ---------------------------------------------------------------------------
//  WHY THIS EXISTS. The HUD used to show only INSTANTANEOUS values: `PL 0.0%`,
//  `T3 floor`, `DR 9 / FZ 153`. That is enough to see that something is wrong
//  and nowhere near enough to see WHY, because the events that actually drive
//  the server's ABR decision are ~1 s transients that are long gone by the time
//  a human reads the panel. The 2026-08-17 tru64 investigation (a station
//  cycling 0→1→2→3→0 every 25 s on a flawless LAN) needed three numbers the UI
//  did not have:
//
//    1. The loss PEAK over a recent window, not the current sample.
//    2. The SAMPLE SIZE that peak was computed from. `lossPct` is
//       missed/(received+missed) over a ~100 ms tick; on a 2 fps station that
//       denominator is 0 or 1 frames, so ONE dropped frame reports 100 % loss
//       against the server's 5 % downshift threshold. The percentage is
//       meaningless without its `n`, and the UI never showed `n`.
//    3. WHEN the tier last changed and what the recent trajectory was — a tier
//       history makes flapping self-evident; a single current tier does not.
//
//  So this module keeps a short rolling window (WINDOW_MS) of per-tick samples
//  and a bounded tier-change log, and exposes them as a flat snapshot the
//  overlay renders. It is a PASSIVE RECORDER: it never feeds the scorer, the
//  banner, or the T_STATS datagram, so it cannot influence what it measures.
//
//  It also mirrors the server's RTT-floor tracker (abr.rs `fold`) so the panel
//  can show the `excess` the server ACTUALLY decides on, rather than the raw
//  RTT the server ignores.
// ============================================================================

/** Rolling window for the loss/drop/freeze rates (ms). ~30 ticks at 100 ms. */
const WINDOW_MS = 3000;
/** Bounded tier-change log; older entries are discarded. */
const HISTORY_MAX = 12;
/** How far back the tier-change COUNT in the snapshot reaches (ms). */
const HISTORY_WINDOW_MS = 300_000;
/**
 * Below this many frames, a loss PERCENTAGE is statistically meaningless — one
 * missed frame out of one swings it to 100 %. Mirrors nothing on the server;
 * it exists purely so the overlay can FLAG a percentage that should not be
 * trusted (and, on a low-fps station, should never have moved the tier).
 */
const LOW_CONFIDENCE_FRAMES = 10;
/**
 * The server's downshift threshold (streamhost `abr.rs` DOWN_LOSS_PCT). Mirrored
 * here ONLY to mark, in the overlay, which observed loss peaks were large enough
 * to have driven a tier change. Kept in sync by hand; a drift makes the overlay
 * annotation wrong, never the stream.
 */
const SERVER_DOWN_LOSS_PCT = 5;

/**
 * The server's RTT-excess downshift threshold (streamhost `abr.rs`
 * DOWN_RTT_EXCESS_MS). Mirrored so the overlay can count how many ticks in the
 * window were over it — a spike lasting one keyframe burst is invisible in an
 * instantaneous reading but is exactly what moves the tier.
 */
const SERVER_DOWN_RTT_EXCESS_MS = 80;

/** One ~100 ms tick's raw counters. */
interface Sample {
  at: number;
  received: number;
  missed: number;
  /** Raw RTT sample, and the excess over the floor AT THAT TICK. */
  rttMs: number | null;
  excessMs: number | null;
}

/** One observed tier transition. */
interface TierChange {
  at: number;
  from: number;
  to: number;
}

/** The flat diagnostic snapshot the HUD renders (see buildStreamhostRows). */
export interface StreamDiagnostics {
  /** Loss % over the whole rolling window (missed / (received+missed)). */
  windowLossPct: number;
  /** Frames the window figure was computed from — the denominator that matters. */
  windowFrames: number;
  /** Worst SINGLE-TICK loss % seen in the window. */
  peakLossPct: number;
  /** Frames that worst tick was computed from. `1` means "one frame, 100 %". */
  peakLossFrames: number;
  /** ms since the worst tick, or null if the window holds no loss at all. */
  peakLossAgeMs: number | null;
  /**
   * True when the peak was both (a) big enough to trip the server's downshift
   * threshold and (b) computed from too few frames to mean anything. This is
   * the exact signature of the low-fps loss-quantisation bug.
   */
  peakLossUntrustworthy: boolean;
  /** Frame-drop and freeze deltas over the window, as per-minute rates. */
  dropsPerMin: number;
  freezesPerMin: number;
  /** Smoothed RTT and the learned path floor, mirroring the server's tracker. */
  rttFloorMs: number | null;
  /** Smoothed RTT minus the floor — the congestion signal the server acts on. */
  rttExcessMs: number | null;
  /** Worst RAW RTT in the window — the transient an instantaneous reading misses. */
  rttPeakMs: number | null;
  /** ms since that worst sample, or null if no RTT samples in the window. */
  rttPeakAgeMs: number | null;
  /** Ticks in the window whose excess was over the server's downshift threshold. */
  rttBreachTicks: number;
  /** ms since the last tier change, or null if none observed this session. */
  lastTierChangeAgeMs: number | null;
  /** Compact recent trajectory, oldest→newest, e.g. "0→1→2→3". Empty if none. */
  tierPath: string;
  /** Tier changes observed within HISTORY_WINDOW_MS. */
  tierChanges: number;
}

/** One tick's worth of input. `tier` may be null before the first params push. */
export interface TelemetryTick {
  now: number;
  received: number;
  missed: number;
  rttMs: number | null;
  framesDropped: number;
  freezeCount: number;
  tier: number | null;
}

/**
 * Rolling diagnostic recorder. One instance per StreamClient; fed once per
 * ~100 ms tick from tickStats and read by getMetrics.
 */
export class StreamTelemetry {
  private samples: Sample[] = [];
  private history: TierChange[] = [];
  private lastTier: number | null = null;
  private prevDropped = 0;
  private prevFreezes = 0;
  private dropEvents: Array<{ at: number; n: number }> = [];
  private freezeEvents: Array<{ at: number; n: number }> = [];
  private rttEwma: number | null = null;
  private rttFloor: number | null = null;
  private seeded = false;

  /** Fold one tick. Pure bookkeeping — never mutates the caller's state. */
  tick(t: TelemetryTick): void {
    // RTT floor FIRST, so this tick's sample can carry the excess it produced.
    // Mirrors streamhost abr.rs `fold`: EWMA m=16, the floor snaps DOWN to any
    // new minimum immediately and decays UP at 0.1 %/sample, so a LAN floor
    // stays ~0 and only genuine queueing growth reads as excess.
    if (t.rttMs != null) {
      this.rttEwma = this.rttEwma == null ? t.rttMs : this.rttEwma * (15 / 16) + t.rttMs / 16;
      if (this.rttFloor == null || this.rttEwma < this.rttFloor) this.rttFloor = this.rttEwma;
      else this.rttFloor += (this.rttEwma - this.rttFloor) * 0.001;
    }
    const excess = this.rttEwma != null && this.rttFloor != null
      ? Math.max(0, this.rttEwma - this.rttFloor)
      : null;
    this.samples.push({
      at: t.now, received: t.received, missed: t.missed, rttMs: t.rttMs, excessMs: excess,
    });

    // Cumulative counters → per-window deltas. Seed on the first tick so a
    // mid-session attach doesn't report the whole backlog as a burst.
    if (this.seeded) {
      const dDrop = Math.max(0, t.framesDropped - this.prevDropped);
      const dFreeze = Math.max(0, t.freezeCount - this.prevFreezes);
      if (dDrop > 0) this.dropEvents.push({ at: t.now, n: dDrop });
      if (dFreeze > 0) this.freezeEvents.push({ at: t.now, n: dFreeze });
    }
    this.prevDropped = t.framesDropped;
    this.prevFreezes = t.freezeCount;
    this.seeded = true;

    // Tier transitions.
    if (t.tier != null) {
      if (this.lastTier != null && t.tier !== this.lastTier) {
        this.history.push({ at: t.now, from: this.lastTier, to: t.tier });
        if (this.history.length > HISTORY_MAX) this.history.shift();
      }
      this.lastTier = t.tier;
    }

    this.prune(t.now);
  }

  private prune(now: number): void {
    const cut = now - WINDOW_MS;
    while (this.samples.length && this.samples[0].at < cut) this.samples.shift();
    while (this.dropEvents.length && this.dropEvents[0].at < cut) this.dropEvents.shift();
    while (this.freezeEvents.length && this.freezeEvents[0].at < cut) this.freezeEvents.shift();
    const hcut = now - HISTORY_WINDOW_MS;
    while (this.history.length && this.history[0].at < hcut) this.history.shift();
  }

  /** Flatten the window into the HUD snapshot. */
  snapshot(now: number): StreamDiagnostics {
    let recv = 0;
    let missed = 0;
    let peakPct = 0;
    let peakFrames = 0;
    let peakAt: number | null = null;
    let rttPeak: number | null = null;
    let rttPeakAt: number | null = null;
    let breaches = 0;
    for (const s of this.samples) {
      recv += s.received;
      missed += s.missed;
      if (s.rttMs != null && (rttPeak == null || s.rttMs > rttPeak)) {
        rttPeak = s.rttMs; rttPeakAt = s.at;
      }
      if (s.excessMs != null && s.excessMs >= SERVER_DOWN_RTT_EXCESS_MS) breaches++;
      const n = s.received + s.missed;
      if (n === 0 || s.missed === 0) continue;
      const pct = (s.missed * 100) / n;
      // Strictly-greater keeps the OLDEST tick among equal peaks, which is the
      // one most likely to have driven a tier change already in flight.
      if (pct > peakPct) { peakPct = pct; peakFrames = n; peakAt = s.at; }
    }
    const total = recv + missed;
    const perMin = (evts: Array<{ at: number; n: number }>) => {
      const n = evts.reduce((a, e) => a + e.n, 0);
      return n === 0 ? 0 : (n * 60_000) / WINDOW_MS;
    };
    const last = this.history.length ? this.history[this.history.length - 1] : null;

    return {
      windowLossPct: total > 0 ? (missed * 100) / total : 0,
      windowFrames: total,
      peakLossPct: peakPct,
      peakLossFrames: peakFrames,
      peakLossAgeMs: peakAt == null ? null : Math.max(0, now - peakAt),
      peakLossUntrustworthy: peakPct >= SERVER_DOWN_LOSS_PCT && peakFrames < LOW_CONFIDENCE_FRAMES,
      dropsPerMin: perMin(this.dropEvents),
      freezesPerMin: perMin(this.freezeEvents),
      rttFloorMs: this.rttFloor,
      rttExcessMs: this.rttEwma != null && this.rttFloor != null
        ? Math.max(0, this.rttEwma - this.rttFloor)
        : null,
      rttPeakMs: rttPeak,
      rttPeakAgeMs: rttPeakAt == null ? null : Math.max(0, now - rttPeakAt),
      rttBreachTicks: breaches,
      lastTierChangeAgeMs: last == null ? null : Math.max(0, now - last.at),
      tierPath: this.history.length
        ? [this.history[0].from, ...this.history.map((h) => h.to)].join('→')
        : '',
      tierChanges: this.history.length,
    };
  }
}

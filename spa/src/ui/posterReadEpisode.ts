// ============================================================================
//  posterReadEpisode — is the curatorial prose read?
//  ---------------------------------------------------------------------------
//  Somebody wrote ~450 kB of exhibit prose (registry/posters/*.md, served as
//  poster-docs.json) and nothing in the repo has ever reported whether a word
//  of it is read. Three numbers per opened poster: how long it was VISIBLE, how
//  far down it got, and how often the reader went back up.
//
//  DWELL IS VISIBLE TIME, which is the entire reason this is not "time on
//  page". A poster left open behind another tab for an hour is not an hour of
//  reading, and a handful of those is enough to make every percentile fiction.
//  `startTiming` already excludes hidden time (analytics/metrics.ts); this file
//  gets that for free and must not reimplement it.
//
//  THE REVERSAL COUNT IS A PROXY AND ONLY A PROXY. Scrolling back up mid-poster
//  is what re-reading a paragraph looks like FROM THE OUTSIDE. It is a count of
//  scroll direction changes. It is not a measurement of confusion, difficulty
//  or cognitive load — a reader checking a date, a reader whose trackpad
//  overshot, and a reader defeated by a sentence all produce the same edge.
//  What it is good for: ranking posters against each other, and pairing with
//  depth. A long poster affords more reversals than a short one for reasons
//  that have nothing to do with how it is written, so the two are read together
//  or not at all.
// ============================================================================

import { beginFlow, recordMetric, startTiming, type Timing } from '../analytics';

/** Movement that has to accumulate against the established direction before a
 *  turn counts as a reversal. Trackpad momentum, a rubber-band bounce at the
 *  end of the essay and sub-pixel jitter all produce contrary deltas of a few
 *  pixels; counting those would make every poster look re-read. About a line
 *  and a half of body text, which is the smallest movement a person makes on
 *  purpose. */
const REVERSAL_MIN_PX = 24;

/** Depth at which a poster counts as READ TO THE END. Not 100: the last screen
 *  is a footer and a rule, and requiring the reader to drag the scrollbar into
 *  it would report almost nobody finishing something almost everybody did. */
const END_OF_READ_PCT = 90;

/**
 * Counts direction changes in a stream of scroll deltas, ignoring movement too
 * small to be deliberate.
 *
 * Exported for its own tests and reused by nothing else yet: the fleet table's
 * horizontal pair predates it and counts every non-zero delta, which is right
 * there — a sideways hunt is made of large deliberate sweeps — and wrong here,
 * where a reader's wheel produces a continuous jittering stream.
 */
export function createReversalCounter(minPx: number = REVERSAL_MIN_PX) {
  /** The established direction: +1 down, -1 up, 0 before the first real move. */
  let dir = 0;
  /** Signed pixels accumulated in the current same-sign streak. */
  let run = 0;
  return {
    /** Feed one delta. Returns true if this delta completed a reversal. */
    push(delta: number): boolean {
      if (typeof delta !== 'number' || !Number.isFinite(delta) || delta === 0) return false;
      const next = delta > 0 ? 1 : -1;
      // A change of sign starts a new streak; the old one is spent.
      if (run !== 0 && Math.sign(run) !== next) run = 0;
      run += delta;
      // Not yet enough travel to be a deliberate move in any direction.
      if (Math.abs(run) < minPx) return false;
      if (dir === 0) {
        dir = next;
        return false;
      }
      if (dir === next) return false;
      dir = next;
      run = 0;
      return true;
    },
  };
}

/** How far down a scroll container the reader has got, 0-100. */
export function scrollDepthPct(scrollTop: number, clientHeight: number, scrollHeight: number): number {
  // A poster shorter than the viewport is 100% read by construction — there was
  // never anything below the fold. That is a true statement about that poster
  // and a slightly flattering one about the distribution; posters are long
  // enough that it is rare, and inventing a different answer for the short ones
  // would make the column mean two things.
  const scrollable = scrollHeight - clientHeight;
  if (!Number.isFinite(scrollable) || scrollable <= 0) return 100;
  const pct = ((scrollTop + clientHeight) / scrollHeight) * 100;
  return Math.max(0, Math.min(100, pct));
}

export interface PosterReadEpisode {
  /** The scroll position moved. Called from a passive scroll listener. */
  scrolled(scrollTop: number, clientHeight: number, scrollHeight: number): void;
  /** The poster was closed or unmounted. Settles everything; safe twice. */
  end(): void;
}

const NOOP: PosterReadEpisode = { scrolled() {}, end() {} };

/**
 * Open one poster-reading episode. Never throws.
 *
 * MUST be called from an effect, never a render body or a `setState` updater —
 * StrictMode runs both twice, and two episodes would report one poster as two.
 */
export function beginPosterReadEpisode(): PosterReadEpisode {
  try {
    const flow = beginFlow('poster.read');
    let dwell: Timing | null = startTiming('poster.read.dwellMs');
    const reversals = createReversalCounter();
    let reversalCount = 0;
    let deepestPct = 0;
    let lastTop: number | null = null;
    let ended = false;

    return {
      scrolled(scrollTop: number, clientHeight: number, scrollHeight: number) {
        try {
          if (ended) return;
          if (lastTop !== null) {
            if (reversals.push(scrollTop - lastTop)) reversalCount += 1;
          }
          lastTop = scrollTop;
          flow.step('scrolled');
          const pct = scrollDepthPct(scrollTop, clientHeight, scrollHeight);
          // DEEPEST, not latest: a reader who reaches the end and scrolls back
          // up to re-read a paragraph read the whole thing, and reporting where
          // they happened to stop would score that visit as an abandonment.
          if (pct > deepestPct) deepestPct = pct;
          if (deepestPct >= END_OF_READ_PCT) {
            flow.step('reachedEnd');
            flow.ok();
          }
        } catch { /* instrumentation never throws into the app */ }
      },
      end() {
        try {
          if (ended) return;
          ended = true;
          // Dwell is STOPPED, not abandoned, on every path including a poster
          // dismissed in half a second. That half second is the finding: it is
          // what "opened it and did not read it" looks like, and dropping those
          // samples would leave a distribution made only of the readers.
          dwell?.stop();
          dwell = null;
          // Depth and reversals are settled here for the same reason — one
          // episode, one sample, including the visit that never scrolled (0%,
          // 0 reversals), which is the strongest evidence the prose is unread.
          recordMetric('poster.read.scrollDepthPct', deepestPct);
          recordMetric('poster.read.scrollReversals', reversalCount);
          // `close()`, not `fail()`: a reader who stops half way is the funnel's
          // drop-off, not a fault. Harmless after `ok()`.
          flow.close();
        } catch { /* noop */ }
      },
    };
  } catch {
    return NOOP;
  }
}

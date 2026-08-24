// ============================================================================
//  videoResume — the paused SINK, and getting it pulling again
//  ---------------------------------------------------------------------------
//  Field signature (rhapsody, Chrome 151 Android, installed PWA, 2026-08-24):
//
//      {"vis":"visible","vid":{"w":1024,"h":768,"rs":4,"paused":true,"ct":6.78,
//       "err":null}}
//
//  The <video> is PAUSED on a VISIBLE page, readyState 4, correct dimensions,
//  no error. Chrome-Android pauses a media element when the PWA is backgrounded
//  and NOTHING un-pauses it on return: the old code called play() exactly once,
//  from the effect that attaches the MediaStream, so a resume — where the stream
//  object identity never changes — never re-armed it. A paused element pulls
//  nothing, so the picture is black, `fps` is 0, and the session's own keyframe
//  watchdog then blames the transport for a fault that lives entirely on this
//  side of the wire. See docs/lab/STREAM-DEBUGGING.md.
//
//  A single await v.play() fixed it in the operator's own tab and the clock
//  jumped 655 s straight to the live edge. This module is that one call, made
//  deliberate: it decides WHETHER a resume is owed, forces the live edge rather
//  than trusting it, and reports an autoplay rejection as a state the UI can
//  show instead of a black rectangle.
// ============================================================================

/** A clock this far behind the last seekable instant is history, not the exhibit. */
export const LIVE_EDGE_MAX_LAG_S = 0.5;
/**
 * Cap on how long we wait for the resumed element to report its new clock.
 *
 * play() resolves when playback is ALLOWED, not when a frame has been
 * presented, so reading currentTime straight after it returns the clock the
 * element was paused at — the first version of this logged `advanced=0.00s` on
 * every single resume, a true number that measured nothing. A fixed delay was
 * no better (120 ms was still too early in the field). We wait for the element's
 * own `timeupdate` instead, which is the event that means "the clock moved",
 * and cap it so a sink that never ticks cannot hang the resume.
 */
const RESUME_SETTLE_CAP_MS = 1500;

/** Resolve on the element's first `timeupdate`, or when the cap expires. */
function awaitClockMoved(el: HTMLVideoElement): Promise<void> {
  if (typeof el.addEventListener !== 'function') return Promise.resolve();
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { el.removeEventListener('timeupdate', finish); } catch { /* noop */ }
      resolve();
    };
    const timer = setTimeout(finish, RESUME_SETTLE_CAP_MS);
    el.addEventListener('timeupdate', finish, { once: true });
  });
}

/** What we can observe about the sink without touching it. */
export interface VideoSinkProbe {
  /** A source is attached — an empty element is "not started", not "paused". */
  hasSource: boolean;
  paused: boolean;
  readyState: number;
  /** Decoded width; 0 means the element has never had a picture. */
  width: number;
  currentTime: number;
  /** Non-null when the element itself failed — that is NOT a paused sink. */
  error: unknown;
}

type ResumeOutcome =
  /** No element, or no source attached yet — nothing to resume. */
  | 'no-sink'
  /** The element is already pulling; the black screen is not here. */
  | 'playing'
  /** The page is hidden — a paused element is CORRECT, leave it paused. */
  | 'hidden'
  /** play() was accepted; the sink is pulling again. */
  | 'resumed'
  /** play() was rejected by autoplay policy — the visitor must be asked. */
  | 'blocked';

export interface ResumeReport {
  outcome: ResumeOutcome;
  /** Seconds the media clock advanced across the resume (the live-edge jump). */
  advanced: number;
  /** True when we had to seek explicitly rather than the UA jumping for us. */
  seeked: boolean;
  error?: string;
}

/** Read the sink's state. Never throws: a torn-down element must not crash a resume. */
export function probeVideoSink(el: HTMLVideoElement | null | undefined): VideoSinkProbe | null {
  if (!el) return null;
  try {
    return {
      hasSource: !!el.srcObject || !!el.currentSrc || !!el.src,
      paused: el.paused,
      readyState: el.readyState,
      width: el.videoWidth,
      currentTime: el.currentTime,
      error: el.error,
    };
  } catch {
    return null;
  }
}

/**
 * True when this element is a PAUSED SINK: a healthy, sourced, undamaged
 * element that has simply stopped pulling while the page is in the foreground.
 *
 * This is the distinction the retry loop was missing. "No picture" has two
 * causes that look identical from the outside and want OPPOSITE responses —
 * nothing is ARRIVING (reconnect the transport) versus nothing is being
 * CONSUMED (resume the element, and do NOT tear down a healthy transport).
 * An element carrying an `error` is neither: that is a decoder fault and
 * belongs to the decoder-failed path.
 */
export function isPausedSink(probe: VideoSinkProbe | null, visible: boolean): boolean {
  if (!probe || !visible) return false;
  if (probe.error) return false;
  return probe.hasSource && probe.paused;
}

/**
 * Where the live edge is, or null when the element is already there.
 *
 * A MediaStream-backed element (every streamhost station on the Chrome path,
 * and the WebRTC fallback) reports an EMPTY `seekable`: a live stream has no
 * history to seek through, so resuming necessarily resumes at the live edge —
 * which is exactly the 655 s jump the operator's tab showed. Returning null
 * there is the correct answer, not a missing case. The seek exists for a
 * buffered source, where play() would otherwise resume eleven minutes of
 * history and present it as the exhibit.
 */
export function liveEdgeSeekTarget(probe: {
  currentTime: number;
  seekable: { length: number; end(i: number): number } | null | undefined;
}): number | null {
  const s = probe.seekable;
  if (!s || s.length === 0) return null;
  let end: number;
  try {
    end = s.end(s.length - 1);
  } catch {
    return null;
  }
  if (!Number.isFinite(end)) return null;
  return end - probe.currentTime > LIVE_EDGE_MAX_LAG_S ? end : null;
}

/**
 * Resume a paused sink at the LIVE EDGE.
 *
 * Order matters: seek BEFORE play where a seek is owed, so the element never
 * decodes a single frame of backlog, then verify after play that the clock
 * really did land at the edge rather than assuming the UA did it for us.
 */
export async function resumeVideoElement(
  el: HTMLVideoElement | null | undefined,
  visible: boolean,
): Promise<ResumeReport> {
  const probe = probeVideoSink(el);
  if (!el || !probe || !probe.hasSource) return { outcome: 'no-sink', advanced: 0, seeked: false };
  if (!visible) return { outcome: 'hidden', advanced: 0, seeked: false };
  if (!probe.paused) return { outcome: 'playing', advanced: 0, seeked: false };

  const t0 = probe.currentTime;
  let seeked = false;
  const target = liveEdgeSeekTarget({ currentTime: t0, seekable: el.seekable });
  if (target != null) {
    try { el.currentTime = target; seeked = true; } catch { /* live source: not seekable */ }
  }

  try {
    await el.play();
  } catch (e) {
    const err = e as { name?: string; message?: string };
    return {
      outcome: 'blocked',
      advanced: 0,
      seeked,
      error: err?.name || err?.message || String(e),
    };
  }

  // Verify rather than trust. A MediaStream element lands on the live edge by
  // construction; a buffered one may not have honoured the pre-play seek.
  await awaitClockMoved(el);
  let advanced = 0;
  try {
    const after = liveEdgeSeekTarget({ currentTime: el.currentTime, seekable: el.seekable });
    if (after != null) { el.currentTime = after; seeked = true; }
    advanced = el.currentTime - t0;
  } catch { /* element torn down mid-resume */ }

  return { outcome: 'resumed', advanced, seeked };
}

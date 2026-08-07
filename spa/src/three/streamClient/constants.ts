// ============================================================================
//  streamClient/constants — wire opcodes, stream kinds, watchdog timings, and
//  the (deliberately UA-light) Firefox capability flags shared across the
//  streamClient modules. Split out of the streamClient god-module verbatim; the
//  numeric values ARE the wire contract with streamhost/src/input.rs +
//  transport.rs and must not drift.
// ============================================================================

// ---- input record types (mirror streamhost/src/input.rs) -------------------
export const T_MOVE_ABS = 1;
export const T_BUTTON = 2;
export const T_KEY = 3;
export const T_MOVE_REL = 4;
export const T_WHEEL = 5;
export const T_PING = 9;

// ---- per-type reliable-input CLASS tags (client-opened uni streams) --------
// The first byte of each client-opened unidirectional reliable input stream
// (per-type QUIC input streams / HOL avoidance). Matches transport.rs ICLASS_*.
// This tag namespace is the CLIENT->SERVER uni-stream tag space and is independent
// of the SERVER->CLIENT KIND_* prefixes below.
export const ICLASS_KEY = 1;
export const ICLASS_BUTTON = 2;
export const ICLASS_WHEEL = 3;
// const ICLASS_CONTROL = 4; // reserved urgent-control class (no sender today)
export const INPUT_CLASSES = [ICLASS_KEY, ICLASS_BUTTON, ICLASS_WHEEL] as const;

// ---- tagged-wire (wireVersion>=2) stream kinds -----------------------------
export const KIND_VIDEO = 1;
export const KIND_AUDIO = 2;
// KIND_PARAMS (wireVersion>=3): server→client encoder params + per-session HUD
// stats. Subtype byte selects the payload (1 = encoder-params, 2 = server-stats).
export const KIND_PARAMS = 3;

// ---- client→server feedback datagram opcode (free slot; see input.rs 1..6 and
//  the type-9 RTT ping). T_STATS carries the ABR measurement report every 100ms.
export const T_STATS = 10;

// idle-frame-stall watchdog (Item 4): no decoded frame painted for this long while
// the transport is still open ⇒ raise the stall flag. Chosen > the ~250ms freeze
// window so it flags a genuine multi-frame stall, not a single dropped GOP.
export const FRAME_STALL_MS = 2000;
// A watched streamhost session emits a keyframe heartbeat even for a perfectly
// static desktop. Missing decoded output for two advertised heartbeat windows
// (plus scheduling slack) therefore means the session is stale, not merely idle.
export const MIN_SESSION_STALE_MS = 8000;
export const MAX_SESSION_STALE_MS = 25000;

// Firefox detection (Gecko engine, not the "like Gecko" token every WebKit UA
// carries). Firefox's VideoDecoder isConfigSupported + 'prefer-hardware'
// answers are untrustworthy (Bugzilla 1918769: supported:true configs that
// then fail to decode), so on Firefox we ALWAYS configure with
// hardwareAcceleration 'no-preference' and never trust the HW probe.
export const IS_FIREFOX =
  typeof navigator !== 'undefined'
  && navigator.userAgent.includes('Gecko/')
  && !navigator.userAgent.includes('like Gecko');
// Used only to expose/flush targeted diagnostics for the affected device class;
// capability decisions remain UA-free (decoderUnsupportedReason below).
export const IS_FIREFOX_ANDROID =
  IS_FIREFOX
  && typeof navigator !== 'undefined'
  && navigator.userAgent.includes('Android')
  && navigator.userAgent.includes('Mobile');
// Decoder-failing latch threshold: this many CONSECUTIVE configure/decode
// failures with zero output frames in between ⇒ bannerState 'decoder-failed'
// (the chip reads "No video · decoder failing: …" instead of the generic stall).
export const DECODER_FAIL_THRESHOLD = 3;

// ---------------------------------------------------------------------------
//  Firefox incoming-uni-stream delivery race (the REAL "Firefox stall" root
//  cause, found empirically 2026-07-12 on CT950 with Playwright Firefox 151):
//  Firefox PERMANENTLY stops surfacing server-opened incoming uni-streams to
//  JS when any arrive before the incomingUnidirectionalStreams reader is
//  attached — and our server primes the cached key AU the instant it accepts
//  the session, so the primer always races JS. Server-side vtrace proves every
//  AU is still granted/written/finished at 27 fps into a stalled session;
//  datagrams echo fine; client→server streams work; NOTHING unblocks delivery
//  in-session (datagram writes/reads, client uni/bidi opens all probed).
//  WebCodecs is NOT involved: the same Firefox decodes our captured AUs
//  1-in-1-out in every mode (annexb AND avcC+AVCC description).
//  FIX, two layers:
//    1. PRIMARY (connect()): attach the incoming-stream + datagram readers
//       BEFORE awaiting wt.ready — measured 10/10 healthy sessions vs 6/10
//       (attach just after ready) vs 0/10 (attach after the input-writer
//       opens, the old order). Chrome is indifferent to attach order.
//    2. BELT-AND-BRACES (this watchdog): if a session still comes up poisoned
//       (≤ FF_STALL_MAX_STREAMS streams ever AND none for FF_STALL_QUIET_MS),
//       silently rebuild the transport — each reconnect is an independent
//       trial. Healthy sessions always exceed the threshold within ~1s (video
//       ≥ heartbeat IDR rate + 1 Hz KIND_PARAMS stats), disarming it.
// ---------------------------------------------------------------------------
export const FF_STALL_CHECK_MS = 500;    // watchdog poll cadence
export const FF_STALL_QUIET_MS = 2000;   // no new incoming uni-stream for this long ⇒ poisoned
export const FF_STALL_MAX_STREAMS = 2;   // sessions that ever exceed this are healthy
export const FF_STALL_MAX_REBUILDS = 10; // p(all poisoned) ≈ 0.4^10 — then give up to the stall UI
export const NO_VIDEO_DEADLINE_MS = 3000;

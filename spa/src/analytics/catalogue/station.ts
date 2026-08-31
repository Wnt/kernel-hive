// ============================================================================
//  analytics/catalogue/station — the machine itself: opening one, driving it, and watching it
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
// ============================================================================

import type { FlowSpec, MetricSpec, ProbeSpec } from './types.ts';

export const STATION_PROBES = {
  // ---- the station itself --------------------------------------------------
  // These two are the floor of the whole gallery: if a station never sees a
  // click or a keystroke, nothing else about it matters.
  'station.pointer.used': {
    area: 'station',
    owner: 'src/three/streamClient/inputWire.ts',
    what: 'a button went down on a live guest',
    grades: ['act'],
  },
  'station.key.used': {
    area: 'station',
    owner: 'src/three/streamClient/inputWire.ts',
    what: 'a key went down on a live guest',
    grades: ['act'],
  },
  // ---- the diagnostic overlay ---------------------------------------------
  // The second auto-vs-act pair, and the more expensive one: the stats poll
  // runs once a SECOND for the whole life of every station session, feeding an
  // overlay that is hidden until somebody presses Cmd/Ctrl+N. Reported once per
  // session on each side, not once per tick, so the ratio reads "sessions that
  // polled" against "sessions that looked" rather than ticks against renders.
  'stream.stats.polled': {
    area: 'stream',
    owner: 'src/ui/grid/StreamView/useStreamSession.ts',
    what: 'a station session started polling live stream stats for the debug overlay',
    grades: ['auto'],
  },
  'stream.overlay.shown': {
    area: 'stream',
    owner: 'src/ui/grid/StreamView/DebugOverlay.tsx',
    what: 'the Cmd/Ctrl+N diagnostic overlay was actually on screen',
    grades: ['show'],
    consumes: 'stream.stats.polled',
  },
  // ---- boot video ----------------------------------------------------------
  // /boot/index.json is fetched on every manifest load for every visitor; the
  // videos it indexes only play when somebody opens a station that has one.
  'boot.index.fetch': {
    area: 'boot',
    owner: 'src/data/useManifest.ts',
    what: 'the boot-video index was fetched and merged onto the catalog',
    grades: ['auto'],
  },
  'boot.video.played': {
    area: 'boot',
    owner: 'src/ui/grid/StreamView/BootVideoOverlay.tsx',
    what: 'a boot video actually started playing in front of somebody',
    grades: ['show', 'act'],
    consumes: 'boot.index.fetch',
  },
} as const satisfies Record<string, ProbeSpec>;

export const STATION_FLOWS = {
  'station.connect': {
    area: 'station',
    what: 'opening a station and getting a first frame out of it',
    // Ordered. `firstFrame` is the only step that proves a visitor saw the
    // machine — every earlier one is the gallery talking to itself.
    steps: ['open', 'transport', 'firstFrame'],
  },
  // COMING BACK is not arriving. The resume path is `resumeSignals` +
  // `resumePolicy` + `sessionResume` + `videoResume`, which share no code with
  // the connect ladder above and each exist because of a separate field
  // failure — a frozen PWA, a paused <video> pulling nothing, a session parked
  // in `phase error` forever. Today all of that is invisible: a resume is
  // either a duplicate `station.connect` entry or no entry at all, so a resume
  // that never completes looks exactly like a visitor who left.
  'session.resume': {
    area: 'stream',
    what: 'a backgrounded tab or installed PWA coming back to a moving picture',
    // `wake` is a resume SIGNAL, not a state — resumeSignals fires up to four
    // times per app switch by design. `transport` is where the session is
    // judged live or rebuilt. `firstFrame` is the only step a visitor can see.
    steps: ['wake', 'transport', 'firstFrame'],
  },
  // A freeze as the VISITOR experiences it. Deliberately NOT a measurement of
  // the stream: loss, RTT, tier and bitrate belong to the daemon and to the
  // Cmd/Ctrl+N overlay, and a fourth opinion on them would be worse than none.
  // The drop-off between `frozen` and `moving` is the number that does not
  // exist anywhere else in this system — it is visitors giving up.
  'stream.recover': {
    area: 'stream',
    what: 'a picture that stopped moving, and whether it started again before the visitor left',
    steps: ['frozen', 'reconnecting', 'moving'],
  },
} as const satisfies Record<string, FlowSpec>;

export const STATION_METRICS = {
  // The headline number of the whole gallery: click a machine, see its desktop.
  // Measured in VISIBLE time only (analytics/metrics.ts) — a visitor who opens
  // a station and switches tabs for two minutes did not wait two minutes, and a
  // handful of those is enough to move a p95 into fiction.
  //
  // It ends at the first PAINTED FRAME, not at `phase === 'live'`. The phase has
  // gone live on a session that stayed a spinner, so the phase is the gallery's
  // opinion and the frame is the visitor's.
  'station.open.toFirstFrameMs': {
    area: 'station',
    owner: 'src/three/connectTelemetry.ts',
    what: 'a high value means visitors stare at a spinner between choosing a machine and seeing it',
    scale: 'ms',
  },
  // TIME TO TOUCH. How long somebody looks at a WORKING machine before daring
  // to use it — measured from the first painted frame, not from the click, so
  // it contains none of the connect wait. A high value on one station and not
  // another is a DISCOVERABILITY problem, not a performance one: the same
  // stream, the same latency, and visitors can tell what to do with one
  // exhibit and not the other, which is answered by a coachmark or a caption
  // rather than by anything in the pipeline.
  //
  // Necessarily conditioned on the visitor touching AT ALL — you cannot time
  // an event that never happens, and a visitor who only ever watches abandons
  // this timing rather than landing in it. The proportion who never touch is a
  // different question and already has an answer: `station.pointer.used` and
  // `station.key.used` against sessions. Reading this distribution as if it
  // covered everyone is the one way to misuse it.
  'station.open.toFirstInputMs': {
    area: 'station',
    owner: 'src/three/connectTelemetry.ts',
    what: 'a high value means visitors hesitate to touch this machine once it works — it needs a clearer invitation, not a faster stream',
    scale: 'ms',
  },
  // WHAT THE CONNECT COST, as opposed to whether it worked. The funnel already
  // says a station connected; this says it took four goes to do it, which is a
  // station one bad week away from falling back to its poster. Counted as
  // ATTEMPTS rather than retries because the `count` ladder's smallest bucket
  // is 1: as retries, a clean connect and a one-retry connect would both land
  // in `1` and the commonest case would be unreadable. Committed only on a
  // painted frame — a give-up would otherwise deposit the full ladder length
  // in every failure and turn this into a restatement of the failure rate.
  'station.open.attemptCount': {
    area: 'station',
    owner: 'src/three/connectTelemetry.ts',
    what: 'a high value means this station only connects by retrying, so its ladder is absorbing a fault nobody has been told about',
    scale: 'count',
  },
  // ---- coming back (session.resume) ---------------------------------------
  // The pair below is disjoint by construction: one resume is one sample in
  // exactly one of them. Fused they would be bimodal and their p95 would only
  // report how often the expensive case happens; split, they say which of two
  // completely different fixes is the one worth doing.
  'session.resume.toLiveMs': {
    area: 'stream',
    owner: 'src/three/resumeTelemetry.ts',
    what: 'a high value means a session that survived being backgrounded still takes too long to start pulling again — the fix is in videoResume, not the transport',
    scale: 'ms',
  },
  'session.resume.reconnectToLiveMs': {
    area: 'stream',
    owner: 'src/three/resumeTelemetry.ts',
    what: 'a high value means rebuilding a dead session on resume is slow, so the fix is to keep sessions alive across a background rather than to reconnect faster',
    scale: 'ms',
  },
  // THE ONE LEGITIMATE `countsHiddenTime` IN THE WHOLE CATALOGUE, named as
  // such by the metrics.ts header. Every other duration here stops its clock
  // while the tab is hidden because it describes a person's PATIENCE and
  // hidden time is not patience. This one describes their ABSENCE, so visible
  // time would return zero on every sample — a tautology, not a distribution.
  // It earns the exception by driving a decision nothing else can: the daemon
  // pauses an idle guest after a grace window and holds a wake lease for 90 s
  // (streamhost/src/idle.rs), and how long visitors are actually away is what
  // says whether either window is set anywhere near right.
  'session.resume.awayMs': {
    area: 'stream',
    owner: 'src/three/resumeTelemetry.ts',
    what: 'a high value means visitors leave for longer than the idle-pause grace and wake lease assume, so those windows are tuned for a visit pattern that does not happen',
    scale: 'ms',
    countsHiddenTime: true,
  },
  // ---- freezing (stream.recover) ------------------------------------------
  // Both derived from the PAINT side, both about the human. Nothing here
  // measures loss, RTT, tier or bitrate: the daemon owns those and a fourth
  // number that disagreed with the overlay, the clientlog line and abr.rs
  // would be worse than having none. See three/stallWatch.ts for why the
  // threshold is derived from the station's own keyframe heartbeat rather
  // than fixed, and why a gap on a motionless desktop is not a freeze.
  'stream.recover.stallMs': {
    area: 'stream',
    owner: 'src/three/recoverTelemetry.ts',
    what: 'a high value means visitors sit through long visible freezes before the picture returns, so the recovery ladder is too slow to hide the fault it is recovering from',
    scale: 'ms',
  },
  // The most valuable number in this group: the only place in the system that
  // records a visitor GIVING UP. Everything else measures how long something
  // took for the people who stayed.
  'stream.recover.abandonedAfterMs': {
    area: 'stream',
    owner: 'src/three/recoverTelemetry.ts',
    what: 'a low value means visitors abandon a frozen station quickly, so recovery must beat that budget or be replaced by an honest message — and the COUNT of these is how many visits the fleet is losing to freezes',
    scale: 'ms',
  },
} as const satisfies Record<string, MetricSpec>;

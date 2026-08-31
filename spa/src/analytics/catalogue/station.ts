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
} as const satisfies Record<string, MetricSpec>;

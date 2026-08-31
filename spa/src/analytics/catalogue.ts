// ============================================================================
//  analytics/catalogue — the DENOMINATOR.
//  ---------------------------------------------------------------------------
//  A hit counter can only ever tell you about code that ran. The question this
//  plane exists to answer — "which features does nobody use?" — is a question
//  about code that DID NOT run, and you cannot count that. So the set of
//  instrumented things is declared here, once, and the report is a LEFT JOIN
//  from this list onto what production actually reported. A probe with no
//  observations is a row reading zero, which is the whole point.
//
//  THE INVARIANT THAT MAKES "ZERO" MEAN SOMETHING. Every id below must have a
//  live call site in the file named by `owner`, and
//  `scripts/analytics/check-catalogue.mjs` fails the build if one does not.
//  Without that gate the table has two indistinguishable kinds of zero — "the
//  feature is dead" and "I declared a probe and forgot to call it" — and the
//  second kind is the one that gets a working feature deleted. Declare a probe
//  in the same commit that calls it, or not at all.
//
//  WHAT A GOOD PROBE IS. Not a log line. `what` must finish the sentence "this
//  fired, therefore we know that…", and the answer has to be worth a decision.
//  `station.key.used` proves a human typed at a guest; `render.ran` proves
//  React is React.
//
//  THE PAIRING IS THE INSIGHT. `consumes` links a probe back to the `auto` one
//  whose data it uses. That pair is what separates "this endpoint is called on
//  every page load" from "somebody actually did something with the answer":
//  the report divides one by the other, and a producer with a large call count
//  and a near-zero consumer count is the strongest drop/defer signal this
//  system can emit. An `auto` probe with no consumer declared anywhere is
//  itself a finding — nothing in the UI claims to use it.
// ============================================================================

import type { Intent } from './intent';

/** One instrumented thing. */
export interface ProbeSpec {
  /** Grouping for the report. Keep the vocabulary small. */
  readonly area: 'fleet' | 'station' | 'stream' | 'keyboard' | 'boot' | 'app';
  /** Source file (repo-relative from spa/) holding the call site. Gated. */
  readonly owner: string;
  /** "This fired, therefore we know that…" */
  readonly what: string;
  /** The grades this probe may legitimately report. A call site asking for a
   *  grade not listed here is a bug the type system cannot catch, so the
   *  runtime clamps it — see `reach`. */
  readonly grades: readonly Intent[];
  /** The `auto` probe whose data this one consumes, if any.
   *
   *  Typed `string`, not `ProbeId`: `ProbeId` is `keyof typeof PROBES` and
   *  PROBES is checked against this interface, so naming it here is a circular
   *  reference TypeScript refuses. The constraint is real and is enforced
   *  twice instead — `scripts/analytics/catalogue.mjs check` (a build gate) and
   *  a unit test — both of which also assert the target is an `auto` producer,
   *  which the type could not have said anyway. */
  readonly consumes?: string;
}

/** One named user flow: an ordered path we care about completing. */
export interface FlowSpec {
  readonly area: ProbeSpec['area'];
  readonly what: string;
  /** In order. A flow that reaches step N is assumed to have passed 1..N-1,
   *  so the report can render a funnel without every step being reported. */
  readonly steps: readonly string[];
}

export const PROBES = {
  // ---- the fleet table -----------------------------------------------------
  // The clearest auto-vs-act case in the gallery: /usage/stations.json is
  // fetched on every visit to /fleet, and its only job is to annotate two
  // columns that a visitor may never look at, let alone sort by.
  'fleet.usage.fetch': {
    area: 'fleet',
    owner: 'src/data/fleetTable.ts',
    what: 'the per-station interaction totals were fetched from the server',
    grades: ['auto'],
  },
  'fleet.usage.shown': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'at least one row rendered with real usage numbers in it, in a visible tab',
    grades: ['show'],
    consumes: 'fleet.usage.fetch',
  },
  'fleet.usage.sorted': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a human sorted the fleet BY the usage column — the strongest evidence the fetch earns its keep',
    grades: ['act'],
    consumes: 'fleet.usage.fetch',
  },
  'fleet.sorted': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a human sorted the fleet table by some column',
    grades: ['act'],
  },
  'fleet.faceted': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a human filtered the fleet table by a column facet',
    grades: ['act'],
  },
  'fleet.searched': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a human typed in the fleet free-text filter',
    grades: ['act'],
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
  'keyboard.osk.used': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/OnScreenKeyboard.tsx',
    what: 'a key was pressed on the ON-SCREEN keyboard, not a physical one',
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
} as const satisfies Record<string, ProbeSpec>;

export type ProbeId = keyof typeof PROBES;

export const FLOWS = {
  'station.connect': {
    area: 'station',
    what: 'opening a station and getting a first frame out of it',
    // Ordered. `firstFrame` is the only step that proves a visitor saw the
    // machine — every earlier one is the gallery talking to itself.
    steps: ['open', 'transport', 'firstFrame'],
  },
} as const satisfies Record<string, FlowSpec>;

export type FlowId = keyof typeof FLOWS;

/** Steps of a flow, typed so a mis-spelled step is a compile error. */
export type FlowStep<F extends FlowId> = (typeof FLOWS)[F]['steps'][number];

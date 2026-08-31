// ============================================================================
//  analytics/catalogue/fleet — the fleet table, the WebGL hall, and the curatorial prose
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
// ============================================================================

import type { FlowSpec, MetricSpec, ProbeSpec } from './types.ts';

export const FLEET_PROBES = {
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
} as const satisfies Record<string, ProbeSpec>;

export const FLEET_FLOWS = {} as const satisfies Record<string, FlowSpec>;

export const FLEET_METRICS = {
  // The question this pair exists for: how much work is it to FIND a column in
  // a 60-row, ~20-column table whose body is `width: max-content`?
  //
  // In SCREEN WIDTHS, not pixels. A pixel total is not comparable between a
  // phone and the operator's monitor — the same hunt reads as 400 px on one and
  // 4000 on the other — and a metric you cannot compare across the devices that
  // produced it cannot be acted on. Screen widths is the same quantity with the
  // device divided out, and it is already the unit the answer wants to be in
  // ("two screens of sideways scrolling to reach the codec column").
  'fleet.find.hScrollScreens': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a high value means the columns people want are far from the ones they land on',
    scale: 'count',
  },
  // The stronger of the two, and the one that is hard to get any other way.
  // Distance alone cannot tell a confident sweep to a known column from hunting
  // — both are "far". A REVERSAL is the visitor going back, which is what
  // overshooting or losing your place actually looks like. Read them together:
  // high distance with no reversals is a layout that is merely wide; high
  // reversals is a layout nobody can hold in their head.
  'fleet.find.hScrollReversals': {
    area: 'fleet',
    owner: 'src/ui/FleetTable.tsx',
    what: 'a high value means people overshoot and backtrack — they cannot predict where a column is',
    scale: 'count',
  },
} as const satisfies Record<string, MetricSpec>;

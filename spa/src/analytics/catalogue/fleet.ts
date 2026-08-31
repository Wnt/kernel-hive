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
  // ---- the WebGL hall ------------------------------------------------------
  // The hall is the most expensive surface in the gallery — a parametric room,
  // dressing, grounding shadows, a machine assembly per station — and nothing
  // has ever said how often anybody opens it. Paired against `boot.index.fetch`
  // (fetched once per catalog load, i.e. once per visit, by every surface)
  // this reads as "of the visits that loaded the gallery, how many entered the
  // 3D hall". The pairing is honest in both directions: the hall genuinely
  // consumes that document — `entriesForHall` carries `bootVideo` through and
  // ScreenPlane decodes those loops onto the CRTs.
  //
  // WHAT IT IS NOT: a head-to-head against the 2D grid. The grid is not
  // separately instrumented (its files belong to another instrumentation
  // stream), so this is a share-of-visits number, not a share-of-browsing one.
  // Read it as a floor on how much of the audience the hall ever reaches.
  'hall.entered': {
    area: 'hall',
    owner: 'src/scene/hallEngagement.ts',
    what: 'the 3D hall was mounted in front of somebody, in a visible tab',
    grades: ['show'],
    consumes: 'boot.index.fetch',
  },
} as const satisfies Record<string, ProbeSpec>;

export const FLEET_FLOWS = {
  // ---- finding a machine in the table --------------------------------------
  // The table answers questions about 61 stations across ~20 columns. The only
  // outcome that proves it answered one is a visitor LEAVING it by opening a
  // machine: a table nobody ever exits through a station link is a table that
  // settles nothing. `narrow` is any deliberate act that shrinks the problem —
  // a sort, a facet, or the free-text filter going from empty to non-empty.
  //
  // Abandonment is the drop-off, as everywhere on this plane: a visit that
  // opens and narrows and stops is 1 `open`, 1 `narrow`, 0 `chooseStation`,
  // and nothing synthesises a failure out of it.
  'fleet.find': {
    area: 'fleet',
    what: 'answering a question with the fleet table and leaving it by opening a machine',
    steps: ['open', 'narrow', 'chooseStation'],
  },
  // ---- getting from the hall to a machine ----------------------------------
  // `approach` is not a proximity model invented for this metric: it is the
  // scene's OWN focus state (scene/screenTiers.ts), the same signal that
  // decides whether to spend a live stream texture on a screen. See
  // scene/hallEngagement.ts for the exact condition and its limits.
  'hall.navigate': {
    area: 'hall',
    what: 'entering the 3D hall and leaving it by opening a machine',
    steps: ['enter', 'approach', 'open'],
  },
  // ---- reading a poster ----------------------------------------------------
  // Somebody wrote ~450 kB of curatorial prose and nothing has ever reported
  // whether a word of it is read. `reachedEnd` is the completion, so the funnel
  // reads "opened / scrolled at all / got to the bottom".
  'poster.read': {
    area: 'poster',
    what: 'opening an exhibit poster and reading it to the end',
    steps: ['open', 'scrolled', 'reachedEnd'],
  },
} as const satisfies Record<string, FlowSpec>;

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
  // ---- the two halves of "how much work was that" --------------------------
  // These sit either side of the scroll pair above and share its episode: all
  // four are opened when the table mounts and settled when it unmounts, so a
  // high `actionsToStation` can be read against the same visit's scroll
  // distance. That pairing is the diagnosis: many actions with LITTLE sideways
  // scrolling is a visitor who could see the columns and still could not
  // express the question; many actions with a LOT of it is a visitor who spent
  // the whole visit hunting for where the answer lives.
  //
  // Both are BEHAVIOURAL PROXIES for effort — hesitation and steps-to-goal.
  // They observe what a pointer did. They do not measure attention, difficulty
  // or cognitive load, and a report that describes them that way will get a
  // wrong decision made from it.
  'fleet.find.toFirstActionMs': {
    area: 'fleet',
    owner: 'src/ui/fleetFindEpisode.ts',
    what: 'a high value means people land on the table and cannot tell what to do with it — the controls do not suggest the first move',
    scale: 'ms',
  },
  'fleet.find.actionsToStation': {
    area: 'fleet',
    owner: 'src/ui/fleetFindEpisode.ts',
    what: 'a high value means it takes many sorts and filters to isolate one machine — the default order and the column set are wrong for the questions people actually ask',
    scale: 'count',
  },
  // ---- the hall ------------------------------------------------------------
  // The budget question. The hall costs more to build and to render than
  // everything else in the SPA combined; this says what it converts.
  'hall.navigate.toFirstStationMs': {
    area: 'hall',
    owner: 'src/scene/hallEngagement.ts',
    what: 'a high value means the hall is scenery people wander rather than a way to reach a machine — spend the next hour on the grid instead',
    scale: 'ms',
  },
  // Approached-but-not-opened. The nearest thing to "they looked and moved on"
  // that is observable without eye tracking; see scene/hallEngagement.ts for
  // what "approached" is defined as and what it cannot tell you.
  'hall.navigate.stationsApproached': {
    area: 'hall',
    owner: 'src/scene/hallEngagement.ts',
    what: 'a high value means visitors stand in front of machine after machine without opening any — the placards are not telling people what they are looking at',
    scale: 'count',
  },
  // ---- the prose -----------------------------------------------------------
  // VISIBLE time only, which is the entire reason this is not "time on page":
  // a poster left open in a background tab for an hour is not an hour of
  // reading, and a handful of those would make every percentile fiction.
  'poster.read.dwellMs': {
    area: 'poster',
    owner: 'src/ui/posterReadEpisode.ts',
    what: 'a LOW value means posters are opened and dismissed unread — the prose is not earning the click, whatever it cost to write',
    scale: 'ms',
  },
  'poster.read.scrollDepthPct': {
    area: 'poster',
    owner: 'src/ui/posterReadEpisode.ts',
    what: 'a low value means people stop part way down — the essays are longer than the audience they are written for',
    scale: 'pct',
  },
  // Direction changes while reading. Re-reading a paragraph is what unclear
  // prose looks like from the outside — and it is only that FROM THE OUTSIDE:
  // this counts scroll reversals, not confusion. Read it beside depth; a long
  // poster affords more reversals than a short one for reasons that have
  // nothing to do with how it is written.
  'poster.read.scrollReversals': {
    area: 'poster',
    owner: 'src/ui/posterReadEpisode.ts',
    what: 'a high value means people scroll back up mid-poster — a passage they had to read twice, and the first place to look when rewriting',
    scale: 'count',
  },
} as const satisfies Record<string, MetricSpec>;

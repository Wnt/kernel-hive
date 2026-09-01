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
//  `scripts/analytics/catalogue.mjs check` fails the build if one does not.
//  Without that gate the table has two indistinguishable kinds of zero — "the
//  feature is dead" and "I declared a probe and forgot to call it" — and the
//  second kind is the one that gets a working feature deleted. Declare a probe
//  in the same commit that calls it, or not at all. The same rule applies to
//  flows (`beginFlow`) and metrics (`startTiming` / `recordMetric`).
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
//
//  THREE KINDS, AND THEY ANSWER DIFFERENT QUESTIONS. A probe says a path ran.
//  A flow says how far an ATTEMPT got and where it died. A metric says how
//  long it took or how much effort it cost. Reaching for a probe when the
//  question is "how long" gives you a number that cannot answer it, and the
//  reverse buries a yes/no in a distribution.
//
//  WHY THE `.ts` EXTENSIONS BELOW. `scripts/analytics/catalogue.mjs` imports
//  this file directly under Node's type-stripping loader, which — unlike the
//  bundler — requires an explicit specifier. tsconfig has
//  `allowImportingTsExtensions`, so both readers are happy; drop an extension
//  and the build still passes while the GATE stops running, which is the worst
//  of the available failures.
//
//  ONE FILE PER AREA. The per-area files carry the declarations; this file
//  only merges them. That is not tidiness — several instrumentation streams
//  run in parallel, and a single object literal would be a merge conflict per
//  stream, resolved by hand, in exactly the file where a bad resolution
//  silently detaches a probe from its call site.
// ============================================================================

import { APP_METRICS, APP_PROBES } from './app.ts';
import { FLEET_FLOWS, FLEET_METRICS, FLEET_PROBES } from './fleet.ts';
import { STATION_FLOWS, STATION_METRICS, STATION_PROBES } from './station.ts';
import { STREAM_EVENT_METRICS, STREAM_EVENT_PROBES } from './stream.ts';
import { WALKIN_FLOWS, WALKIN_METRICS, WALKIN_PROBES } from './walkin.ts';

// Only what is imported THROUGH this index. The per-area files take their
// types from './types.ts' directly, so re-exporting them here would be a
// barrel listing everything that exists rather than describing an API.
export { bucketFor } from './types.ts';

export const PROBES = {
  ...APP_PROBES,
  ...FLEET_PROBES,
  ...STATION_PROBES,
  ...STREAM_EVENT_PROBES,
  ...WALKIN_PROBES,
} as const;

export type ProbeId = keyof typeof PROBES;

export const FLOWS = {
  ...FLEET_FLOWS,
  ...STATION_FLOWS,
  ...WALKIN_FLOWS,
} as const;

export type FlowId = keyof typeof FLOWS;

/** Steps of a flow, typed so a mis-spelled step is a compile error. */
export type FlowStep<F extends FlowId> = (typeof FLOWS)[F]['steps'][number];

export const METRICS = {
  ...APP_METRICS,
  ...FLEET_METRICS,
  ...STATION_METRICS,
  ...STREAM_EVENT_METRICS,
  ...WALKIN_METRICS,
} as const;

export type MetricId = keyof typeof METRICS;

// ============================================================================
//  observability/ReportHeader — the sentence every number on this page needs.
//  ---------------------------------------------------------------------------
//  A fifth file beside the four views, because all four carry the same two
//  non-negotiable disclosures and a copy in each is a copy that will diverge:
//
//  1. THE WINDOW. `never reached` is a fact about a window and the sessions in
//     it. It is NOT `unreachable`. A 30-day window over a private gallery with
//     a handful of visits says much less than a 365-day one, and the verdict
//     is only readable next to it.
//  2. THE CLIENT CLASS. This lab drives its own SPA with a fleet of browser
//     probes (docs/ANALYTICS.md §4). They click and type for real, so every
//     heuristic says "human"; classified, they are `probe`. On a 63-station
//     private gallery they are plausibly the MAJORITY of traffic, so a page
//     that did not say which class it was showing would let somebody make a
//     keep/drop decision about what the TEST FLEET exercises and believe it
//     was about visitors.
//
//  It also renders the three-way state from reportMath's `dataState`, because
//  "nothing has ever posted here" and "nobody did this in 30 days" are
//  different statements and only the second is evidence of anything.
// ============================================================================

import type { AnalyticsReport } from './types';
import { dataState } from './reportMath';
import './reportViews.css';

/** What this section is called, and what a zero in it would mean. Passed in
 *  rather than derived so each view says it in its own terms — a zero probe and
 *  a zero funnel are not the same finding. */
export interface ReportHeaderProps {
  readonly report: AnalyticsReport;
  /** e.g. "no probe reported in this window". Shown only when there IS data,
   *  so a genuinely empty store never gets a verdict-shaped sentence. */
  readonly zeroMeans: string;
}

export function ReportHeader({ report, zeroMeans }: ReportHeaderProps) {
  const state = dataState(report);
  const klass = report.window.class;
  const probeClass = klass === 'probe';
  return (
    <>
      <div className="obs-window">
        <span>
          window <b>last {report.window.days} days</b>
          {report.window.since ? <> (from {report.window.since})</> : null}
        </span>
        <span className={probeClass ? 'obs-class-probe' : undefined}>
          class <b>{klass}</b>
          {probeClass ? ' — this lab’s own browser automation, not visitors' : null}
        </span>
        <span>last batch accepted <b>{report.lastAt ?? 'never'}</b></span>
      </div>
      {state === 'no-store' ? (
        <p className="obs-nodata">
          <b>No data at all.</b> This store has never accepted a batch, so every row below is
          an absence of evidence rather than a finding. Check the analytics route is deployed
          and the service restarted before reading a single zero as &ldquo;unused&rdquo; —
          a push is not a deploy.
        </p>
      ) : null}
      {state === 'empty-window' ? (
        <p className="obs-nodata">
          <b>Nothing in this window.</b> The store has data (last batch {report.lastAt}), but
          nothing for <b>{report.window.days} days</b> at class <b>{klass}</b>. Widen the
          window or change the class before reading any zero below; over this one they all
          say the same thing and it is not about any individual feature.
        </p>
      ) : null}
      {state === 'ok' ? (
        <p className="obs-nodata">
          There is data in this window, so a zero row is a statement: {zeroMeans}. It is still
          not &ldquo;unreachable&rdquo; — read the window above first, and remember the counts
          are the client&rsquo;s own account of what it did: right for deciding what to build
          next, wrong for anything that has to be true.
        </p>
      ) : null}
    </>
  );
}

/** A count where zero has to be readable as a finding rather than a blank.
 *  Used by every table for the same reason: a bare `0` in a column of numbers
 *  is the single most misread cell in this UI. */
export function Count({ n, state }: { readonly n: number; readonly state: string }) {
  if (n > 0) return <>{n.toLocaleString()}</>;
  return <span className={state === 'ok' ? 'obs-zero' : 'obs-unknown'}>{state === 'ok' ? '0' : '—'}</span>;
}

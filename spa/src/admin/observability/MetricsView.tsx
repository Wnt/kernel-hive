// ============================================================================
//  observability/MetricsView — how long it took, how much effort it cost, and
//  what to DO about the number.
//  ---------------------------------------------------------------------------
//  EVERY FIGURE HERE IS A BUCKET EDGE, rendered "≤ edge". The tab bucketed the
//  value before sending it (src/analytics/metrics.ts) so that a durable
//  years-long aggregate never becomes a behavioural trace of one visitor's
//  session; a p95 printed as `2847ms` would be inventing three digits nobody
//  measured, and being on a screen it would be believed. `over max` is the
//  overflow bucket and is a real answer, not a missing one.
//
//  THE DECISION SITS BESIDE THE NUMBER. The catalogue's `what` is written to
//  finish "a high value here means…" precisely so a report can render what to
//  do about the figure rather than only the figure — that is the direct answer
//  to "what decisions can we make from this". Several are written "a LOW value
//  means…" instead (poster dwell, scroll depth, abandon-after), so the sentence
//  is rendered VERBATIM under a neutral heading; putting them all under "what a
//  high value means" would invert three of them.
//
//  PROXIES ARE LABELLED AS PROXIES. docs/ANALYTICS.md §5.2 is firm about this
//  and the UI has to be too — see the standing caveat below the table, which is
//  rendered unconditionally so no row can escape it.
// ============================================================================

import { useMemo } from 'react';
import type { AnalyticsReport, Catalogue } from './types';
import { dataState, formatEdge, metricRows, type MetricRow } from './reportMath';
import { ReportHeader } from './ReportHeader';
import './reportViews.css';

export interface MetricsViewProps {
  readonly report: AnalyticsReport;
  readonly catalogue: Catalogue;
}

function Edge({ row, which }: { readonly row: MetricRow; readonly which: 'p50' | 'p75' | 'p95' }) {
  const p = row[which];
  if (p.edge === '-') return <span className="obs-unknown">—</span>;
  return <>≤&nbsp;{formatEdge(p.edge, row.scale)}</>;
}

export function MetricsView({ report, catalogue }: MetricsViewProps) {
  const rows = useMemo(() => metricRows(catalogue, report), [catalogue, report]);
  const state = dataState(report);
  const silent = rows.filter((r) => r.n === 0);

  return (
    <section className="obs-section">
      <h2>Metrics — how long, and how much effort</h2>
      <p className="obs-lede">
        Every metric the catalogue declares, whether or not it recorded a sample. Percentiles are
        <b> bucket edges</b>, never interpolated values: the tab bucketed each measurement before
        sending it, so <code>≤ 3.2s</code> is the entire truth the store holds and a precise
        number would be three digits nobody measured. Durations count <b>visible time only</b> —
        a wait that happened while the tab was backgrounded is not a wait.
      </p>
      <ReportHeader report={report} zeroMeans="nobody reached the path that records this metric" />

      <table className="obs-table">
        <thead>
          <tr>
            <th>metric</th>
            <th className="obs-num">n</th>
            <th className="obs-num">p50</th>
            <th className="obs-num">p75</th>
            <th className="obs-num">p95</th>
            <th>the decision this number is for</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.metric} className={state === 'ok' && r.n === 0 ? 'obs-row-never' : undefined}>
              <td>
                <div className="obs-id">
                  {r.metric}
                  {r.proxy ? <span className="obs-badge" title="A behavioural proxy: it observes what a pointer or a scroll container did. Read it as a comparison, not as a measurement of the visitor.">proxy</span> : null}
                  {r.countsHiddenTime ? <span className="obs-badge" title="This clock keeps running while the tab is hidden — the away time IS the quantity.">counts hidden time</span> : null}
                </div>
                <div className="obs-owner">{r.owner} · {r.scale}</div>
              </td>
              <td className="obs-num">
                {r.n > 0 ? r.n.toLocaleString()
                  : <span className={state === 'ok' ? 'obs-never' : 'obs-unknown'}>{state === 'ok' ? 'no samples' : '—'}</span>}
              </td>
              <td className="obs-num"><Edge row={r} which="p50" /></td>
              <td className="obs-num"><Edge row={r} which="p75" /></td>
              <td className="obs-num"><Edge row={r} which="p95" /></td>
              <td className="obs-what">{r.what}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="obs-tally">
        {state === 'ok'
          ? `${silent.length} of ${rows.length} declared metrics recorded nothing in this window`
          : `${rows.length} declared metrics, none of which this window can speak for`}
        {state === 'ok' && silent.length > 0
          ? `: ${silent.slice(0, 6).map((r) => r.metric).join(', ')}${silent.length > 6 ? ' …' : ''}`
          : '.'}
      </p>
      <p className="obs-note">
        <b>A metric with no samples is a stronger statement than a probe with no hits.</b>{' '}
        The catalogue gate already refuses a metric with no live call site, so &ldquo;declared and
        never called&rdquo; is ruled out: nobody reached the path in this window. What it still is
        not, is <i>unreachable</i> — read the window and class above first.
      </p>
      <p className="obs-note">
        <b>The rows badged <i>proxy</i> are behavioural proxies for effort, not measurements of
        the visitor.</b> Hesitation before a first action, steps to a goal, backtracking,
        correction rates and scroll oscillation observe what a pointer and a scroll container
        did. A reversal is produced identically by a reader checking a date, a trackpad that
        overshot, and a reader defeated by a sentence; a long time-to-first-action is produced
        identically by a confused visitor and one who answered the phone in a tab that was still
        visible. None of them measures attention, difficulty or cognitive load. They are good for
        COMPARISON and ranking — this poster against that one, this month against last, the fleet
        table before a column change against after — which is all that was ever asked of them.
        The badge is matched on the quantity in the id, so read it as a floor: a proxy of a
        genuinely new shape may not carry the badge and this paragraph still applies to it.
      </p>
      <p className="obs-note">
        A <code>pct</code> rate may exceed 100 and land in <code>over max</code>; that is real
        (clearing a field the guest already had text in) and is not clamped, because clamping
        would merge it with the merely terrible. A rate over an empty denominator is recorded as
        nothing at all rather than as a zero.
      </p>
    </section>
  );
}

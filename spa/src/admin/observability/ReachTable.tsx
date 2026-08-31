// ============================================================================
//  observability/ReachTable — which declared features anything ever reached,
//  and whether the calls that ran are earning their answers.
//  ---------------------------------------------------------------------------
//  Two tables, and they answer two different questions that a single hit
//  counter destroys by fusing (docs/ANALYTICS.md §1):
//
//  REACH is the LEFT JOIN. Every probe the catalogue declares gets a row, so a
//  feature nobody has opened is a row reading zero rather than a row that is
//  not there. You cannot count code that did not run, which is why the
//  denominator is declared by hand and why this table is the point of the
//  system rather than a summary of it.
//
//  AUTO VS ACT is the pair. `called 907` and `used 64` are two facts about one
//  endpoint and a single number destroys both. It is rendered as a SENTENCE
//  rather than a ratio column on purpose: the finding only lands when the
//  producer's count and the consumer's count are read in one breath —
//  "polls stats 388 times for an overlay nobody opened" is the shape of the
//  question this plane was built to answer.
//
//  NO QUADRANT COLUMN. `reach-report.py` puts a HEALTHY / PAYING TWICE /
//  EXPOSED / DEAD verdict beside each probe by crossing this axis with vitest's
//  coverage-final.json and the instrumented build's line map. Neither artefact
//  is reachable from a tab, and a quadrant drawn from one axis would be exactly
//  the collapse that report refuses to make. See reportMath.reachRows.
// ============================================================================

import { useMemo } from 'react';
import type { AnalyticsReport, Catalogue } from './types';
import { dataState, pairRows, reachRows } from './reportMath';
import { Count, ReportHeader } from './ReportHeader';
import './reportViews.css';

export interface ReachTableProps {
  readonly report: AnalyticsReport;
  readonly catalogue: Catalogue;
}

export function ReachTable({ report, catalogue }: ReachTableProps) {
  const rows = useMemo(() => reachRows(catalogue, report), [catalogue, report]);
  const pairs = useMemo(() => pairRows(rows), [rows]);
  const state = dataState(report);
  const cold = rows.filter((r) => !r.reached).length;

  return (
    <section className="obs-section">
      <h2>Feature reach</h2>
      <p className="obs-lede">
        Every probe the catalogue declares, whether or not production reported it. The three
        columns are the intent ladder and they grade only downwards:{' '}
        <b>auto</b> ran because a page loaded or a poll fired and nobody asked,{' '}
        <b>show</b> put the result in front of a human in a visible tab, and{' '}
        <b>act</b> is a human deliberately operating it. Synthetic input (type-in demos, the
        win9x boot-modal auto-dismiss) can never earn an <b>act</b>.
      </p>
      <ReportHeader report={report} zeroMeans="no tab reported reaching this probe" />

      <table className="obs-table">
        <thead>
          <tr>
            <th>probe</th>
            <th className="obs-num">auto</th>
            <th className="obs-num">show</th>
            <th className="obs-num">act</th>
            <th>reach</th>
            <th>this fired, therefore we know that…</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.probe} className={state === 'ok' && !r.reached ? 'obs-row-never' : undefined}>
              <td>
                <div className="obs-id">{r.probe}</div>
                <div className="obs-owner">{r.owner}</div>
              </td>
              <td className="obs-num"><Count n={r.auto} state={state} /></td>
              <td className="obs-num"><Count n={r.show} state={state} /></td>
              <td className="obs-num"><Count n={r.act} state={state} /></td>
              <td>
                {r.reached ? (
                  <span className="obs-zero">reached</span>
                ) : state === 'ok' ? (
                  // Deliberately not the word "dead" and deliberately not red.
                  <span className="obs-never">never reached</span>
                ) : (
                  <span className="obs-unknown">no data</span>
                )}
              </td>
              <td className="obs-what">{r.what}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="obs-tally">
        {state === 'ok'
          ? `${cold} of ${rows.length} declared probes were never reached in this window.`
          : `${rows.length} declared probes, none of which this window can speak for.`}
      </p>
      <p className="obs-note">
        <b>never reached</b> is not <b>unreachable</b>. It says no tab reported this probe over
        the window and class in the banner above — which on a private gallery with a handful of
        visits is a much weaker statement than it looks. What it IS good for is the pair below,
        and for shortlisting what to go and look at.
      </p>

      <h2 style={{ marginTop: 28 }}>Auto vs act — is the request earning its answer?</h2>
      <p className="obs-lede">
        A probe may declare that it <b>consumes</b> an <b>auto</b> producer&rsquo;s data. Dividing
        one by the other separates &ldquo;this endpoint is called on every page load&rdquo; from
        &ldquo;somebody actually used the answer&rdquo;. A large call count against a near-zero
        used count is not a dead feature — it is a live <b>cost</b>.
      </p>
      {pairs.length === 0 ? (
        <p className="obs-note">No probe in the catalogue declares a <code>consumes</code> producer.</p>
      ) : (
        <div>
          {pairs.map((p) => (
            <span className="obs-pair" key={`${p.producer}->${p.consumer}`}>
              <span className="obs-id">{p.producer}</span> called{' '}
              <b>{p.calls.toLocaleString()}</b>
              <span className="obs-arrow">→</span>
              <span className="obs-id">{p.consumer}</span> used{' '}
              <b>{p.used.toLocaleString()}</b>{' '}
              {p.pct === null ? (
                // 0/0 is not 0%. "Nobody used the answer" and "nothing asked
                // for it either" are different findings and only one of them
                // argues for removing anything.
                <span className="obs-unknown">(no ratio — the producer never ran in this window)</span>
              ) : (
                <span className={`obs-pct${p.pct < 5 ? ' obs-pct-cold' : ''}`}>
                  ({p.pct.toFixed(1)}%)
                </span>
              )}
            </span>
          ))}
        </div>
      )}
      <p className="obs-note">
        Both halves of a pair are reported at the same granularity — once per session, not once
        per tick — so a ratio reads as &ldquo;sessions that paid&rdquo; over &ldquo;sessions that
        looked&rdquo; and is not a function of how long a tab stayed open.
      </p>
    </section>
  );
}

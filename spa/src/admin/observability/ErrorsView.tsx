// ============================================================================
//  observability/ErrorsView — faults COUNTED, grouped and attributed.
//  ---------------------------------------------------------------------------
//  This is not a log. `/clientlog` keeps the stack, the component stack, the
//  href and the IP so one broken session can be read, and it prunes itself.
//  This lane keeps the COUNT, durably, so a fault that happened four hundred
//  times is one row that says four hundred — and a durable aggregate must not
//  be where a visitor's browsing history lives forever.
//
//  THE FLOW IS THE ATTRIBUTION, NOT THE MESSAGE. The fingerprint scrubs urls,
//  hex, uuids and every number, which deliberately collapses
//  `Failed to fetch …/signal/beos.json` and `…/signal/irix.json` into one row.
//  The per-station split somebody then wants comes from the FLOW and the STEP,
//  because the same exception is a different finding in a connect than in a
//  page turn: an error log knows what broke and not what the person was trying
//  to do.
//
//  NO DENOMINATOR, SO NO LEFT JOIN. Every other table on this page is joined
//  onto the catalogue, because a zero is the finding. Nobody declares the
//  faults they intend to have, so this table is what happened and nothing else
//  — and an empty one is genuinely good news, provided the banner says there
//  was data in the window at all.
//
//  The fingerprint is a BUTTON. It is the join key into the trace lane: the
//  aggregates say a fault happened four hundred times, and only a trace can
//  show the session that produced one of them.
// ============================================================================

import { useMemo } from 'react';
import type { AnalyticsReport } from './types';
import { dataState, errorRows } from './reportMath';
import { ReportHeader } from './ReportHeader';
import './reportViews.css';

export interface ErrorsViewProps {
  readonly report: AnalyticsReport;
  /** Hand the fingerprint to the trace side so an operator can go from "this
   *  happened 400 times" to "show me one of them". Optional: this view is
   *  readable on its own and must not require the drilldown to exist. */
  readonly onSelectFingerprint?: (fp: string) => void;
}

export function ErrorsView({ report, onSelectFingerprint }: ErrorsViewProps) {
  const rows = useMemo(() => errorRows(report), [report]);
  const state = dataState(report);
  const total = rows.reduce((sum, r) => sum + r.n, 0);

  return (
    <section className="obs-section">
      <h2>Errors by flow — most frequent first</h2>
      <p className="obs-lede">
        Faults grouped by fingerprint and attributed to the flow and the step the attempt was
        standing on when they were raised. The fingerprint has already scrubbed urls, ids and
        every number, so one row can cover many stations; the flow column is where that split
        comes back.
      </p>
      <ReportHeader report={report} zeroMeans="no fault with this attribution was reported" />

      {rows.length === 0 ? (
        <p className={state === 'ok' ? 'obs-note' : 'obs-nodata'}>
          {state === 'ok'
            ? 'No faults were reported in this window. There was other traffic in it (see the banner), so this is a real answer rather than an empty page.'
            : 'No faults — but nothing else was reported in this window either, so this table is not evidence of anything. See the banner above.'}
        </p>
      ) : (
        <>
          <table className="obs-table">
            <thead>
              <tr>
                <th className="obs-num">count</th>
                <th>fingerprint</th>
                <th>flow / step</th>
                <th>source</th>
                <th>sample message</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={`${r.fp}:${r.flow}:${r.step}`}>
                  <td className="obs-num"><b>{r.n.toLocaleString()}</b></td>
                  <td>
                    <button
                      type="button"
                      className="obs-fp"
                      disabled={!onSelectFingerprint}
                      title={onSelectFingerprint
                        ? 'Find traces carrying this fingerprint'
                        : 'Trace drilldown is not wired up on this page'}
                      onClick={onSelectFingerprint ? () => onSelectFingerprint(r.fp) : undefined}
                    >
                      {r.fp}
                    </button>
                  </td>
                  <td className="obs-id">
                    {r.flow
                      ? <>{r.flow} / {r.step || '—'}</>
                      : <span className="obs-unknown">(outside every flow)</span>}
                  </td>
                  <td className="obs-owner">{r.source || '—'}</td>
                  <td className="obs-msg">{r.message}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="obs-tally">
            {rows.length.toLocaleString()} fingerprint/attribution groups, {total.toLocaleString()}{' '}
            faults in total. The store caps this list at 200 groups.
          </p>
        </>
      )}

      <p className="obs-note">
        A row attributed to <i>(outside every flow)</i> is not a defect of the instrumentation.
        Errors raised while no flow was open are folded into the empty flow rather than dropped,
        because &ldquo;faults nobody&rsquo;s journey owns&rdquo; is itself a finding — an
        unattributed crash on the landing page lands exactly here.
      </p>
      <p className="obs-note">
        The message is a SAMPLE of the group, kept short on purpose. There is no stack here and
        there will not be: stacks stay on <code>clientlog.jsonl</code>, which prunes itself, and
        on the trace lane, which expires in days. This one is durable.
      </p>
    </section>
  );
}

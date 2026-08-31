// ============================================================================
//  observability/FunnelView — where attempts die.
//  ---------------------------------------------------------------------------
//  A flow is opened around an ATTEMPT, not a retry and not a session, and its
//  steps are monotonic: reporting step N implies 1..N-1 were passed, and
//  backwards or repeated moves are ignored. That is what makes this a funnel —
//  counts that only ever decrease down the declared list — rather than a bag of
//  counters that can read more `firstFrame`s than `transport`s. The step ORDER
//  is the catalogue's, never the report's.
//
//  DROP-OFF IS THE ABANDONMENT. There is no timeout and no "abandoned" event:
//  388 entered `open` and 344 reached `firstFrame` already states it, and
//  synthesising an abandonment on a timer would invent a number the funnel
//  holds and have to guess a threshold to do it. A visitor who navigates away
//  mid-connect leaves through `close()`, which reports nothing — counting that
//  as a failure would double-count every abandonment as a fault.
//
//  WHAT THE FUNNEL DOES NOT CONTAIN, and why a step can look healthier than the
//  door it sits behind: three refusals are counted OUTSIDE their flow on
//  purpose (walk-in access closed, no WebAuthn, a claim refused mid-session).
//  Had they entered the funnel, the drop-off at `landing` would read as a
//  landing page nobody understands and somebody would rewrite copy to fix an
//  operator switch. Only genuine drop-off is left here to be read as drop-off.
//
//  No charting library: a bar is a div whose width is a percentage.
// ============================================================================

import { useMemo } from 'react';
import type { AnalyticsReport, Catalogue } from './types';
import { dataState, funnelRows } from './reportMath';
import { ReportHeader } from './ReportHeader';
import './reportViews.css';

export interface FunnelViewProps {
  readonly report: AnalyticsReport;
  readonly catalogue: Catalogue;
}

export function FunnelView({ report, catalogue }: FunnelViewProps) {
  const flows = useMemo(() => funnelRows(catalogue, report), [catalogue, report]);
  const state = dataState(report);
  const silent = flows.filter((f) => f.entered === 0).length;

  return (
    <section className="obs-section">
      <h2>Flows — where attempts die</h2>
      <p className="obs-lede">
        Every flow the catalogue declares, whether or not anybody attempted it. Bars are
        relative to the attempts that entered the flow&rsquo;s first step. The number in red is
        how many attempts did not reach the next step; that drop-off <i>is</i> the abandonment,
        so nothing here invents an &ldquo;abandoned&rdquo; event to go beside it.
      </p>
      <ReportHeader report={report} zeroMeans="nobody attempted this flow" />

      {flows.map((f) => {
        const base = f.entered;
        return (
          <div className="obs-funnel" key={f.flow}>
            <h3>{f.flow}</h3>
            <p className="obs-lede" style={{ margin: '0 0 6px' }}>{f.what}</p>
            {base === 0 ? (
              <p className={state === 'ok' ? 'obs-never' : 'obs-unknown'} style={{ fontSize: 12.5 }}>
                {state === 'ok'
                  ? 'no attempt entered this flow in this window'
                  : 'no data in this window — see the banner above'}
              </p>
            ) : (
              f.steps.map((s) => (
                <div className="obs-step" key={s.step}>
                  <span className="obs-step-name">{s.step}</span>
                  <span className="obs-bar">
                    <span style={{ width: `${Math.min(100, (100 * s.entered) / base)}%` }} />
                  </span>
                  <span className="obs-step-counts">
                    {s.entered.toLocaleString()} entered
                    {s.ok > 0 ? <> · {s.ok.toLocaleString()} completed</> : null}
                    {s.failed > 0 ? <> · <span className="obs-lost">{s.failed.toLocaleString()} failed here</span></> : null}
                    {s.lost !== null && s.lost > 0 ? (
                      <> · <span className="obs-lost">−{s.lost.toLocaleString()} lost</span></>
                    ) : null}
                  </span>
                </div>
              ))
            )}
            {f.failReasons.length > 0 ? (
              <ul className="obs-fails">
                {f.failReasons.map((r) => (
                  <li key={r.reason}>
                    failed with reason <code>{r.reason}</code>: {r.n.toLocaleString()}
                  </li>
                ))}
              </ul>
            ) : null}
          </div>
        );
      })}

      <p className="obs-tally">
        {state === 'ok'
          ? `${silent} of ${flows.length} declared flows saw no attempt at all in this window.`
          : `${flows.length} declared flows, none of which this window can speak for.`}
      </p>
      <p className="obs-note">
        A fail reason is a short stable token the call site chose, never a message — the message
        lane is the error table. A failure reported with no reason lands on the step the attempt
        was standing on and is shown there as <i>failed here</i>; that half is not in{' '}
        <code>reach-report.py</code>&rsquo;s output, which prints only the named reasons.
      </p>
    </section>
  );
}

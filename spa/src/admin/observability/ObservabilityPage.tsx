// ============================================================================
//  ObservabilityPage — the one place all of this is readable.
//  ---------------------------------------------------------------------------
//  Five views over three stores, and the reason they are one page rather than
//  five is the CROSS-LINKS. Separately, each answers a question and leaves you
//  somewhere else to go:
//
//    "station.connect fails 12% of the time"   ...so show me one that failed.
//    "this fingerprint happened 40 times"      ...so show me a session it hit.
//    "this trace died in `transport`"          ...so is that normal, or today?
//
//  Every one of those is a jump from an aggregate to an instance or back, and a
//  tool that cannot make the jump leaves the operator copying ids between two
//  browser tabs. The aggregate answers WHETHER, the trace answers WHY, and
//  neither is much use alone — see docs/ANALYTICS.md, which argues the same
//  thing about the stores themselves.
//
//  WHY THE TABS ARE A URL. `?view=traces&errorsOnly=1` is the whole state, so a
//  slice worth showing somebody is a link, not a set of instructions. The trace
//  list already round-trips its own filters through the query string
//  (traceFilters.ts); this only adds which view is open, and defers to that
//  module for everything else rather than keeping a second copy of the rules.
// ============================================================================

import { useCallback, useEffect, useState } from 'react';
import type { AnalyticsReport, Catalogue, ClientClass, TraceDetail as TraceDoc } from './types';
import { TraceList } from './TraceList';
import { TraceDetail } from './TraceDetail';
import { ReachTable } from './ReachTable';
import { FunnelView } from './FunnelView';
import { MetricsView } from './MetricsView';
import { ErrorsView } from './ErrorsView';
import { fetchTrace, isForbidden, isUnavailable } from './traceApi';
import { CLIENT_CLASSES, fetchReport, loadCatalogue } from './reportApi';
import { AdminNav } from '../AdminNav';
import './observability.css';

type View = 'traces' | 'reach' | 'funnels' | 'metrics' | 'errors';

const VIEWS: Array<{ id: View; label: string; blurb: string }> = [
  { id: 'traces', label: 'Traces', blurb: 'Individual journeys, and the spans inside them' },
  { id: 'reach', label: 'Reach', blurb: 'Which features are used, and whether deliberately' },
  { id: 'funnels', label: 'Funnels', blurb: 'Where attempts at a journey die' },
  { id: 'metrics', label: 'Metrics', blurb: 'How long things took, and what they cost' },
  { id: 'errors', label: 'Errors', blurb: 'Faults, grouped, with the flow they broke' },
];

function readView(search: string): View {
  const v = new URLSearchParams(search).get('view');
  return VIEWS.some((x) => x.id === v) ? (v as View) : 'traces';
}

/** Put the open view in the URL without adding a history entry per tab click —
 *  the back button should leave this page, not walk back through five tabs. */
function writeView(view: View): void {
  try {
    const url = new URL(window.location.href);
    url.searchParams.set('view', view);
    window.history.replaceState(null, '', url.toString());
  } catch { /* a URL we cannot rewrite costs a shareable link, nothing more */ }
}

export function ObservabilityPage() {
  const [view, setView] = useState<View>(() => readView(window.location.search));
  const [trace, setTrace] = useState<TraceDoc | null>(null);
  const [traceError, setTraceError] = useState<string | null>(null);

  // The aggregate side. One fetch shared by four views: they read the same
  // document, and fetching it per tab would let two tabs disagree about a
  // number while sitting next to each other.
  const [days, setDays] = useState(30);
  const [klass, setKlass] = useState<ClientClass>('human');
  const [report, setReport] = useState<AnalyticsReport | null>(null);
  const [reportError, setReportError] = useState<string | null>(null);
  const [catalogue] = useState<Catalogue>(() => loadCatalogue());

  const needsReport = view !== 'traces';
  useEffect(() => {
    if (!needsReport) return;
    let alive = true;
    setReportError(null);
    fetchReport(days, klass)
      .then((r) => { if (alive) setReport(r); })
      .catch((e: unknown) => { if (alive) setReportError(e instanceof Error ? e.message : String(e)); });
    return () => { alive = false; };
  }, [needsReport, days, klass]);

  const openTrace = useCallback((traceId: string) => {
    setTraceError(null);
    fetchTrace(traceId)
      .then(setTrace)
      .catch((e: unknown) => {
        // The two refusals a reader must not confuse with "no such trace":
        // not being an admin, and the store not being wired up at all.
        setTraceError(
          isForbidden(e) ? 'Traces are admin-only, and this session is not an admin.'
            : isUnavailable(e) ? 'The trace store is not available on this deployment.'
            : `Could not open ${traceId.slice(0, 12)}…`,
        );
      });
  }, []);

  const show = useCallback((next: View) => { setView(next); writeView(next); }, []);

  /** Errors -> traces: the fingerprint rides along in the URL so the trace list
   *  opens already narrowed. It is not a server-side filter (the search route
   *  has no fingerprint facet), so this narrows to the failures and says so —
   *  an honest approximation beats a filter that silently matches nothing. */
  const traceThisFault = useCallback((fp: string) => {
    try {
      const url = new URL(window.location.href);
      url.searchParams.set('errorsOnly', '1');
      url.searchParams.set('view', 'traces');
      window.history.replaceState(null, '', url.toString());
      window.dispatchEvent(new PopStateEvent('popstate'));
    } catch { /* the tab switch below still happens */ }
    setTraceError(`Showing failed traces. Look for fingerprint ${fp} on a span's exception event.`);
    show('traces');
  }, [show]);

  return (
    <div className="obs-page-scroll">
      <AdminNav />
      <main className="obs-page">
        <header className="obs-head">
          <h1>Observability</h1>
          <p className="obs-sub">
            Everything this gallery records about itself. The aggregates say <em>whether</em> and{' '}
            <em>how often</em>; the traces say <em>why</em>, for one journey at a time.
          </p>
          <nav className="obs-tabs" aria-label="Observability views">
            {VIEWS.map((v) => (
              <button
                key={v.id}
                type="button"
                className={`obs-tab${view === v.id ? ' obs-tab--on' : ''}`}
                aria-current={view === v.id ? 'page' : undefined}
                title={v.blurb}
                onClick={() => show(v.id)}
              >
                {v.label}
              </button>
            ))}
          </nav>
        </header>

        {needsReport && (
          <div className="obs-controls">
            <label>
              Window
              <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
                <option value={1}>last 24 hours</option>
                <option value={7}>last 7 days</option>
                <option value={30}>last 30 days</option>
                <option value={365}>last year</option>
              </select>
            </label>
            <label>
              Reported by
              <select value={klass} onChange={(e) => setKlass(e.target.value as ClientClass)}>
                {CLIENT_CLASSES.map((c) => (
                  <option key={c} value={c}>
                    {c === 'probe' ? 'probe (this lab’s own automation)' : c}
                  </option>
                ))}
              </select>
            </label>
            {/* Said out loud rather than left to the dropdown: a window with no
                visits is the single easiest way to misread this whole page. */}
            <span className="obs-hint">
              A zero here means “nobody reached it in this window” — never “unreachable”.
            </span>
          </div>
        )}

        {view === 'traces' && (
          <>
            {traceError && <p className="obs-notice">{traceError}</p>}
            <TraceList onOpenTrace={openTrace} />
            {trace && (
              <TraceDetail
                trace={trace}
                onOpenTrace={openTrace}
                onSelectSession={(sessionId) => {
                  setTraceError(`Filter the list by session ${sessionId} to see its other journeys.`);
                }}
              />
            )}
          </>
        )}

        {needsReport && reportError && <p className="obs-notice">{reportError}</p>}
        {needsReport && !report && !reportError && <p className="obs-notice">Loading the report…</p>}
        {report && view === 'reach' && <ReachTable report={report} catalogue={catalogue} />}
        {report && view === 'funnels' && <FunnelView report={report} catalogue={catalogue} />}
        {report && view === 'metrics' && <MetricsView report={report} catalogue={catalogue} />}
        {report && view === 'errors' && (
          <ErrorsView report={report} onSelectFingerprint={traceThisFault} />
        )}
      </main>
    </div>
  );
}

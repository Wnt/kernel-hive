// ============================================================================
//  admin/observability/TraceList — find the trace.
//  ---------------------------------------------------------------------------
//  The list is the entry point to everything else on this surface: a flame
//  graph is only reachable once you have decided WHICH trace, and deciding that
//  is a filtering problem, not a rendering one. So the weight here is in the
//  filter bar and in the empty states, not in the table.
//
//  Three decisions worth stating up front, because each of them is a place a
//  trace UI usually misleads:
//
//  * THE FILTER VALUES COME FROM THE DATA. `facets()` returns the journey names,
//    classes and statuses that actually exist, with counts. A hardcoded list
//    would keep offering a journey that stopped being emitted and would hide one
//    that appeared without anybody declaring it — and noticing the second is
//    half the value of having this at all.
//  * PAGING AND SORTING ARE THE STORE'S. `traces.py` orders newest-first and
//    pages with LIMIT/OFFSET over an index. Fetching everything and slicing in
//    the browser would work for a week and then quietly become the reason the
//    page is slow.
//  * THE VIEW IS THE URL. Every filter round-trips through the query string
//    (traceFilters.ts), so an interesting slice is a link somebody can paste.
// ============================================================================

import { useCallback, useEffect, useState } from 'react';
import type { TraceFilters, TraceSummary } from './types';
import { exportOtlp, fetchTrace, OTLP_EXPORT_CAP } from './traceApi';
import { totalTraces, useTraceFacets, useTraceSearch } from './useTraces';
import {
  DEFAULT_FILTERS, DEFAULT_LIMIT, WINDOWS,
  filtersToSearch, isTraceId, isUnfiltered, parseFilters, windowIdFor, withWindow,
} from './traceFilters';
import './TraceList.css';

const FILTER_KEYS = ['session', 'name', 'class', 'status', 'errorsOnly', 'sinceMs', 'untilMs', 'minDurMs', 'limit', 'offset'];

/** A URL that names no filter at all is a first visit, and gets the defaults —
 *  above all `class: human` (see DEFAULT_FILTERS for why that is not neutral).
 *  A URL that names ANY filter is somebody's saved slice and is honoured
 *  exactly, including the choice to leave the class open. */
function initialFilters(search: string): TraceFilters {
  const q = new URLSearchParams(search);
  const named = FILTER_KEYS.some((k) => q.has(k));
  return named ? parseFilters(q) : { ...DEFAULT_FILTERS };
}

function ago(then: number, now: number): string {
  const s = Math.max(0, Math.round((now - then) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

function dur(ms: number): string {
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(ms < 10_000 ? 2 : 1)} s`;
  return `${Math.floor(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
}

function SessionCell({ id }: { id: string }) {
  const [copied, setCopied] = useState(false);
  // Truncated because a session id is 20-odd opaque characters that no operator
  // reads — but the WHOLE thing is what you paste into the session filter, so
  // it has to be copyable rather than merely visible.
  return (
    <button
      type="button"
      className="tl-session"
      title={`${id} — click to copy`}
      onClick={(e) => {
        e.stopPropagation();
        void navigator.clipboard?.writeText(id).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 1200);
        });
      }}
    >
      {copied ? 'copied' : id.slice(0, 8)}
    </button>
  );
}

function Row({ t, now, selected, onOpen }: { t: TraceSummary; now: number; selected: boolean; onOpen: () => void }) {
  return (
    // A row is a control, so it is reachable and openable from the keyboard;
    // an operator working a long list should not have to reach for the mouse.
    <tr
      className={`tl-row${selected ? ' tl-row--on' : ''}${t.errorCount ? ' tl-row--err' : ''}`}
      tabIndex={0}
      onClick={onOpen}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onOpen(); } }}
    >
      <td title={new Date(t.startedMs).toLocaleString()}>{ago(t.startedMs, now)}</td>
      <td className="tl-name">{t.name}</td>
      <td className="tl-num">{dur(t.durMs)}</td>
      <td className="tl-num">{t.spanCount}</td>
      <td className="tl-num">{t.errorCount > 0 ? <span className="tl-errs">{t.errorCount}</span> : '—'}</td>
      <td><span className={`tl-class tl-class--${t.class}`}>{t.class}</span></td>
      <td><SessionCell id={t.sessionId} /></td>
    </tr>
  );
}

export function TraceList({ onOpenTrace }: { onOpenTrace: (traceId: string) => void }) {
  const [filters, setFilters] = useState<TraceFilters>(() => initialFilters(window.location.search));
  const [selected, setSelected] = useState<string | null>(null);
  const [jump, setJump] = useState('');
  const [notice, setNotice] = useState<string | null>(null);
  const now = Date.now();

  const search = useTraceSearch(filters);
  const facets = useTraceFacets();

  // The URL is written with replaceState rather than pushState: an operator
  // narrowing a filter is refining ONE view, and a back button that walks
  // backwards through every keystroke of a session id is worse than useless.
  // Done with the history API directly rather than react-router's
  // useSearchParams so this component does not require a Router around it —
  // the shell that mounts it belongs to another stream.
  useEffect(() => {
    const q = filtersToSearch(filters);
    const next = `${window.location.pathname}${q ? `?${q}` : ''}`;
    if (next !== `${window.location.pathname}${window.location.search}`) {
      window.history.replaceState(null, '', next);
    }
  }, [filters]);

  useEffect(() => {
    const onPop = () => setFilters(initialFilters(window.location.search));
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  // Any filter change resets paging: page 4 of one filter is not page 4 of
  // another, and keeping the offset lands the operator on an empty page that
  // reads as "no matches".
  const set = useCallback((patch: TraceFilters) => {
    setFilters((prev) => ({ ...prev, offset: 0, ...patch }));
  }, []);

  const names = facets.state.phase === 'ready' ? facets.state.data.names : [];
  const classes = facets.state.phase === 'ready' ? facets.state.data.classes : [];
  const storeTotal = facets.state.phase === 'ready' ? totalTraces(facets.state.data) : null;
  const probeCount = classes.find((c) => c.value === 'probe')?.n ?? 0;

  const openTrace = useCallback((id: string) => {
    setSelected(id);
    onOpenTrace(id);
  }, [onOpenTrace]);

  // The trace-id box is a JUMP, not a filter — the search route has no trace-id
  // filter. It is checked against the store first so a mistyped id says so here,
  // instead of opening a detail view onto nothing.
  const doJump = useCallback(async () => {
    const id = jump.trim();
    if (!isTraceId(id)) { setNotice('A trace id is 32 hex characters.'); return; }
    try {
      await fetchTrace(id);
      setNotice(null);
      openTrace(id);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'no such trace');
    }
  }, [jump, openTrace]);

  const doExport = useCallback(async () => {
    try {
      const { bytes } = await exportOtlp(filters);
      setNotice(`Exported ${(bytes / 1024).toFixed(0)} kB of OTLP/JSON (at most ${OTLP_EXPORT_CAP} traces).`);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : 'export failed');
    }
  }, [filters]);

  if (search.state.phase === 'forbidden' || facets.state.phase === 'forbidden') {
    return (
      <p className="tl-empty tl-empty--stop">
        <strong>Traces are admin-only.</strong> A trace says which session did what, so unlike the
        anonymous aggregates it leaves the box only through an admin session. This is a refusal,
        not an empty list. <a href="/admin">Sign in as an admin</a>.
      </p>
    );
  }
  if (search.state.phase === 'unavailable') {
    return (
      <p className="tl-empty tl-empty--stop">
        <strong>The trace store is not available.</strong> The serving plane answered 503, which
        means it started without a trace store — tracing is off in this build, or the database
        failed to open. Nothing is wrong with your filter.
      </p>
    );
  }

  const result = search.state.phase === 'ready' ? search.state.data : null;
  const rows = result?.traces ?? [];
  const offset = filters.offset ?? 0;
  const limit = filters.limit ?? DEFAULT_LIMIT;

  return (
    <section className="tl">
      <div className="tl-bar">
        <label className="tl-chk">
          <input
            type="checkbox"
            checked={!!filters.errorsOnly}
            onChange={(e) => set({ errorsOnly: e.target.checked || undefined })}
          />
          Errors only
        </label>

        <label className="tl-field">
          <span>Journey</span>
          <select value={filters.name ?? ''} onChange={(e) => set({ name: e.target.value || undefined })}>
            <option value="">Any ({names.reduce((s, n) => s + n.n, 0)})</option>
            {names.map((n) => <option key={n.value} value={n.value}>{n.value} ({n.n})</option>)}
          </select>
        </label>

        <label className="tl-field">
          <span>Since</span>
          <select
            value={windowIdFor(filters, now)}
            onChange={(e) => setFilters((prev) => withWindow(prev, e.target.value, Date.now()))}
          >
            {WINDOWS.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}
            {windowIdFor(filters, now) === 'custom' && <option value="custom">Custom</option>}
          </select>
        </label>

        <label className="tl-field">
          <span>Slower than</span>
          <input
            type="number" min={0} step={100} className="tl-num-in"
            value={filters.minDurMs ?? ''}
            placeholder="ms"
            onChange={(e) => set({ minDurMs: e.target.value === '' ? undefined : Math.max(0, Number(e.target.value)) })}
          />
        </label>

        <label className="tl-field">
          <span>Class</span>
          <select value={filters.class ?? ''} onChange={(e) => set({ class: (e.target.value || undefined) as TraceFilters['class'] })}>
            <option value="">All classes</option>
            {classes.map((c) => <option key={c.value} value={c.value}>{c.value} ({c.n})</option>)}
          </select>
        </label>

        <label className="tl-field">
          <span>Session</span>
          <input
            type="text" className="tl-text" placeholder="session id"
            value={filters.session ?? ''}
            onChange={(e) => set({ session: e.target.value.trim() || undefined })}
          />
        </label>

        <label className="tl-field">
          <span>Trace id</span>
          <input
            type="text" className="tl-text" placeholder="32 hex — opens it"
            value={jump}
            onChange={(e) => setJump(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') void doJump(); }}
          />
        </label>

        <button type="button" className="tl-btn" onClick={() => { setFilters({ ...DEFAULT_FILTERS }); setNotice(null); }}>
          Reset
        </button>
        <button type="button" className="tl-btn" onClick={() => void doExport()} disabled={!result?.total}>
          Export OTLP
        </button>
      </div>

      {/* The active class is never silent: a list that is quietly hiding two
          thirds of its rows is how an operator reads the test fleet as
          visitors, or misses that they are looking at it. */}
      <p className={`tl-classline${filters.class ? '' : ' tl-classline--open'}`}>
        {filters.class
          ? <>Showing <strong>{filters.class}</strong> traces only{filters.class === 'human' && probeCount > 0
              ? <> — {probeCount} <button type="button" className="tl-link" onClick={() => set({ class: 'probe' })}>probe traces</button> hidden (this lab drives its own SPA)</>
              : null}.</>
          : <>Showing <strong>all classes</strong>, including this lab&apos;s own browser probes — those are not visitors.</>}
      </p>

      {notice && <p className="tl-notice">{notice}</p>}
      {facets.state.phase === 'error' && <p className="tl-notice">Filter values unavailable: {facets.state.message}</p>}

      {search.state.phase === 'error' && <p className="tl-empty tl-empty--stop">Search failed: {search.state.message}</p>}
      {search.state.phase === 'loading' && <p className="tl-empty">Searching…</p>}

      {result && rows.length === 0 && (
        storeTotal === 0
          // A brand-new deployment has an empty store, and that must not look
          // like a filter that excluded everything. The facets are unfiltered,
          // so their being empty is the difference.
          ? <p className="tl-empty"><strong>No traces have been recorded yet.</strong> The store is
              empty — no tab has uploaded a span. Nothing here is filtered out.</p>
          : <p className="tl-empty"><strong>No traces match these filters.</strong> The store holds
              {storeTotal === null ? ' other' : ` ${storeTotal}`} traces.{' '}
              <button type="button" className="tl-link" onClick={() => setFilters({ ...DEFAULT_FILTERS })}>Reset the filters</button>.</p>
      )}

      {result && rows.length > 0 && (
        <>
          <table className="tl-table">
            <thead>
              <tr>
                <th>When</th><th>Journey</th><th>Duration</th><th>Spans</th><th>Errors</th><th>Class</th><th>Session</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((t) => (
                <Row key={t.traceId} t={t} now={now} selected={t.traceId === selected} onOpen={() => openTrace(t.traceId)} />
              ))}
            </tbody>
          </table>
          <div className="tl-foot">
            <span>
              Showing {offset + 1}–{offset + rows.length} of {result.total}
              {isUnfiltered(filters) ? '' : ' matched'}
            </span>
            <button type="button" className="tl-btn" disabled={offset === 0}
              onClick={() => setFilters((p) => ({ ...p, offset: Math.max(0, (p.offset ?? 0) - limit) }))}>
              Newer
            </button>
            <button type="button" className="tl-btn" disabled={offset + rows.length >= result.total}
              onClick={() => setFilters((p) => ({ ...p, offset: (p.offset ?? 0) + limit }))}>
              Older
            </button>
          </div>
        </>
      )}
    </section>
  );
}

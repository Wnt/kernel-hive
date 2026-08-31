// ============================================================================
//  admin/observability/TraceDetail — one trace, whole.
//  ---------------------------------------------------------------------------
//  Takes the trace as a PROP and fetches nothing. The data layer belongs to the
//  list view that already loaded this document; a panel that re-fetched what it
//  was handed would double every read of an admin-only, short-retention store
//  and could contradict the row the operator clicked.
//
//  The header states the trace's OWN summary numbers (span count, error count)
//  next to what the spans in hand actually add up to. Those disagree while a
//  trace is still arriving — traces.py rebuilds the summary as each batch lands
//  — and that disagreement is worth showing rather than smoothing over: it is
//  the difference between "this journey had 3 spans" and "3 spans of this
//  journey have reached the box so far".
// ============================================================================

import { useMemo, useState } from 'react';
import type { FlameLayout, RowAnomaly } from './flame';
import { buildFlameLayout, describeAnomaly, exceptionOf, formatDuration, visibleMs } from './flame';
import type { TraceDetail as Trace, TraceSpan } from './types';
import { FlameGraph } from './FlameGraph';
import './flame.css';

interface Props {
  trace: Trace;
  /** Lets the list view pivot to "this session's other traces". Optional
   *  because the panel is useful before that wiring exists. */
  onSelectSession?: (sessionId: string) => void;
}

export function TraceDetail({ trace, onSelectSession }: Props) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const layout = useMemo(() => buildFlameLayout(trace.spans), [trace.spans]);
  const selected = trace.spans.find((s) => s.spanId === selectedId) ?? null;
  const selectedRow = layout.rows.find((r) => r.span.spanId === selectedId) ?? null;

  // The WORST single span, not a sum: spans nest, so a child's hidden time is
  // also its parent's and adding them up would report more hidden time than the
  // trace lasted. The worst span is the one that answers "is any of this
  // duration a person walking away rather than the software being slow".
  const worstHidden = trace.spans.reduce((n, s) => Math.max(n, Math.max(0, s.hiddenMs)), 0);

  return (
    <section className="td-panel" aria-label={`Trace ${trace.name}`}>
      <header className="td-head">
        <h2 className="td-title">{trace.name}</h2>
        <div className="td-id">
          <span>{trace.traceId}</span>
          <CopyButton value={trace.traceId} label="trace id" />
        </div>
        <div className="td-id">
          <span>session {trace.sessionId}</span>
          <CopyButton value={trace.sessionId} label="session id" />
          {onSelectSession && (
            <button type="button" className="td-link" onClick={() => onSelectSession(trace.sessionId)}>
              other traces from this session
            </button>
          )}
        </div>
        <Facts trace={trace} layout={layout} worstHidden={worstHidden} />
        {layout.anomalyCount > 0 && (
          <p className="td-warn" role="status">
            {layout.anomalyCount} of {layout.rows.length} rows are structurally broken — a missing parent, a
            span outliving its parent, or a parent loop. Every one is still drawn, at its true time; select a
            marked row to see what is wrong with it. This is damage to the RECORD of the journey, not a fault
            in the journey itself.
          </p>
        )}
      </header>

      <FlameGraph layout={layout} selectedId={selectedId} onSelect={setSelectedId} />

      <div className="td-detail">
        {selected && selectedRow
          ? <SpanDetail span={selected} anomalies={selectedRow.anomalies} />
          : <p className="td-hint">Select a span — click a row, or focus the graph and use ↑ ↓ — for its attributes and events.</p>}
      </div>
    </section>
  );
}

function Facts({ trace, layout, worstHidden }: { trace: Trace; layout: FlameLayout; worstHidden: number }) {
  // The span count is the one place the summary and the spans in hand are shown
  // together, because only their disagreement reveals a trace mid-flight.
  const partial = layout.rows.length !== trace.spanCount;
  return (
    <dl className="td-facts">
      <div className="td-fact">
        <dt>duration</dt>
        <dd>{formatDuration(layout.totalMs)}</dd>
      </div>
      <div className="td-fact">
        <dt>spans</dt>
        <dd>
          {layout.rows.length}
          {partial && <small> of {trace.spanCount} summarised</small>}
        </dd>
      </div>
      <div className={`td-fact${trace.errorCount > 0 ? ' td-fact--bad' : ''}`}>
        <dt>errors</dt>
        <dd>{trace.errorCount}</dd>
      </div>
      <div className="td-fact">
        <dt>class</dt>
        <dd>{trace.class}</dd>
      </div>
      <div className="td-fact">
        <dt>started</dt>
        <dd><small>{new Date(trace.startedMs).toLocaleString()}</small></dd>
      </div>
      {worstHidden > 0 && (
        <div className="td-fact">
          <dt>hidden, worst span</dt>
          <dd>{formatDuration(worstHidden)}</dd>
        </div>
      )}
    </dl>
  );
}

function SpanDetail({ span, anomalies }: { span: TraceSpan; anomalies: RowAnomaly[] }) {
  const exc = exceptionOf(span);
  const attrs = Object.entries(span.attributes);
  const hidden = Math.max(0, span.hiddenMs);
  return (
    <>
      <h3>{span.name}</h3>
      <dl className="td-kv">
        <dt>duration</dt>
        <dd>
          {formatDuration(span.durMs)}
          {/* The reading that stops a false "slow span" verdict. */}
          {hidden > 0 && <> — {formatDuration(visibleMs(span))} on screen, {formatDuration(hidden)} with the tab hidden</>}
        </dd>
        <dt>kind</dt>
        <dd>{span.kind}</dd>
        <dt>status</dt>
        <dd>
          {span.status}
          {span.status === 'unset' && <> — ended without asserting success; this is the default, not a pass</>}
          {span.statusMessage && <> — {span.statusMessage}</>}
        </dd>
        <dt>span id</dt>
        <dd>{span.spanId}</dd>
        <dt>parent</dt>
        <dd>{span.parentId ?? 'none (root)'}</dd>
      </dl>

      {exc && (
        <p className="td-exc">
          <strong>{exc.type}</strong>{exc.message ? `: ${exc.message}` : ''}
          {/* Stacks are deliberately not in this store — traces.py refuses
              `exception.stacktrace`; clientlog.jsonl keeps them per session. */}
          <br /><small>No stack here by design — /clientlog holds stacks for this session id.</small>
        </p>
      )}

      {anomalies.length > 0 && (
        <ul className="td-anoms">
          {anomalies.map((a) => <li key={a}>{describeAnomaly(a)}</li>)}
        </ul>
      )}

      <h4>attributes</h4>
      {attrs.length ? (
        <dl className="td-kv">
          {attrs.map(([k, v]) => <Fragmented key={k} k={k} v={String(v)} />)}
        </dl>
      ) : <p className="td-hint">None.</p>}

      <h4>events</h4>
      {span.events.length ? (
        <ul className="td-events">
          {span.events.map((e, i) => (
            <li key={`${e.n}-${e.t}-${i}`}>
              <code>+{formatDuration(e.t - span.startedMs)}</code>
              <span>
                {e.n}
                {e.a && Object.keys(e.a).length > 0 && (
                  <> — {Object.entries(e.a).map(([k, v]) => `${k}=${String(v)}`).join(', ')}</>
                )}
              </span>
            </li>
          ))}
        </ul>
      ) : <p className="td-hint">None.</p>}
    </>
  );
}

/** A `<dt>/<dd>` pair. Split out only because a fragment with a key cannot be
 *  written inline in the map above without the shorthand losing the key. */
function Fragmented({ k, v }: { k: string; v: string }) {
  return <><dt>{k}</dt><dd>{v}</dd></>;
}

function CopyButton({ value, label }: { value: string; label: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className="td-copy"
      aria-label={`Copy ${label}`}
      onClick={() => {
        // Clipboard is unavailable on an insecure origin and can be refused by
        // permission; the id is on screen either way, so failing quietly here
        // costs nothing an operator cannot work around.
        try {
          void navigator.clipboard?.writeText(value).then(() => setDone(true), () => {});
        } catch { /* no clipboard */ }
      }}
    >
      {done ? 'copied' : 'copy'}
    </button>
  );
}

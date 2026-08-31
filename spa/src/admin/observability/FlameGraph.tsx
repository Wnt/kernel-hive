// ============================================================================
//  admin/observability/FlameGraph — the bars.
//  ---------------------------------------------------------------------------
//  Time on X, nesting on Y, one row per span. All geometry comes from
//  flame.ts; nothing here decides where anything goes, so what a reader can be
//  misled by is limited to COLOUR and LABELLING, which is what this file is
//  careful about:
//
//  * ONE colour axis, and it is status. Kind, depth and anomalies get shape,
//    text and glyphs instead. A second colour axis on a chart this dense makes
//    both unreadable, and status is the one an operator is scanning for.
//  * `unset` is grey, never green. It is the DEFAULT — a span that ended
//    without asserting success (see traces.py) — and colouring the common case
//    as a pass invents a fleet-wide green nobody measured.
//  * Nothing is carried by colour alone: every row states its status in text
//    in the label column and again in its `aria-label`.
//
//  HIDDEN TIME IS DRAWN AS A HATCH, RIGHT-ANCHORED, AND THAT POSITION IS A LIE
//  WE LABEL AS ONE. The store keeps how MUCH of a span passed with the tab
//  hidden, never WHEN (spa/src/analytics/trace.ts accumulates a total against
//  one global visibility clock). Drawing the hatch at some specific offset
//  would claim knowledge we do not have, so it sits at the end of the bar, is
//  hatched rather than filled so it never reads as a measured interval, and the
//  legend says outright that only the amount is known.
// ============================================================================

import { useCallback, useMemo } from 'react';
import type { FlameLayout, FlameRow } from './flame';
import { describeAnomaly, formatDuration, hiddenShare, visibleMs } from './flame';
import './flame.css';

/** Indentation stops growing here. Depth is unbounded in principle (the client
 *  allows 32 nested active spans) and an indent that keeps growing eats the
 *  name column until nothing is readable at depth 15. Past this the exact
 *  depth is carried by a numeric badge and by `aria-level`, which is where a
 *  screen reader was reading it from anyway. */
const MAX_INDENT = 8;
const INDENT_PX = 11;

const STATUS_TEXT = { error: 'error', ok: 'ok', unset: 'no status' } as const;

function tickLabels(totalMs: number): string[] {
  return [0, 0.25, 0.5, 0.75, 1].map((f) => formatDuration(totalMs * f));
}

/** Everything a hover tooltip and a screen reader should hear, in one string.
 *  Hidden time is only mentioned when there IS some — on a trace where nobody
 *  backgrounded the tab, a "0 ms hidden" on all 200 rows is pure noise. */
function rowLabel(row: FlameRow): string {
  const { span } = row;
  const bits = [
    `${span.name}, depth ${row.depth}`,
    `${formatDuration(span.durMs)}`,
    STATUS_TEXT[span.status],
  ];
  if (span.kind !== 'internal') bits.push(span.kind);
  if (span.hiddenMs > 0) {
    bits.push(`${formatDuration(span.hiddenMs)} of it hidden, ${formatDuration(visibleMs(span))} on screen`);
  }
  for (const a of row.anomalies) bits.push(describeAnomaly(a));
  return bits.join(' — ');
}

interface Props {
  layout: FlameLayout;
  selectedId: string | null;
  onSelect: (spanId: string) => void;
}

export function FlameGraph({ layout, selectedId, onSelect }: Props) {
  const { rows, totalMs } = layout;
  const ticks = useMemo(() => tickLabels(totalMs), [totalMs]);

  // The tree owns focus and moves an active DESCENDANT, rather than 200 rows
  // each taking a tab stop or fighting over focus() on every re-render.
  const onKeyDown = useCallback((e: React.KeyboardEvent) => {
    if (!rows.length) return;
    // -1 when nothing is selected yet: the first ArrowDown then lands on row 0
    // and the first ArrowUp on the last row, which is what a list should do.
    const at = rows.findIndex((r) => r.span.spanId === selectedId);
    let next: number;
    if (e.key === 'ArrowDown') next = Math.min(rows.length - 1, at + 1);
    else if (e.key === 'ArrowUp') next = at < 0 ? rows.length - 1 : Math.max(0, at - 1);
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = rows.length - 1;
    else return;
    e.preventDefault();
    onSelect(rows[next].span.spanId);
  }, [rows, selectedId, onSelect]);

  if (!rows.length) {
    return <p className="fg-empty">This trace has no spans. Nothing was dropped here — the store returns a trace only once at least one span has landed, so this is a trace whose spans have since been pruned.</p>;
  }

  return (
    <div className="fg">
      <div className="fg-axis" aria-hidden="true">
        <div className="fg-axis-gutter">span</div>
        <div className="fg-axis-scale">
          {ticks.map((t, i) => (
            <span className="fg-tick" key={t + String(i)} style={{ left: `${i * 25}%` }}>{t}</span>
          ))}
        </div>
      </div>

      <div
        className="fg-rows"
        role="tree"
        tabIndex={0}
        aria-label={`Flame graph, ${rows.length} spans over ${formatDuration(totalMs)}`}
        aria-activedescendant={selectedId ? `fg-row-${selectedId}` : undefined}
        onKeyDown={onKeyDown}
      >
        {rows.map((row) => (
          <Row
            key={row.span.spanId}
            row={row}
            selected={row.span.spanId === selectedId}
            onSelect={onSelect}
          />
        ))}
      </div>

      <ul className="fg-legend">
        <li><i className="fg-key fg-key--error" />error</li>
        <li><i className="fg-key fg-key--unset" />no status (the default — not a pass)</li>
        <li><i className="fg-key fg-key--ok" />ok (success asserted)</li>
        <li><i className="fg-key fg-key--hidden" />tab hidden — the AMOUNT is measured, the position in the span is not</li>
        <li><i className="fg-key fg-key--anomaly" />structurally broken; select the row for what is wrong</li>
      </ul>
    </div>
  );
}

function Row({ row, selected, onSelect }: { row: FlameRow; selected: boolean; onSelect: (id: string) => void }) {
  const { span, depth, x, width, hiddenWidth } = row;
  const indent = Math.min(depth, MAX_INDENT) * INDENT_PX;
  const label = rowLabel(row);
  const share = hiddenShare(span);

  return (
    <div
      id={`fg-row-${span.spanId}`}
      role="treeitem"
      aria-level={depth + 1}
      aria-selected={selected}
      aria-label={label}
      title={label}
      className={`fg-row${selected ? ' is-selected' : ''}${row.synthetic ? ' is-synthetic' : ''}`}
      onClick={() => onSelect(span.spanId)}
    >
      <div className="fg-name" style={{ paddingInlineStart: `${indent + 6}px` }}>
        {depth > MAX_INDENT && <span className="fg-depth" aria-hidden="true">·{depth}</span>}
        <span className="fg-name-text">{span.name}</span>
        {span.kind !== 'internal' && <span className="fg-kind" aria-hidden="true">{span.kind}</span>}
        {span.status === 'error' && <span className="fg-badge fg-badge--error" aria-hidden="true">error</span>}
        {row.anomalies.length > 0 && <span className="fg-badge fg-badge--anomaly" aria-hidden="true">!</span>}
      </div>
      <div className="fg-track">
        <div
          className={`fg-bar fg-bar--${span.status}`}
          style={{ left: `${x * 100}%`, width: `${width * 100}%` }}
        >
          {hiddenWidth > 0 && (
            <span
              className="fg-hidden"
              style={{ width: `${(hiddenWidth / width) * 100}%` }}
              aria-hidden="true"
            />
          )}
        </div>
        {/* Duration rides beside the bar rather than inside it: at 200 spans
            most bars are far too narrow to hold text, and a number that
            disappears at some widths is worse than one that never moves. */}
        <span className="fg-dur" style={{ left: `${Math.min(x + width, 0.82) * 100}%` }}>
          {formatDuration(span.durMs)}
          {share > 0.02 && <em className="fg-dur-hidden"> · {Math.round(share * 100)}% hidden</em>}
        </span>
      </div>
    </div>
  );
}

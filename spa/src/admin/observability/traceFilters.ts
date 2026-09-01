// ============================================================================
//  admin/observability/traceFilters — filter state as data, and as a URL.
//  ---------------------------------------------------------------------------
//  Pure. No fetch, no React, no clock reads except where a caller passes `now`
//  in. Everything here is about ONE property: a filtered view of the trace list
//  must be LINKABLE. An operator who finds an interesting slice pastes the URL
//  to somebody else, or to themselves next week, and gets the same slice back.
//
//  That is the property that quietly breaks — a key renamed, a number arriving
//  as a string, a stale key surviving a rewrite — so it is the property this
//  module is tested on (traceFilters.test.ts).
//
//  The validation here MIRRORS `scripts/serve/auth/routes.py::_search_filters`
//  and `traces.py`'s regexes. It is not a substitute for them: the server is the
//  authority and re-checks everything. It is here so a hand-edited URL fails at
//  the control that shows it, rather than travelling to the server as a filter
//  the operator cannot see and cannot have meant.
// ============================================================================

import type { ClientClass, SpanStatus, TraceFilters } from './types';

/** Server: `traces.py` NAME_RE. A root span's name, not free text. */
const NAME_RE = /^[A-Za-z][A-Za-z0-9._-]{0,79}$/;
/** Server: `traces.py` SESSION_RE. */
const SESSION_RE = /^[A-Za-z0-9._-]{1,64}$/;
/** W3C Trace Context: 128 bits of lowercase hex. Used by the "open this exact
 *  trace" box, which is a JUMP and not a filter — the search route has no
 *  trace-id filter, and inventing one in the URL would promise a slice the
 *  server cannot return. */
const TRACE_ID_RE = /^[0-9a-f]{32}$/;

const CLASSES: readonly ClientClass[] = ['human', 'probe', 'unknown'];
const STATUSES: readonly SpanStatus[] = ['unset', 'ok', 'error'];

/** The store clamps to 500 (`traces.py::search`). Mirrored so a URL can never
 *  claim a page size the server will silently shrink. */
export const MAX_LIMIT = 500;
export const DEFAULT_LIMIT = 50;

/** Time-window presets, newest-first. `null` means "everything the store still
 *  has" — which is 14 days, because that is the trace retention (traces.py). */
export const WINDOWS: ReadonlyArray<{ id: string; label: string; ms: number | null }> = [
  { id: '15m', label: '15 min', ms: 15 * 60_000 },
  { id: '1h', label: '1 hour', ms: 60 * 60_000 },
  { id: '6h', label: '6 hours', ms: 6 * 60 * 60_000 },
  { id: '24h', label: '24 hours', ms: 24 * 60 * 60_000 },
  { id: '7d', label: '7 days', ms: 7 * 24 * 60 * 60_000 },
  { id: 'all', label: 'All kept (14 d)', ms: null },
];

/** The class filter defaults to `human` — NOT to "everything".
 *
 *  docs/ANALYTICS.md §4: this lab drives its own SPA with browser probes
 *  (`scripts/e2e/*.mjs`), which set `navigator.webdriver` and are stored as
 *  `probe`. On a 63-station private gallery they can outnumber real visits, so
 *  an unfiltered list is mostly the test fleet, and an operator reading it as
 *  visitors would draw exactly the wrong conclusion. The default is opinionated
 *  on purpose; the UI's job is to make sure it is never SILENT. */
export const DEFAULT_FILTERS: TraceFilters = { class: 'human', limit: DEFAULT_LIMIT, offset: 0 };

function num(raw: string | null): number | undefined {
  if (raw === null || raw.trim() === '') return undefined;
  const n = Number(raw);
  // Rejects NaN, Infinity, negatives and fractions. The store's columns are
  // integer ms and integer counts; anything else is a mistyped URL.
  if (!Number.isSafeInteger(n) || n < 0) return undefined;
  return n;
}

function oneOf<T extends string>(raw: string | null, allowed: readonly T[]): T | undefined {
  return raw !== null && (allowed as readonly string[]).includes(raw) ? (raw as T) : undefined;
}

/** Read filters out of a query string. Unknown keys are DROPPED, not carried:
 *  the URL is a description of a filter set, and a key this build does not
 *  understand is one it cannot honour or display. */
export function parseFilters(search: string | URLSearchParams): TraceFilters {
  const q = typeof search === 'string' ? new URLSearchParams(search) : search;
  const out: TraceFilters = {};

  const session = q.get('session');
  if (session && SESSION_RE.test(session)) out.session = session;
  const name = q.get('name');
  if (name && NAME_RE.test(name)) out.name = name;

  const klass = oneOf(q.get('class'), CLASSES);
  if (klass) out.class = klass;
  const status = oneOf(q.get('status'), STATUSES);
  if (status) out.status = status;

  // Only the affirmative spelling is honoured. An `errorsOnly=0` in a URL means
  // the same as the key being absent, and round-trips to absent.
  if (q.get('errorsOnly') === '1') out.errorsOnly = true;

  const since = num(q.get('sinceMs'));
  if (since !== undefined) out.sinceMs = since;
  const until = num(q.get('untilMs'));
  if (until !== undefined) out.untilMs = until;
  const minDur = num(q.get('minDurMs'));
  if (minDur !== undefined) out.minDurMs = minDur;

  const limit = num(q.get('limit'));
  if (limit !== undefined) out.limit = Math.max(1, Math.min(MAX_LIMIT, limit));
  const offset = num(q.get('offset'));
  if (offset !== undefined) out.offset = offset;

  return out;
}

/** Filters → query string, WITHOUT a leading '?'. Empty in, empty out: a
 *  default view must produce a clean URL rather than a page of `=&`, both
 *  because it is what an operator expects to paste and because a URL that
 *  changes when nothing changed makes the back button lie. */
export function filtersToSearch(f: TraceFilters): string {
  const q = new URLSearchParams();
  if (f.session) q.set('session', f.session);
  if (f.name) q.set('name', f.name);
  if (f.class) q.set('class', f.class);
  if (f.status) q.set('status', f.status);
  if (f.errorsOnly) q.set('errorsOnly', '1');
  if (f.sinceMs !== undefined) q.set('sinceMs', String(f.sinceMs));
  if (f.untilMs !== undefined) q.set('untilMs', String(f.untilMs));
  if (f.minDurMs !== undefined) q.set('minDurMs', String(f.minDurMs));
  if (f.limit !== undefined) q.set('limit', String(f.limit));
  if (f.offset !== undefined && f.offset > 0) q.set('offset', String(f.offset));
  return q.toString();
}

/** The body posted to `/auth/traces/*`. Built key by key from a whitelist —
 *  never by spreading the filter object — so a field that finds its way into
 *  UI state cannot become a field the server is asked to interpret. The server
 *  whitelists again (`_search_filters`); this is the near end of the same rule. */
export function toWireFilters(f: TraceFilters): TraceFilters {
  const clean = parseFilters(filtersToSearch(f));
  // `limit` and `offset` always travel: paging is server-side (the store sorts
  // newest-first and pages with LIMIT/OFFSET), and leaving them off would ask
  // for the store's own default rather than the page the operator is looking at.
  return { ...clean, limit: clean.limit ?? DEFAULT_LIMIT, offset: clean.offset ?? 0 };
}

/** True when this is the "everything, all time" view — used to tell "no traces
 *  match your filter" apart from "there are no traces". */
export function isUnfiltered(f: TraceFilters): boolean {
  return (
    !f.session && !f.name && !f.class && !f.status && !f.errorsOnly
    && f.sinceMs === undefined && f.untilMs === undefined && f.minDurMs === undefined
  );
}

/** Which preset a `sinceMs` came from, for showing the window control in the
 *  state the operator left it in. Approximate by design: presets are stored as
 *  ABSOLUTE times (so a pasted link is the same slice, not the same phrase),
 *  and an absolute time drifts out of its preset as the clock moves. */
export function windowIdFor(f: TraceFilters, now: number): string {
  if (f.sinceMs === undefined) return 'all';
  const age = now - f.sinceMs;
  const hit = WINDOWS.find((w) => w.ms !== null && Math.abs(age - w.ms) <= w.ms * 0.25);
  return hit ? hit.id : 'custom';
}

/** Apply a preset, resolved to an absolute instant NOW. See `windowIdFor` for
 *  why absolute rather than relative. Paging resets: page 3 of the last hour is
 *  not page 3 of the last 15 minutes. */
export function withWindow(f: TraceFilters, windowId: string, now: number): TraceFilters {
  const w = WINDOWS.find((x) => x.id === windowId);
  const next: TraceFilters = { ...f, offset: 0 };
  if (!w || w.ms === null) delete next.sinceMs;
  else next.sinceMs = now - w.ms;
  return next;
}

/** Is this string a trace id we could open? The trace-id box is a jump, not a
 *  filter — see TRACE_ID_RE above. */
export function isTraceId(raw: string): boolean {
  return TRACE_ID_RE.test(raw.trim());
}

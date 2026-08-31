// ============================================================================
//  admin/observability/useTraces — the three trace reads, as React state.
//  ---------------------------------------------------------------------------
//  Same shape as admin/useWalkinAdmin.ts: a phase union rather than the
//  `{data, loading, error}` triple, because the states this surface has to keep
//  apart are not degrees of one another.
//
//    forbidden    you are not an admin — NOT an empty list
//    unavailable  the trace store is not bound: tracing is off, not broken
//    error        the query failed
//    ready        an answer, which may legitimately be zero rows
//
//  A zero-row `ready` still needs one more fact to be readable, and it is not in
//  the search response: is the store empty, or did the filter exclude
//  everything? That comes from the facets (see `useTraceFacets`), which is why
//  the list loads both.
// ============================================================================

import { useCallback, useEffect, useRef, useState } from 'react';
import type { TraceFacets, TraceFilters, TraceSearchResult } from './types';
import { fetchFacets, isForbidden, isUnavailable, searchTraces } from './traceApi';
import { filtersToSearch } from './traceFilters';

export type Loaded<T> =
  | { phase: 'loading' }
  | { phase: 'forbidden' }
  | { phase: 'unavailable' }
  | { phase: 'error'; message: string }
  | { phase: 'ready'; data: T };

function failure(error: unknown): Loaded<never> {
  if (isForbidden(error)) return { phase: 'forbidden' };
  if (isUnavailable(error)) return { phase: 'unavailable' };
  return { phase: 'error', message: error instanceof Error ? error.message : 'unknown error' };
}

/** Runs one load, guarding against the two orderings that produce wrong state:
 *  a resolve after unmount, and a slow first request landing after a fast
 *  second one. The second matters here — an operator retyping a filter fires
 *  several searches, and the LAST one asked for is the one on screen. */
function useLoader<T>(run: () => Promise<T>, key: string): { state: Loaded<T>; refresh: () => void } {
  const [state, setState] = useState<Loaded<T>>({ phase: 'loading' });
  const latest = useRef(0);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);

  // `run` is rebuilt on every render by callers that close over filters; the
  // KEY is what identifies a query, so the effect and the ref both hang off it.
  const runRef = useRef(run);
  runRef.current = run;

  const load = useCallback(async () => {
    const ticket = ++latest.current;
    setState({ phase: 'loading' });
    try {
      const data = await runRef.current();
      if (!alive.current || ticket !== latest.current) return;
      setState({ phase: 'ready', data });
    } catch (error) {
      if (!alive.current || ticket !== latest.current) return;
      setState(failure(error));
    }
  }, []);

  useEffect(() => { void load(); }, [load, key]);
  return { state, refresh: () => { void load(); } };
}

export function useTraceSearch(filters: TraceFilters): { state: Loaded<TraceSearchResult>; refresh: () => void } {
  return useLoader(() => searchTraces(filters), filtersToSearch(filters));
}

/** The values the filter bar offers, with counts — driven by the data, so a
 *  journey that stopped being emitted drops out of the filter and one nobody
 *  declared shows up in it (types.ts, traces.py::facets).
 *
 *  It is also this surface's answer to "is there any data at all": the facets
 *  are unfiltered by construction, so their class counts summing to zero means
 *  an EMPTY STORE, which is what a brand-new deployment looks like and must not
 *  be shown as a filter that matched nothing. */
export function useTraceFacets(): { state: Loaded<TraceFacets>; refresh: () => void } {
  return useLoader(() => fetchFacets(), 'facets');
}

export function totalTraces(facets: TraceFacets): number {
  return facets.classes.reduce((sum, c) => sum + c.n, 0);
}

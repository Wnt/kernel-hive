import { useEffect, useMemo, useRef, useState } from 'react';
import { useFleetTable, useStationUsage, type FleetEntry } from '../data/fleetTable';
import { FLEET_COLUMNS, type Column, type ColKey } from './fleetColumns';
import { accumulator, reach } from '../analytics';
import { beginFleetFindEpisode, type FleetFindEpisode } from './fleetFindEpisode';
import './FleetTable.css';

// Operator-facing fleet table: every lineup entry, one row, with the facts the
// registry can answer about HOW it runs. Data is /fleet-table.json — see
// scripts/stations_registry/fleet_table.py for every derivation rule. Column
// definitions (render / sort / facet) live in fleetColumns.tsx; this file is the
// table chrome: sort, free-text filter, and per-column facet filters (a header
// popover listing that column's distinct values with counts; a row must match
// EVERY active facet, and within one facet ANY chosen value).

type Facets = Map<ColKey, Set<string>>;

function matchesQuery(e: FleetEntry, q: string): boolean {
  if (!q) return true;
  const hay = FLEET_COLUMNS.flatMap((c) => c.facet(e)).concat([e.id, e.displayName]).join(' ').toLowerCase();
  return q.split(/\s+/).every((word) => hay.includes(word));
}

function matchesFacets(e: FleetEntry, facets: Facets): boolean {
  for (const [key, chosen] of facets) {
    if (chosen.size === 0) continue;
    const col = FLEET_COLUMNS.find((c) => c.key === key);
    if (!col) continue;
    const values = col.facet(e);
    if (!values.some((v) => chosen.has(v))) return false;
  }
  return true;
}

export function FleetTable() {
  const doc = useFleetTable();
  // Interaction totals arrive separately and land on the entries here, so the
  // 'use' column sorts and facets like any other. They are an annotation on the
  // registry's table, never part of the generated document.
  const stationUsage = useStationUsage();
  // The consumer half of fleet.usage.fetch. Reported when the annotation
  // actually carries numbers, not when the fetch returns: an empty map means
  // the columns rendered as blanks, and a blank column is not a use of the
  // endpoint. `reach` downgrades this to `auto` on its own if the tab is
  // hidden, so a background tab pre-rendering the table does not count as
  // having shown anybody anything.
  const usageRows = Object.keys(stationUsage).length;
  useEffect(() => {
    if (usageRows > 0) reach('fleet.usage.shown', 'show');
  }, [usageRows]);
  const [query, setQuery] = useState('');
  const [facets, setFacets] = useState<Facets>(new Map());
  // Sort chain: sorts[0] is primary, sorts[1] secondary, … Click a header to
  // make it primary (click again to flip); Shift+click to add it as the next
  // level (or flip it in place). An empty chain is the default order (year,
  // then id) — the same tiebreak every chain ends in.
  const [sorts, setSorts] = useState<Array<{ key: ColKey; dir: 1 | -1 }>>([]);
  const [open, setOpen] = useState<{ key: ColKey; x: number; y: number } | null>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  // The `fleet.find` episode: open -> narrow -> chooseStation, plus the
  // hesitation and steps-to-goal numbers. Held in a ref rather than state
  // because nothing renders from it, and opened in an effect rather than at
  // render time so StrictMode's double render cannot open two flows. Its
  // boundaries are deliberately the same mount/unmount pair as the scroll
  // accumulators below — see fleetFindEpisode.ts.
  const findRef = useRef<FleetFindEpisode | null>(null);
  useEffect(() => {
    const episode = beginFleetFindEpisode();
    findRef.current = episode;
    return () => {
      findRef.current = null;
      episode.end();
    };
  }, []);

  // ---- how much sideways hunting this table costs ---------------------------
  // `.fleet-table` is `width: max-content`, so on any realistic viewport the
  // columns people want are off-screen and finding one means scrolling to it.
  // Two numbers, committed once per visit rather than per scroll event:
  // DISTANCE in screen widths (device-divided-out, so a phone and the operator's
  // monitor are comparable), and REVERSALS — direction changes, which is what
  // overshooting or losing your place actually looks like. Distance alone
  // cannot tell a confident sweep from a hunt; together they can.
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const distance = accumulator('fleet.find.hScrollScreens');
    const reversals = accumulator('fleet.find.hScrollReversals');
    let last = el.scrollLeft;
    let dir = 0;
    const onScroll = () => {
      const delta = el.scrollLeft - last;
      if (delta === 0) return;
      last = el.scrollLeft;
      // Normalise by the viewport, not the content: "two screens of scrolling"
      // is the sentence the answer wants to be in.
      const width = el.clientWidth || 1;
      distance.add(Math.abs(delta) / width);
      const next = delta > 0 ? 1 : -1;
      if (dir !== 0 && next !== dir) reversals.add(1);
      dir = next;
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      el.removeEventListener('scroll', onScroll);
      // Commit on unmount, including the zero: a visitor who found what they
      // wanted without scrolling at all is the outcome the table is FOR, and
      // dropping those samples would leave a distribution of only the failures.
      distance.commit();
      reversals.commit();
    };
  }, []);

  // close the facet popover on outside click / Escape
  useEffect(() => {
    if (!open) return;
    const onDown = (ev: MouseEvent) => {
      if (popRef.current && !popRef.current.contains(ev.target as Node)) setOpen(null);
    };
    const onKey = (ev: KeyboardEvent) => { if (ev.key === 'Escape') setOpen(null); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [open]);

  const q = query.trim().toLowerCase();
  const rows = useMemo(() => {
    if (!doc) return [];
    const entries = doc.entries.map((e) => (stationUsage[e.id] ? { ...e, usage: stationUsage[e.id] } : e));
    const chain = sorts
      .map((s) => ({ col: FLEET_COLUMNS.find((c) => c.key === s.key), dir: s.dir }))
      .filter((s): s is { col: Column; dir: 1 | -1 } => s.col !== undefined);
    return entries
      .filter((e) => matchesQuery(e, q) && matchesFacets(e, facets))
      .sort((a, b) => {
        for (const { col, dir } of chain) {
          const av = col.sort(a), bv = col.sort(b);
          const cmp = typeof av === 'number' && typeof bv === 'number' ? av - bv : String(av).localeCompare(String(bv));
          if (cmp) return cmp * dir;
        }
        return a.year - b.year || a.id.localeCompare(b.id);
      });
  }, [doc, stationUsage, q, facets, sorts]);

  if (doc === undefined) return <div className="fleet-view"><p className="fleet-status">Loading fleet table…</p></div>;
  if (doc === null) {
    return (
      <div className="fleet-view">
        <p className="fleet-status">No fleet table published. Run <code>scripts/serve-https-spa.sh manifests</code> (it renders <code>fleet-table.json</code> from the registry).</p>
      </div>
    );
  }

  const onSort = (key: ColKey, additive: boolean) => {
    reach('fleet.sorted', 'act');
    findRef.current?.narrowed();
    // Sorting BY the usage column is the strongest evidence /usage/stations.json
    // earns the request it costs on every visit — somebody did not merely see
    // the numbers, they asked a question of them.
    if (key === 'use') reach('fleet.usage.sorted', 'act');
    return applySort(key, additive);
  };
  const applySort = (key: ColKey, additive: boolean) => setSorts((prev) => {
    const at = prev.findIndex((s) => s.key === key);
    if (additive) {
      if (at >= 0) return prev.map((s, i) => (i === at ? { key, dir: s.dir === 1 ? -1 : 1 } : s));
      return [...prev, { key, dir: 1 }];
    }
    if (at === 0) return [{ key, dir: prev[0].dir === 1 ? -1 : 1 }, ...prev.slice(1)];
    return [{ key, dir: 1 }, ...prev.filter((s) => s.key !== key)];
  });
  const sortRank = (key: ColKey) => sorts.findIndex((s) => s.key === key);
  const toggleValue = (key: ColKey, value: string) => {
    reach('fleet.faceted', 'act');
    findRef.current?.narrowed();
    return applyFacet(key, value);
  };
  const applyFacet = (key: ColKey, value: string) => setFacets((prev) => {
    const next = new Map(prev);
    const set = new Set(next.get(key) ?? []);
    if (set.has(value)) set.delete(value); else set.add(value);
    if (set.size) next.set(key, set); else next.delete(key);
    return next;
  });
  const clearFacet = (key: ColKey) => setFacets((prev) => { const next = new Map(prev); next.delete(key); return next; });
  const activeCount = [...facets.values()].reduce((n, s) => n + s.size, 0);

  // Facet value counts are computed over rows matching the OTHER filters, so a
  // popover shows how many rows each choice would keep (classic faceted search).
  const facetCounts = (col: Column): Array<[string, number]> => {
    const others = new Map(facets); others.delete(col.key);
    const counts = new Map<string, number>();
    for (const e of doc.entries) {
      if (!matchesQuery(e, q) || !matchesFacets(e, others)) continue;
      for (const v of new Set(col.facet(e))) counts.set(v, (counts.get(v) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0], undefined, { numeric: true }));
  };
  const openCol = open ? FLEET_COLUMNS.find((c) => c.key === open.key) ?? null : null;

  return (
    <div className="fleet-view">
      <div className="fleet-toolbar">
        <input
          type="search"
          className="fleet-search"
          placeholder="Free text: e.g. mame, kiosk, tcg, warpd…"
          value={query}
          onChange={(ev) => {
            // The empty -> non-empty transition only. Per keystroke this would
            // be the most-used feature in the gallery by twenty times, and the
            // action count would be measuring typing speed.
            if (!query && ev.target.value) {
              reach('fleet.searched', 'act');
              findRef.current?.narrowed();
            }
            setQuery(ev.target.value);
          }}
          aria-label="Filter stations"
        />
        {activeCount > 0 && (
          <div className="fleet-active" aria-label="Active column filters">
            {[...facets.entries()].map(([key, set]) => {
              const col = FLEET_COLUMNS.find((c) => c.key === key);
              return (
                <button key={key} type="button" className="fleet-chip" onClick={() => clearFacet(key)} title="Click to clear this column's filter">
                  {col?.label}: {[...set].join(' | ')} ×
                </button>
              );
            })}
            <button type="button" className="fleet-chip fleet-chip--clear" onClick={() => setFacets(new Map())}>clear all</button>
          </div>
        )}
        {sorts.length > 0 && (
          <button type="button" className="fleet-chip fleet-chip--clear" title="Reset to the default order (year)" onClick={() => setSorts([])}>
            sort: {sorts.map((s) => `${FLEET_COLUMNS.find((c) => c.key === s.key)?.label ?? s.key} ${s.dir === 1 ? '▲' : '▼'}`).join(' → ')} ×
          </button>
        )}
        <span className="fleet-summary">{rows.length} / {doc.entries.length} stations</span>
      </div>
      <div className="fleet-scroll" ref={scrollRef}>
        <table className="fleet-table">
          <thead>
            <tr>
              {FLEET_COLUMNS.map((c) => {
                const active = facets.get(c.key)?.size ?? 0;
                return (
                  <th key={c.key} scope="col" className={`fleet-col-${c.key}`} title={c.title} aria-sort={sortRank(c.key) === 0 && sorts.length ? (sorts[0].dir === 1 ? 'ascending' : 'descending') : 'none'}>
                    <span className="fleet-th">
                      <button
                        type="button"
                        className={`fleet-sort${sortRank(c.key) >= 0 ? ' active' : ''}`}
                        title="Click: sort by this column (again to flip). Shift+click: add as the next sort level."
                        onClick={(ev) => onSort(c.key, ev.shiftKey)}
                      >
                        {c.label}
                        {sortRank(c.key) >= 0 && (
                          <span className="fleet-sort-mark">
                            {sorts[sortRank(c.key)].dir === 1 ? '▲' : '▼'}
                            {sorts.length > 1 && <sup>{sortRank(c.key) + 1}</sup>}
                          </span>
                        )}
                      </button>
                      <button
                        type="button"
                        className={`fleet-filter-btn${active ? ' active' : ''}`}
                        aria-label={`Filter by ${c.label}`}
                        aria-expanded={open?.key === c.key}
                        title={active ? `${active} value(s) selected` : `Filter by ${c.label}`}
                        onClick={(ev) => {
                          const r = ev.currentTarget.getBoundingClientRect();
                          setOpen(open?.key === c.key ? null : { key: c.key, x: r.left, y: r.bottom + 4 });
                        }}
                      >
                        {active ? `▼${active}` : '▽'}
                      </button>
                    </span>
                  </th>
                );
              })}
            </tr>
          </thead>
          {/* Delegated, so the station link stays fleetColumns' business and this
              file does not have to thread a callback through every column
              renderer. Capture phase, so the click is witnessed before
              react-router navigates the table away. */}
          <tbody
            onClickCapture={(ev) => {
              if ((ev.target as HTMLElement).closest('a.fleet-name')) findRef.current?.choseStation();
            }}
          >
            {rows.map((e) => (
              <tr key={e.id} className={e.listed ? '' : 'fleet-row--unlisted'}>
                {FLEET_COLUMNS.map((c) => <td key={c.key} className={`fleet-col-${c.key}`}>{c.render(e)}</td>)}
              </tr>
            ))}
            {rows.length === 0 && (
              <tr><td colSpan={FLEET_COLUMNS.length} className="fleet-empty">No station matches — clear a filter above.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {open && openCol && (
        <div ref={popRef} className="fleet-pop" style={{ left: Math.min(open.x, window.innerWidth - 300), top: open.y }} role="dialog" aria-label={`Filter ${openCol.label}`}>
          <div className="fleet-pop-head">
            <strong>{openCol.label}</strong>
            {(facets.get(openCol.key)?.size ?? 0) > 0 && (
              <button type="button" className="fleet-chip fleet-chip--clear" onClick={() => clearFacet(openCol.key)}>clear</button>
            )}
          </div>
          <ul className="fleet-pop-list">
            {facetCounts(openCol).map(([value, n]) => {
              const on = facets.get(openCol.key)?.has(value) ?? false;
              return (
                <li key={value}>
                  <label>
                    <input type="checkbox" checked={on} onChange={() => toggleValue(openCol.key, value)} />
                    <span className="fleet-pop-value">{value}</span>
                    <span className="fleet-count">{n}</span>
                  </label>
                </li>
              );
            })}
          </ul>
        </div>
      )}
      <p className="fleet-footnote">
        Rendered from <code>registry/stations/*.json</code> + <code>registry/bridge-suites.json</code> by <code>stations-registry.py</code> (<code>fleet-table.json</code>).
        Tier is derived per <code>docs/GUEST-TIERS.md</code>; emulator and UI kind are the registry's <code>emulator</code> / <code>ui</code> fields. Hover a header or cell for the source of each value; ▽ filters a column; click a header to sort, Shift+click to add a secondary sort.
      </p>
    </div>
  );
}


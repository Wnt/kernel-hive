import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useMuseum } from '../../state/store';
import { bindingFromManifest } from '../../three/archetypeRegistry';
import type { EnrichedVM } from '../../types';
import { posterFor } from '../../data/posterIndex';
import { matchesQuery, parseQuery, stationTerms } from './stationSearch';
import { usePullToRefresh } from './usePullToRefresh';

// ============================================================================
//  GridView — the plain 2D, keyboard-navigable card grid (DEFAULT view)
//  ---------------------------------------------------------------------------
//  Lists the ANNOUNCED lineup — store.listedVms, i.e. the manifest minus
//  `showcase` posters (dropped in useManifest) and minus soft-hidden stations
//  (registry `listing`, filtered in the store), so neither kind gets a card or
//  counts toward the era/total sums below. Read `listedVms`, never `vms`: `vms`
//  still carries the hidden rows so /os/:osId can resolve them. GROUPED BY ERA.
//  Cards are
//  clean CSS placeholders — no live streams open here; only the OS the user
//  opens streams (StreamView), never the whole fleet at once. Clicking /
//  Enter / Space on a card opens that OS full-viewport.
//
//  Era sections FOLD. Only the two decades the collection is thickest in open
//  on a first visit; after that the viewer's own choices are remembered. The
//  filter (stationSearch.ts) overrides the fold entirely while it is active —
//  an era holding a match is opened whether the viewer had it shut or not, and
//  an era holding none disappears. Anything less and the filter looks broken:
//  you type `irix` and the page answers with a row of closed headers.
// ============================================================================

function yearNum(v: EnrichedVM): number {
  const y = typeof v.year === 'number' ? v.year : parseInt(String(v.year), 10);
  return Number.isFinite(y) ? y : 9999;
}

// Bucket an OS into a decade era. Prefer the curated `era` label, else derive
// from the year so nothing ever lands in an "unknown" pile.
function eraOf(v: EnrichedVM): string {
  if (v.era && /^\d{4}s$/.test(v.era)) return v.era;
  const y = yearNum(v);
  if (!Number.isFinite(y) || y === 9999) return 'Other';
  return `${Math.floor(y / 10) * 10}s`;
}

// A short evocative subtitle per era, purely decorative.
const ERA_SUBTITLE: Record<string, string> = {
  '1980s': 'The command line & the first windows',
  '1990s': 'The desktop metaphor takes over',
  '2000s': 'The web, the workstation',
  '2010s': 'From-scratch revivals',
  '2020s': 'The modern era',
};

interface EraGroup {
  era: string;
  minYear: number;
  items: EnrichedVM[];
}

// Fold state. Open by default on a FIRST visit only: the two decades this
// collection is thickest in, and the ones a visitor is looking for. Every other
// era starts shut so the page opens as a readable index rather than 61 cards.
const DEFAULT_OPEN_ERAS = new Set(['1990s', '2000s']);
const FOLD_STORAGE_KEY = 'kernelHive.gridEraOpen';

type FoldState = Record<string, boolean>;

// Storage can be absent (SSR-ish contexts), blocked (Safari private mode throws
// on ACCESS, not just on write) or hold something another version wrote. Any of
// those is a first visit, which is a perfectly good answer.
function readFoldState(): FoldState {
  try {
    const raw = window.localStorage.getItem(FOLD_STORAGE_KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return {};
    return Object.fromEntries(
      Object.entries(parsed as Record<string, unknown>)
        .filter((entry): entry is [string, boolean] => typeof entry[1] === 'boolean'),
    );
  } catch {
    return {};
  }
}

function writeFoldState(state: FoldState): void {
  try { window.localStorage.setItem(FOLD_STORAGE_KEY, JSON.stringify(state)); }
  catch { /* the fold still works for this visit; only the memory is lost */ }
}

// GridView unmounts while an OS stream route is open. Keep its scroll offset in
// UI memory so returning to the grid restores the same spot, while a real page
// load (including a direct /os/:osId deep-link) still starts at the top.
let savedScrollTop: number | null = null;

export default function GridView() {
  const vms = useMuseum((s) => s.listedVms);
  const gridRef = useRef<HTMLDivElement>(null);
  // Preserve query parameters across navigation into a station.
  const { search } = useLocation();

  const streamable = vms;

  // Touch pull-to-refresh. A standalone/installed PWA has no browser chrome and
  // so no native pull-to-refresh; the grid supplies its own on its scroll box. A
  // full reload re-fetches the rendered manifest, so a newly-listed (or
  // just-recaptured) station shows up. `vms.length > 0` gates it because the
  // loading placeholder below is a different, ref-less element.
  const pull = usePullToRefresh(
    gridRef,
    useCallback(() => { window.location.reload(); }, []),
    vms.length > 0,
  );

  // Group by era, sort items by year within a group, and groups chronologically.
  const groups = useMemo<EraGroup[]>(() => {
    const by = new Map<string, EnrichedVM[]>();
    for (const v of streamable) {
      const era = eraOf(v);
      const arr = by.get(era) ?? [];
      arr.push(v);
      by.set(era, arr);
    }
    const out: EraGroup[] = [];
    for (const [era, items] of by) {
      items.sort((a, b) => yearNum(a) - yearNum(b) || a.displayName.localeCompare(b.displayName));
      out.push({ era, minYear: Math.min(...items.map(yearNum)), items });
    }
    out.sort((a, b) => a.minYear - b.minYear);
    return out;
  }, [streamable]);

  // ---- filter ----------------------------------------------------------
  const [query, setQuery] = useState('');
  const filterRef = useRef<HTMLInputElement>(null);

  // One term set per station, rebuilt only when the lineup itself changes —
  // never per keystroke.
  const termsById = useMemo(
    () => new Map(streamable.map((v) => [v.id, stationTerms(v)])),
    [streamable],
  );
  const parsed = useMemo(() => parseQuery(query), [query]);
  const filtering = parsed.length > 0;

  // Groups as the page will actually show them: filtered, and emptied eras
  // dropped so a search never renders a header with nothing under it.
  const shownGroups = useMemo<EraGroup[]>(() => {
    if (!filtering) return groups;
    return groups
      .map((g) => ({ ...g, items: g.items.filter((v) => matchesQuery(termsById.get(v.id)!, parsed)) }))
      .filter((g) => g.items.length > 0);
  }, [groups, filtering, parsed, termsById]);

  const matchCount = shownGroups.reduce((n, g) => n + g.items.length, 0);

  // ---- fold ------------------------------------------------------------
  const [foldState, setFoldState] = useState<FoldState>(readFoldState);

  // A filter run OVERRIDES the fold rather than replacing it: every era with a
  // match is open while typing, and clearing the box hands the viewer their own
  // expand/collapse choices back untouched.
  const isOpen = useCallback(
    (era: string) => (filtering ? true : foldState[era] ?? DEFAULT_OPEN_ERAS.has(era)),
    [filtering, foldState],
  );

  const toggleEra = useCallback((era: string) => {
    setFoldState((prev) => {
      const next = { ...prev, [era]: !(prev[era] ?? DEFAULT_OPEN_ERAS.has(era)) };
      writeFoldState(next);
      return next;
    });
  }, []);

  // Flat DOM order of card refs for roving arrow-key navigation. Cards are now
  // <Link> anchors, so the ref array is typed for HTMLAnchorElement. Only cards
  // that are actually rendered (open era, matching the filter) get an index.
  const cardRefs = useRef<(HTMLAnchorElement | null)[]>([]);
  const flatCount = shownGroups.reduce((n, g) => (isOpen(g.era) ? n + g.items.length : n), 0);

  // Save from the still-mounted scroll container before the route removes it.
  useLayoutEffect(() => () => {
    if (gridRef.current) savedScrollTop = gridRef.current.scrollTop;
  }, []);

  // Restore only after the catalog has rendered enough layout to accept the
  // previous offset. useLayoutEffect applies it before the returning frame.
  useLayoutEffect(() => {
    if (vms.length > 0 && savedScrollTop !== null && gridRef.current) {
      gridRef.current.scrollTop = savedScrollTop;
    }
  }, [vms.length]);

  // Autofocus the filter so the operator can type the moment the page settles —
  // but only where a keyboard is already present. On a touch device focusing an
  // input pops the on-screen keyboard over the collection you came to look at.
  // GridView owns the '/' route alone, so nothing else is competing for focus.
  useEffect(() => {
    if (window.matchMedia?.('(pointer: fine)').matches) filterRef.current?.focus();
  }, []);

  // Escape empties the filter from anywhere on the grid. It is free here: the
  // Escape the rest of the app protects belongs to an opened station's
  // StreamView, which is a different route and unmounts this one.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => { if (e.key === 'Escape') setQuery(''); };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const focusCard = (i: number) => {
    if (i < 0 || i >= flatCount) return;
    cardRefs.current[i]?.focus();
  };

  const onGridKeyDown = (e: React.KeyboardEvent, idx: number) => {
    switch (e.key) {
      case 'ArrowRight':
      case 'ArrowDown':
        e.preventDefault();
        focusCard(idx + 1);
        break;
      case 'ArrowLeft':
      case 'ArrowUp':
        e.preventDefault();
        focusCard(idx - 1);
        break;
      case 'Home':
        e.preventDefault();
        focusCard(0);
        break;
      case 'End':
        e.preventDefault();
        focusCard(flatCount - 1);
        break;
      case ' ':
      case 'Spacebar':               // legacy key name
        // Native <a href> activates on Enter but NOT Space; the old <button>
        // activated on both. Preserve Space activation and stop page scroll.
        e.preventDefault();
        cardRefs.current[idx]?.click();
        break;
      default:
        break;
    }
  };

  if (vms.length === 0) {
    // The catalog is static and non-empty, so an empty list only ever means the
    // one-off mount effect hasn't populated the store yet.
    return (
      <div className="grid-view">
        <div className="grid-empty">Loading the collection…</div>
      </div>
    );
  }

  // Running index across all groups keeps arrow navigation continuous.
  let running = -1;

  return (
    <div ref={gridRef} className="grid-view" role="region" aria-label="Operating system collection">
      {/* Pull-to-refresh affordance — slides out from under the app bar as the
          list is pulled down, spins once a refresh is committed. Decorative:
          the reload it triggers is the real feedback. */}
      <div
        className={`grid-refresh${pull.armed ? ' is-armed' : ''}`}
        style={{
          transform: `translate(-50%, ${Math.round(pull.distance)}px)`,
          opacity: pull.refreshing || pull.distance > 2 ? 1 : 0,
        }}
        aria-hidden="true"
      >
        <span
          className={`grid-refresh-icon${pull.refreshing ? ' is-refreshing' : ''}`}
          style={pull.refreshing ? undefined : { transform: `rotate(${Math.min(1, pull.distance / 64) * 270}deg)` }}
        >
          ↻
        </span>
      </div>
      <div className="grid-view-inner">
        <div className="grid-filter">
          <input
            ref={filterRef}
            className="grid-filter-input"
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Filter — win2k, windows 3, unix, irix, dos…"
            aria-label="Filter the collection by name, era or family"
            aria-describedby="grid-filter-status"
            autoComplete="off"
            spellCheck={false}
          />
          {filtering && (
            <button type="button" className="grid-filter-clear" onClick={() => setQuery('')}>
              Clear
            </button>
          )}
          <span id="grid-filter-status" className="grid-filter-status" role="status">
            {filtering ? `${matchCount} of ${streamable.length}` : `${streamable.length} systems · press /`}
          </span>
        </div>

        {filtering && matchCount === 0 && (
          <div className="grid-empty grid-empty--nomatch">
            Nothing in the collection matches “{query.trim()}”.
          </div>
        )}

        {shownGroups.map((g) => {
          const open = isOpen(g.era);
          const panelId = `era-panel-${g.era}`;
          return (
            <section className="era-section" key={g.era} aria-label={`Era ${g.era}`}>
              <h2 className="era-header">
                <button
                  type="button"
                  className="era-toggle"
                  aria-expanded={open}
                  aria-controls={panelId}
                  onClick={() => toggleEra(g.era)}
                >
                  <span className="era-caret" aria-hidden="true">{open ? '▾' : '▸'}</span>
                  <span className="era-name">{g.era}</span>
                  <span className="era-sub">{ERA_SUBTITLE[g.era] ?? ''}</span>
                  {/* Kept on a collapsed header too: a shut era must never read
                      as an empty one. */}
                  <span className="era-count">{g.items.length}</span>
                </button>
              </h2>

              <div className="card-grid" id={panelId} role="list" hidden={!open}>
                {open && g.items.map((v) => {
                running += 1;
                const idx = running;
                const b = bindingFromManifest(v);
                const accent = v.accent;
                const hero = posterFor(v.id)?.hero;
                return (
                  <Link
                    key={v.id}
                    role="listitem"
                    ref={(el) => { cardRefs.current[idx] = el; }}
                    to={{ pathname: `/os/${v.id}`, search }}
                    className="os-card"
                    style={{ ['--accent' as string]: accent }}
                    onKeyDown={(e) => onGridKeyDown(e, idx)}
                    aria-label={`${v.displayName}, ${v.year}. ${v.blurb ?? ''} Open live.`}
                  >
                    <span className="os-poster" aria-hidden="true">
                      <span className="os-poster-screen">
                        {hero ? (
                          <img
                            className="os-poster-shot"
                            src={hero}
                            alt=""
                            loading="lazy"
                            decoding="async"
                          />
                        ) : (
                          <>
                            <span className="os-poster-name">{v.displayName}</span>
                            <span className="os-poster-year">{v.year}</span>
                          </>
                        )}
                      </span>
                      {b.bootVideo && (
                        <span className="os-badge os-badge--bootvid" title="Boot capture available">▶ Boot</span>
                      )}
                      {b.hardwareInput && (
                        <span className="os-badge os-badge--hwinput" title="Native guest hardware input enabled">HW input</span>
                      )}
                      {/* A graphical exhibit whose pointer is relative only. Not a
                          fault — the machine never had an absolute pointer, or we
                          have not built one for it yet — so it warns rather than
                          errors, and it sits below the HW-input slot because a station
                          can never have both. */}
                      {b.relativePointerOnly && (
                        <span
                          className="os-badge os-badge--relptr"
                          title="Relative pointer only: the cursor moves by deltas, so it cannot track your finger 1:1"
                        >
                          Rel. pointer
                        </span>
                      )}
                    </span>
                    <span className="os-card-body">
                      <span className="os-card-name">{v.displayName}</span>
                      <span className="os-card-meta">{v.lineage}</span>
                      <span className="os-card-chips">
                        <span className="os-chip">{v.year}</span>
                        <span className="os-chip">{v.arch}</span>
                      </span>
                    </span>
                    </Link>
                  );
                })}
              </div>
            </section>
          );
        })}
        <footer className="grid-foot">
          {filtering
            ? `${matchCount} matching ${matchCount === 1 ? 'system' : 'systems'} in ${shownGroups.length} ${shownGroups.length === 1 ? 'era' : 'eras'}`
            : `${groups.length} eras · ${streamable.length} operating systems`}
          {' · '}
          <a
            className="grid-foot-link"
            href="https://github.com/Wnt/kernel-hive"
            target="_blank"
            rel="noopener noreferrer"
          >
            Source on GitHub
          </a>
        </footer>
      </div>
    </div>
  );
}

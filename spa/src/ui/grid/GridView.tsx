import { useLayoutEffect, useMemo, useRef } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { useMuseum } from '../../state/store';
import { bindingFromManifest } from '../../three/archetypeRegistry';
import type { EnrichedVM } from '../../types';
import { posterFor } from '../../data/posterIndex';

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

  // Flat DOM order of card refs for roving arrow-key navigation. Cards are now
  // <Link> anchors, so the ref array is typed for HTMLAnchorElement.
  const cardRefs = useRef<(HTMLAnchorElement | null)[]>([]);
  const flatCount = streamable.length;

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
      <div className="grid-view-inner">
        {groups.map((g) => (
          <section className="era-section" key={g.era} aria-label={`Era ${g.era}`}>
            <header className="era-header">
              <h2>{g.era}</h2>
              <span className="era-sub">{ERA_SUBTITLE[g.era] ?? ''}</span>
              <span className="era-count">{g.items.length}</span>
            </header>

            <div className="card-grid" role="list">
              {g.items.map((v) => {
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
        ))}
        <footer className="grid-foot">
          {groups.length} eras · {streamable.length} operating systems
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

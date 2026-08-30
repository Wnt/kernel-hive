import { Link } from 'react-router-dom';
import { bindingFromManifest } from '../../three/archetypeRegistry';
import { posterFor } from '../../data/posterIndex';
import type { EnrichedVM } from '../../types';
import type { WalkinPool } from '../../data/walkinTypes';
import { cardTarget } from './lineup';

// One card in the grid, for either visitor class.
//
// WHERE A CARD GOES, per visitor class (lineup.ts `cardTarget`):
//   invited / operator  → the station's own console, /os/<id>
//   walk-in, playable   → their private clone, /walkin/play/<os>
//   walk-in, on display → the placard, opened in place — never a stream link
//                         the gate would refuse, and never a dead button.
//
// The placard case is still an <a>, not a <button>, so the grid's roving
// arrow-key navigation — which indexes HTMLAnchorElement refs — keeps working
// across a mixed grid without learning about a second element type.

/** "2 of 3 free", with the free slots also drawn as pips. The walk-in landing
 *  page draws the same meter: one lineup, one vocabulary. */
function PoolMeter({ pool }: { pool: WalkinPool | undefined }) {
  if (!pool) return <span className="walkin-pool">checking…</span>;
  const pips = Array.from({ length: pool.size }, (_, index) => index < pool.free);
  return (
    <span className={`walkin-pool${pool.free === 0 ? ' walkin-pool--none' : ''}`}>
      <span className="walkin-pips" aria-hidden="true">
        {pips.map((free, index) => (
          <span key={index} className={`walkin-pip${free ? ' walkin-pip--free' : ''}`} />
        ))}
      </span>
      {pool.free} of {pool.size} free
    </span>
  );
}

function CardBody({ vm }: { vm: EnrichedVM }) {
  const b = bindingFromManifest(vm);
  const hero = posterFor(vm.id)?.hero;
  return (
    <>
      <span className="os-poster" aria-hidden="true">
        <span className="os-poster-screen">
          {hero ? (
            <img className="os-poster-shot" src={hero} alt="" loading="lazy" decoding="async" />
          ) : (
            <>
              <span className="os-poster-name">{vm.displayName}</span>
              <span className="os-poster-year">{vm.year}</span>
            </>
          )}
        </span>
        {b.bootVideo && (
          <span className="os-badge os-badge--bootvid" title="Boot capture available">▶ Boot</span>
        )}
        {b.hardwareInput && (
          <span className="os-badge os-badge--hwinput" title="Native guest hardware input enabled">HW input</span>
        )}
        {/* A graphical exhibit whose pointer is relative only. Not a fault — the
            machine never had an absolute pointer, or we have not built one for
            it yet — so it warns rather than errors, and it sits below the
            HW-input slot because a station can never have both. */}
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
        <span className="os-card-name">{vm.displayName}</span>
        <span className="os-card-meta">{vm.lineage}</span>
        <span className="os-card-chips">
          <span className="os-chip">{vm.year}</span>
          <span className="os-chip">{vm.arch}</span>
        </span>
      </span>
    </>
  );
}

export interface OsCardProps {
  vm: EnrichedVM;
  /** Whether this tab belongs to a walk-in account. */
  walkin: boolean;
  /** Query string carried across navigation into a station. */
  search: string;
  /** Live pool status for a walk-in's playable stations. */
  pool: WalkinPool | undefined;
  cardRef: (el: HTMLAnchorElement | null) => void;
  onKeyDown: (e: React.KeyboardEvent) => void;
  onOpenPlacard?: (osId: string) => void;
}

export function OsCard({ vm, walkin, search, pool, cardRef, onKeyDown, onOpenPlacard }: OsCardProps) {
  const target = cardTarget(vm.id, walkin);
  const placard = target.kind === 'placard';
  const shared = {
    role: 'listitem' as const,
    ref: cardRef,
    className: `os-card${placard ? ' os-card--placard' : ''}`,
    style: { ['--accent' as string]: vm.accent },
    onKeyDown,
    'aria-label': `${vm.displayName}, ${vm.year}. ${vm.blurb ?? ''} ${
      placard ? 'On display — read the placard.' : 'Open live.'
    }`,
  };

  if (placard) {
    return (
      // The href is a real, reachable page rather than "#": middle-click and
      // "open in new tab" then land somewhere true, while a plain click keeps
      // the placard in place without losing the visitor's scroll position.
      // It carries the bundle's BASE_URL by hand because this is a raw <a> —
      // react-router applies the basename to <Link>, not to an href, and
      // without it a staged preview's cards point at the PRODUCTION site.
      <a
        {...shared}
        href={`${import.meta.env.BASE_URL}walkin/exhibits#${vm.id}`}
        onClick={(e) => { e.preventDefault(); onOpenPlacard?.(vm.id); }}
      >
        <CardBody vm={vm} />
        <span className="os-card-foot">
          <span className="walkin-tag">On display — read the placard</span>
        </span>
      </a>
    );
  }

  return (
    <Link {...shared} to={{ pathname: target.to, search }}>
      <CardBody vm={vm} />
      {target.kind === 'clone' && (
        <span className="os-card-foot">
          <span className="walkin-tag walkin-tag--playable">
            {pool?.free === 0 ? 'Join the queue' : 'Play it'}
          </span>
          <PoolMeter pool={pool} />
        </span>
      )}
    </Link>
  );
}

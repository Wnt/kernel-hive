import { poolFor } from '../walkin/usePools';
import type { WalkinPool, WalkinState } from '../data/walkinTypes';
import { posterFor } from '../data/posterIndex';
import { HERO_STATIONS, stationCopy } from './stations';
import type { HeroPhase } from './heroSession';

// ============================================================================
//  landing/StationSwitcher — three machines, one press apart.
//  ---------------------------------------------------------------------------
//  The switcher has to be as obvious as the machine itself, because it is the
//  answer to the only question a stranger asks after the first ten seconds:
//  "is this the only one?". So it is not a select and not a menu — it is the
//  three machines, face up, with their live pool state on them.
//
//  IT IS A SWITCH, NOT A NAVIGATION. Pressing one releases the cell on screen
//  and claims the next (heroSession.switchPlan), which on a warm, paused pool
//  is a resume rather than a boot. The pressed chip goes active IMMEDIATELY,
//  from the claim's own `want` rather than from a second piece of state: the
//  page is already tracking what it asked for, and a switcher that waits for
//  the broker before it moves reads as a switcher that did not register the
//  press.
//
//  THE COUNTS ARE LIVE, and they are why a full pool does not read as a broken
//  button: `2 of 3 free` says what pressing will get you, and `all busy` says,
//  before the press, that it will not.
// ============================================================================

function PoolPips({ pool }: { pool: WalkinPool | undefined }) {
  if (!pool) return <span className="landing-chip__pool">checking…</span>;
  return (
    <span className={`landing-chip__pool${pool.free === 0 ? ' landing-chip__pool--none' : ''}`}>
      <span className="landing-chip__pips" aria-hidden="true">
        {Array.from({ length: pool.size }, (_, index) => (
          <span key={index} className={`landing-pip${index < pool.free ? ' landing-pip--free' : ''}`} />
        ))}
      </span>
      {pool.free === 0 ? 'all busy' : `${pool.free} of ${pool.size} free`}
    </span>
  );
}

/** The station this switcher should draw as selected: what is on screen, or —
 *  while a claim is in flight — what was just asked for. */
function selectedStation(phase: HeroPhase): string | null {
  if (phase.kind === 'live') return phase.station;
  if (phase.kind === 'claiming') return phase.want;
  if (phase.kind === 'queued') return phase.want;
  return null;
}

export function StationSwitcher({
  phase,
  state,
  disabled,
  onPick,
}: {
  phase: HeroPhase;
  state: WalkinState | null;
  disabled: boolean;
  onPick: (os: string) => void;
}) {
  const selected = selectedStation(phase);
  return (
    <div className="landing-switch" role="tablist" aria-label="Which machine to drive">
      {HERO_STATIONS.map((os) => {
        const copy = stationCopy(os);
        const pool = poolFor(state, os);
        const active = selected === os;
        const shot = posterFor(os)?.hero;
        return (
          <button
            key={os}
            type="button"
            role="tab"
            aria-selected={active}
            className={`landing-chip${active ? ' landing-chip--active' : ''}`}
            style={{ ['--station-accent' as string]: copy.accent }}
            disabled={disabled && !active}
            onClick={() => onPick(os)}
          >
            {shot && <img className="landing-chip__shot" src={shot} alt="" loading="lazy" />}
            <span className="landing-chip__text">
              <span className="landing-chip__name">{copy.name}</span>
              <span className="landing-chip__meta">{copy.meta}</span>
              <PoolPips pool={pool} />
            </span>
            <span className="landing-chip__state" aria-hidden="true">
              {active ? 'on screen' : 'drive it'}
            </span>
          </button>
        );
      })}
    </div>
  );
}

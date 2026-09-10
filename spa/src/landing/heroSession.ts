import type { WalkinClaim, WalkinQueued } from '../data/walkinTypes';
import { isClosedError, isQueued, WalkinApiError } from '../walkin/api';
import type { ReleaseReason } from './heroPolicy';

// ============================================================================
//  landing/heroSession — the hero machine's claim/switch state machine, as
//  pure data.
//  ---------------------------------------------------------------------------
//  The landing page's whole promise is "a real machine, already running, that
//  you can drive". Everything expensive about keeping that promise is a
//  SEQUENCE — claim, hold, release, claim again — and a sequence is exactly
//  what a React component is worst at holding honestly: an effect that fires
//  twice under StrictMode, a switch whose release lands after its own claim, a
//  reload that re-claims a cell the visitor still holds. Vitest here runs under
//  plain Node with no jsdom (vitest.config.ts), so a component is untestable by
//  construction and the sequencing would have no gate at all.
//
//  So the sequencing lives here, as functions over values, with heroSession
//  .test.ts beside it; useHeroSession.ts is the thin React glue that calls
//  them. The rule for this file: no fetch, no timers, no DOM.
// ============================================================================

/** The clone identity form is frozen in CONTRACT-LEDGER §5.1: `walkin-<os>-<n>`. */
export function stationOfClone(clone: string): string {
  return clone.replace(/^walkin-/, '').replace(/-\d+$/, '');
}

export type HeroPhase =
  /** Nothing claimed and nothing being claimed — the poster is on screen. */
  | { kind: 'idle' }
  /** A claim is in flight. `want` is null for "any machine, server's choice". */
  | { kind: 'claiming'; want: string | null }
  /** The visitor holds a cell and the stream is mounted. */
  | { kind: 'live'; station: string; claim: WalkinClaim }
  /** Every cell of the asked-for station was taken at that moment. */
  | { kind: 'queued'; want: string | null; position: number }
  /** The page gave a cell back on its own — heroPolicy.releaseDue says why. */
  | { kind: 'stopped'; station: string | null; reason: StopReason }
  /** The plane said no. `code` is the broker's own, `message` its wording. */
  | { kind: 'refused'; code: HeroRefusal; message: string };

/** The refusals this page renders differently. Everything else is `error`. */
type HeroRefusal = 'closed' | 'budget' | 'error';

/** Why the PAGE stopped, as opposed to why the broker refused. The two the
 *  watchdog can decide (heroPolicy.releaseDue), plus the visitor closing the
 *  machine themselves. A stopped machine ALWAYS says which — the same rule the
 *  walk-in plane already keeps for a session that ends (walkin/reasons.ts): a
 *  visitor who is never told why is a visitor who assumes it broke. */
export type StopReason = ReleaseReason | 'left';

/**
 * Which station did the broker actually hand over?
 *
 * The landing page claims with NO `os` so the server picks at random
 * (LANDING-REDESIGN-CONTRACT, "POST /walkin/claim"), which means the page
 * cannot know what it is showing until the answer comes back. `station` in the
 * response is the contract's answer and is preferred; the clone id is the
 * fallback, because it carries the station in its own frozen shape and is
 * therefore never absent. `want` is last: on the random path it is null, and on
 * a switch it is what we ASKED for, which is a wish and not a fact.
 */
export function stationOfClaim(claim: WalkinClaim, want: string | null): string {
  if (typeof claim.station === 'string' && claim.station) return claim.station;
  const fromClone = stationOfClone(claim.clone);
  if (fromClone && fromClone !== claim.clone) return fromClone;
  return want ?? fromClone;
}

/** What the hero becomes after the broker answered a claim. */
export function phaseAfterHeroClaim(result: WalkinClaim | WalkinQueued, want: string | null): HeroPhase {
  if (isQueued(result)) return { kind: 'queued', want, position: result.position };
  return { kind: 'live', station: stationOfClaim(result, want), claim: result };
}

/** The exhaustion code from LANDING-REDESIGN-CONTRACT ("The anonymous budget"). */
function isBudgetError(error: unknown): boolean {
  if (!(error instanceof WalkinApiError)) return false;
  // The contract writes it `WALKIN_ANON_BUDGET`; the ledger's own body codes are
  // lower-case with underscores (`walkin_closed`). Match either — which half of
  // the wire won the casing argument is not a thing this page should depend on.
  return error.code.toLowerCase().includes('anon_budget');
}

/** What the hero becomes after the claim THREW. */
export function phaseAfterHeroClaimError(error: unknown): HeroPhase {
  if (isBudgetError(error)) {
    return { kind: 'refused', code: 'budget', message: 'Your minute is up.' };
  }
  if (isClosedError(error)) {
    return { kind: 'refused', code: 'closed', message: 'Walk-in access is currently closed.' };
  }
  return {
    kind: 'refused',
    code: 'error',
    message: error instanceof Error ? error.message : 'no machine could be claimed',
  };
}

/** The clone this phase is holding, if any — what a release must be given. */
export function heldClone(phase: HeroPhase): string | null {
  return phase.kind === 'live' ? phase.claim.clone : null;
}

/** The station on screen, if any. Drives the status strip and the switcher. */
export function liveStation(phase: HeroPhase): string | null {
  return phase.kind === 'live' ? phase.station : null;
}

/** True while the page is waiting on the broker — the switcher disables itself. */
export function isBusy(phase: HeroPhase): boolean {
  return phase.kind === 'claiming';
}

export type SwitchStep =
  | { op: 'release'; clone: string }
  | { op: 'claim'; os: string | null };

/**
 * The ordered steps that take the hero from where it is to `target`.
 *
 * There is no switch ENDPOINT — the contract is explicit that a switch is
 * `release` then `claim`, in that order, and that the anonymous budget lives on
 * the visitor so it survives the round trip. Three rules, and each one is a bug
 * this page would otherwise have:
 *
 *   * Switching to the station already on screen returns NO steps. The obvious
 *     implementation releases and re-claims, which on the anonymous plane spends
 *     part of a 60-second budget to arrive back where you already were, and on
 *     any plane throws away the visitor's work in that guest.
 *   * A release always precedes its claim. One clone per account (ledger §7):
 *     claiming first means the broker retires the cell you are watching, and the
 *     frame the visitor was driving goes away before its replacement exists.
 *   * Holding nothing means there is nothing to release, and the plan is one
 *     step. Sending a release for a clone we do not hold is a refused call, and
 *     a refused call in a switch reads as a broken switcher.
 */
export function switchPlan(phase: HeroPhase, target: string | null): SwitchStep[] {
  const held = heldClone(phase);
  if (held === null) return [{ op: 'claim', os: target }];
  if (target !== null && liveStation(phase) === target) return [];
  return [{ op: 'release', clone: held }, { op: 'claim', os: target }];
}

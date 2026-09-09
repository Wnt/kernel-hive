import type { WalkinClaim, WalkinQueued } from '../data/walkinTypes';
import { isClosedError, isQueued } from './api';
import type { WalkinReason } from './reasons';

// The play view's state machine, as pure functions — what a claim's outcome
// turns the page into, and what the page owes the pool when a session ends.
//
// Why this is a module and not four lines inside WalkinPlay: a browser reload
// used to strand the visitor on "That session ended" with a retry that could
// never succeed. Nothing released the clone on a reload (React's unmount
// cleanup does not run when the document is torn down), so the visitor still
// held it, and the reloaded page's claim was refused with "you already have
// walkin-win311-1 — release it first". The broker now hands that clone back as
// a RESUMED claim (scripts/serve/walkin/broker.py `_claim`), and this module is
// where the page's side of that contract is stated and tested:
//
//   * a claim that comes back `resumed` is the visitor's own live cell — same
//     clone, the clock where it was — and is played, not announced;
//   * a session the page ends on its own clock (TTL, idle) RELEASES the clone
//     before offering "Play again", so the retry claims a fresh one instead
//     of re-attaching to a machine whose time is up;
//   * every ended state offers a way back in. Closed access included: the
//     button re-asks the broker, which is the only party that knows whether
//     the door has reopened.

export type Phase =
  | { kind: 'claiming' }
  | { kind: 'queued'; position: number }
  | { kind: 'playing'; claim: WalkinClaim; resumed: boolean }
  | { kind: 'ended'; reason: WalkinReason | null; message?: string };

/** What the page becomes after the broker answered a claim (or reset). */
export function phaseAfterClaim(result: WalkinClaim | WalkinQueued): Phase {
  if (isQueued(result)) return { kind: 'queued', position: result.position };
  return { kind: 'playing', claim: result, resumed: result.resumed === true };
}

/** What the page becomes after the claim THREW. */
export function phaseAfterClaimError(reason: unknown): Phase {
  if (isClosedError(reason)) return { kind: 'ended', reason: 'WALKIN_CLOSED' };
  return {
    kind: 'ended',
    reason: null,
    message: reason instanceof Error ? reason.message : 'the machine could not be claimed',
  };
}

/**
 * When the page ends the session itself, is the clone finished with?
 *
 * TTL and idle are ends the broker's reaper is about to enforce anyway; handing
 * the clone back now means "Play again" gets a fresh machine, and the pool
 * gets it back seconds earlier. Closed access is NOT released here — the
 * broker's teardown owns that (it revokes tickets first, then kills), and a
 * client-side release racing it would only add a refused call.
 */
export function releasesCloneOnEnd(reason: WalkinReason | null): boolean {
  return reason === 'WALKIN_TTL' || reason === 'WALKIN_IDLE';
}

/** The label of the way back in, from any ended state. Never absent. */
export function playAgainLabel(reason: WalkinReason | null): string {
  switch (reason) {
    case 'WALKIN_CLOSED':
      return 'Check again';
    case 'WALKIN_TTL':
    case 'WALKIN_IDLE':
      return 'Play again';
    default:
      return 'Take another machine';
  }
}

/**
 * Should a page that was just shown again re-run its claim?
 *
 * `pageshow` with `persisted` is the back/forward cache: the browser restored
 * the old document — with the old React tree, whose clone was released when
 * the visitor left. That tree must claim afresh (it will be handed its own
 * cell back if the release never reached the broker). A non-persisted
 * pageshow is the normal first paint, already claiming.
 */
export function reclaimsOnPageShow(persisted: boolean): boolean {
  return persisted;
}

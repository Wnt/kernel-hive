import type { WalkinAccess } from '../data/walkinTypes';
import { parseWalkinReason, type WalkinReason } from './reasons';

// Why did THIS session end? — the resolver behind the play surface's ending
// card.
//
// The broker is the authority: when it hands the client a §3.1 code, that code
// wins, whatever this UI thinks it observed. But a dropped session must never
// leave the visitor staring at "connection lost" when the honest answer was on
// the clock, so when no code arrives the resolver falls back to the facts the
// client can see for itself — the access level it last polled, its own TTL
// countdown, and how long since the visitor last touched anything. Those are
// observations, not policy: the numbers come from the claim and from
// /walkin/state, and the resolver never invents a session end that the broker
// has not already caused.

export interface WalkinEndFacts {
  /** Anything the broker said about the drop — close reason, error body, field. */
  brokerCode?: unknown;
  /** Access level from the most recent /walkin/state poll. */
  access?: WalkinAccess;
  /** Is this visitor's role still allowed to hold a clone at that access level? */
  allowed?: boolean;
  /** Seconds left on the claim's TTL when the session ended (may go negative). */
  secondsLeft?: number;
  /** Seconds since the last pointer/key event inside the stage. */
  idleSeconds?: number;
  /** The broker's idle window; the ledger's default is 180s. */
  idleWindowSeconds?: number;
}

/**
 * The reason to render, or null when nothing walk-in-specific explains the
 * drop (⇒ the caller shows the generic stream copy, which is then the truth).
 */
export function resolveEndReason(facts: WalkinEndFacts): WalkinReason | null {
  const fromBroker = parseWalkinReason(facts.brokerCode);
  if (fromBroker) return fromBroker;
  if (facts.access !== undefined && facts.allowed === false) return 'WALKIN_CLOSED';
  if (facts.secondsLeft !== undefined && facts.secondsLeft <= 0) return 'WALKIN_TTL';
  const window = facts.idleWindowSeconds ?? 180;
  if (facts.idleSeconds !== undefined && facts.idleSeconds >= window) return 'WALKIN_IDLE';
  return null;
}

/** May a visitor with this role hold a walk-in clone at this access level? */
export function accessAllows(access: WalkinAccess, role: string): boolean {
  if (access === 'open') return true;
  // Invited keeps the door open for the gallery's existing accounts and closes
  // it to self-registered walk-ins; Closed shuts it for everyone (§3).
  if (access === 'invited') return role === 'viewer' || role === 'admin';
  return false;
}

/** mm:ss for the session clock. Never renders a negative clock. */
export function clockText(secondsLeft: number): string {
  const total = Math.max(0, Math.floor(secondsLeft));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, '0')}`;
}

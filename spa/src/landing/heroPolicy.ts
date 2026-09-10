import type { WalkinAccess, WalkinAnonBudget } from '../data/walkinTypes';
import { accessAllows } from '../walkin/sessionEnd';

// ============================================================================
//  landing/heroPolicy — when the hero MAY claim a machine, and when it must
//  give one back.
//  ---------------------------------------------------------------------------
//  The landing page auto-claims. That is the feature: a stranger arrives and a
//  real machine is already running for them, with nothing to press first. It is
//  also the most expensive sentence in this repo, because there are eight cells
//  across three pools and every load of `/` takes one. A crawler, a preloaded
//  link, a tab opened into the background and forgotten, a monitoring check —
//  each of those is a visitor as far as an auto-claim is concerned, and none of
//  them will ever look at the frame they are paying for.
//
//  So the policy is: claim eagerly, and hand it back at the first sign nobody
//  is there. Both halves are pure functions here, tested next door, because
//  both are timing rules — the class of rule that is impossible to eyeball and
//  trivial to get backwards.
// ============================================================================

/** How long a freshly claimed cell may go untouched before it goes back. */
export const FIRST_INPUT_GRACE_MS = 15_000;

/**
 * How long a cell the visitor HAS driven may sit in a hidden tab.
 *
 * Longer than the first-input grace on purpose: someone who has already typed
 * at the guest and then switches tabs for twenty seconds is a visitor, not a
 * crawler, and taking their machine away mid-thought is a worse failure than
 * holding a cell for half a minute. Someone who never touched it gets no such
 * benefit of the doubt — see `hidden` in releaseDue().
 */
export const HIDDEN_GRACE_MS = 30_000;

export interface HoldFacts {
  now: number;
  /** When the broker handed this cell over. */
  claimedAt: number;
  /** The last TRUSTED pointer/key/touch on the stage; null ⇒ never driven. */
  lastInputAt: number | null;
  /** When the tab went hidden; null ⇒ visible. */
  hiddenSince: number | null;
}

/** Why the hero is handing its cell back, or null to keep holding. */
export type ReleaseReason = 'never-driven' | 'hidden';

/**
 * Should this held cell go back to the pool right now?
 *
 * Order matters, and it is the order of how sure we are that nobody is there:
 *
 *   1. Never driven AND the tab is hidden — the strongest signal there is. A
 *      page that was claimed and immediately backgrounded was opened by
 *      software or by a person who has already moved on. No grace at all.
 *   2. Never driven, visible, past the grace — the crawler case, and the
 *      "opened in a tab to read later" case. 15 seconds is long enough for a
 *      real person to find the machine with their mouse and short enough that
 *      eight cells are not held by nobody.
 *   3. Driven, but hidden past the longer grace — a real visitor who left.
 *
 *  A visible, driven cell is never released here: from that point it is the
 *  broker's TTL and idle windows that own the session (walkin/sessionEnd.ts),
 *  and a second, shorter client-side rule would only end sessions the server
 *  believes are alive.
 */
export function releaseDue(f: HoldFacts): ReleaseReason | null {
  const driven = f.lastInputAt !== null;
  const hidden = f.hiddenSince !== null;
  if (!driven && hidden) return 'hidden';
  if (!driven && f.now - f.claimedAt >= FIRST_INPUT_GRACE_MS) return 'never-driven';
  if (driven && hidden && f.now - (f.hiddenSince as number) >= HIDDEN_GRACE_MS) return 'hidden';
  return null;
}

/** Seconds left before an undriven cell is handed back — the caption's number. */
export function graceSecondsLeft(f: Pick<HoldFacts, 'now' | 'claimedAt'>): number {
  return Math.max(0, Math.ceil((FIRST_INPUT_GRACE_MS - (f.now - f.claimedAt)) / 1000));
}

// ---------------------------------------------------------------------------
//  Capability — can this browser play a stream at all?
// ---------------------------------------------------------------------------

export interface HeroCaps {
  /** WebTransport, the primary path's transport. */
  wt: boolean;
  /** WebCodecs' VideoDecoder, the primary path's decoder. */
  vd: boolean;
  /** RTCPeerConnection — the WebRTC fallback needs nothing else. */
  rtc: boolean;
  /** A secure context; neither transport exists without one. */
  secure: boolean;
}

/**
 * Can this browser be handed a live machine?
 *
 * Deliberately WIDER than `selectClientTransport` (three/streamTransportSelect
 * .ts), and that is the point of asking here as well: that module picks WHICH
 * of the two paths a capable browser takes, and its own header records the
 * lesson that a browser missing one API is not a browser that cannot play. A
 * Safari with no WebTransport, and a Firefox-Android with no VideoDecoder, both
 * play perfectly well over the WebRTC fallback. So the only browser that gets
 * the poster instead of a machine is one with neither path — and the poster is
 * then the honest answer, not a degraded one.
 */
export function heroPlayable(caps: HeroCaps): boolean {
  if (!caps.secure) return false;
  if (caps.wt && caps.vd) return true;
  return caps.rtc;
}

/** What this browser is missing, in the visitor's words. Never blames them. */
export function heroBlockedLine(caps: HeroCaps): string {
  if (!caps.secure) {
    return 'Live machines need a secure (https) connection, and this page was not loaded over one.';
  }
  return 'This browser has neither WebTransport with WebCodecs nor WebRTC, so it cannot receive a live picture. A current Safari, Chrome, Edge or Firefox can.';
}

// ---------------------------------------------------------------------------
//  Auto-claim — the gate on the whole feature
// ---------------------------------------------------------------------------

export interface AutoClaimFacts {
  playable: boolean;
  /** document.visibilityState === 'visible'. */
  visible: boolean;
  /** From /walkin/state; undefined ⇒ not answered yet, so do not guess. */
  access: WalkinAccess | undefined;
  role: string;
  /** The anonymous budget, when the caller is anonymous. */
  budget: WalkinAnonBudget | undefined;
  /** Already holding a cell, or already asking for one. */
  holding: boolean;
  busy: boolean;
  /** Claims this page has already fired. Auto-claim is a ONE-shot. */
  attempts: number;
}

/**
 * Should the page claim a machine by itself, right now?
 *
 * Every clause is a cell that would otherwise be spent on nobody:
 *
 *   * `playable` — a browser that cannot render the picture must not hold the
 *     machine that is producing it.
 *   * `visible` — a background tab is not a visitor. This is the crawler and
 *     the middle-click-into-a-new-tab case, and it is the cheapest of the
 *     checks to get right: `document.visibilityState` is already correct on the
 *     first paint of a backgrounded tab.
 *   * `access` known and allowing this role — asking a closed door for a
 *     machine gets a refusal that the page then has to explain, and the door
 *     being shut is not an error to show a stranger.
 *   * not expired — an anonymous visitor whose 60 seconds are gone gets the
 *     wall, not another claim the server will refuse.
 *   * `attempts === 0` — auto means ONCE. A page that re-claims on its own after
 *     a failure is a page that hammers the broker from a tab nobody is reading;
 *     every later claim comes from a button a person pressed.
 */
export function shouldAutoClaim(f: AutoClaimFacts): boolean {
  if (!f.playable || !f.visible) return false;
  if (f.holding || f.busy || f.attempts > 0) return false;
  if (f.access === undefined || !accessAllows(f.access, f.role)) return false;
  return !(f.budget?.expired ?? false);
}

// ---------------------------------------------------------------------------
//  The countdown mirror
// ---------------------------------------------------------------------------

/**
 * The visitor-facing countdown, mirrored from the server's number.
 *
 * The contract is explicit that `remainingSeconds` is server-authoritative and
 * that the client clock is a MIRROR, never the source of truth. So this never
 * accumulates: it recomputes from the last polled number and the wall time
 * since that poll, which means a poll landing late, early or out of order snaps
 * the display to the truth instead of drifting away from it. Clamped at zero —
 * a negative countdown is a number no visitor should ever be shown.
 */
export function mirroredRemaining(serverSeconds: number, polledAt: number, now: number): number {
  const elapsed = Math.floor(Math.max(0, now - polledAt) / 1000);
  return Math.max(0, Math.floor(serverSeconds) - elapsed);
}

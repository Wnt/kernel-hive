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
//
//  WHAT COUNTS AS "SOMEBODY IS THERE" changed on 2026-09-10, and it is the
//  reason for most of this file. The visitor's intro time used to start when
//  the page took a machine, so a stranger reading the headline was already
//  spending it — measured on the live site: seventeen seconds gone before
//  anything was touched. Now the minute starts at the first MEANINGFUL input,
//  the server keeps that clock (`POST /walkin/engage`), and the cost of the
//  change is that a claim no longer bounds itself. That cost is paid here, by
//  a longer release for a machine nobody has engaged with.
// ============================================================================

/**
 * The events that mean a person is DRIVING the machine, and the whole list.
 *
 * The line is deliberately where the operator drew it: "the 1 minute should
 * only start after I have interacted with the machine in a meaningful way like
 * first click or keyboard entry. just moving the mouse over the display canvas
 * should not start it." A pointer crossing the picture is a cursor moving over
 * a poster; it is also, on this page, the single most likely thing to happen by
 * accident, because the machine sits under the headline the visitor is reading.
 *
 * So: presses, taps and keys. NOT `mousemove`/`pointermove` (crossing it),
 * NOT `wheel` or `scroll` (reading past it — `wheel` was on this list until it
 * was noticed that scrolling to the collection below the fold starts a minute
 * the visitor never asked for), NOT `focus`/`mouseover`/`pointerover` (arriving
 * near it). `mousedown` rides beside `pointerdown` for the browsers that never
 * got Pointer Events; both firing for one press is harmless, since the first
 * touch is the only one that decides anything.
 */
export const MEANINGFUL_EVENTS = ['pointerdown', 'mousedown', 'touchstart', 'keydown'] as const;

/** Whether a DOM event type is one the visitor's minute may start on. */
export function isMeaningful(type: string): boolean {
  return (MEANINGFUL_EVENTS as readonly string[]).includes(type);
}

/**
 * How long a claimed cell may go UN-ENGAGED before it goes back.
 *
 * The old number was fifteen seconds, and it was right for the world it was
 * written in: the budget was already burning, so a cell nobody had touched in
 * fifteen seconds was a cell being wasted twice over. With the clock no longer
 * running until first touch, the same fifteen seconds became the bug the
 * operator reported — the machine was taken away from a visitor who was still
 * reading, and the only way back re-rolled the station.
 *
 * A hundred seconds is chosen against what a person actually does above the
 * fold: read a headline, a five-line lede and the caption under the machine,
 * glance at three switcher chips, and reach for the mouse. That is well under a
 * minute even read slowly, so this is a whole unhurried visit plus margin. It
 * is under the SERVER's own window (`auth/anon.py UNENGAGED_SECONDS`, 120s) on
 * purpose, so the tab that can hand its own cell back does — the server's sweep
 * is the backstop for the client that never will, which is exactly the client
 * that is not a person.
 */
export const UNENGAGED_GRACE_MS = 100_000;

/** How near the un-engaged release the caption starts saying so. A warning that
 *  runs for a hundred seconds is furniture; one that appears at the end is a
 *  warning. */
export const GRACE_WARN_SECONDS = 30;

/**
 * How long a cell the visitor HAS engaged with may sit in a hidden tab.
 *
 * Someone who has already typed at the guest and then switches tabs for twenty
 * seconds is a visitor, not a crawler, and taking their machine away
 * mid-thought is a worse failure than holding a cell for half a minute. Someone
 * who never touched it gets no such benefit of the doubt — see `hidden` in
 * releaseDue(). It is shorter than the un-engaged window and that is not a
 * contradiction: their minute is RUNNING, so holding the cell is spending their
 * budget on a tab they cannot see.
 */
export const HIDDEN_GRACE_MS = 30_000;

export interface HoldFacts {
  now: number;
  /** When the broker handed this cell over. */
  claimedAt: number;
  /** The first MEANINGFUL input on the machine; null ⇒ never engaged. Sticky
   *  for the visit, exactly like the server's own `engaged` — engagement is a
   *  fact about the person, so it is not re-earned for each machine they try. */
  engagedAt: number | null;
  /** The last trusted press ANYWHERE on the hero — a switcher chip, the call to
   *  action. Not engagement (it says nothing about the guest), but it is proof a
   *  person is on the page, so it pushes the un-engaged release out rather than
   *  cancelling it. */
  lastPresenceAt: number | null;
  /** When the tab went hidden; null ⇒ visible. */
  hiddenSince: number | null;
}

/** When the un-engaged clock started running: the claim, or the last time the
 *  visitor proved they were here, whichever is later. */
function untouchedSince(f: Pick<HoldFacts, 'claimedAt' | 'lastPresenceAt'>): number {
  return Math.max(f.claimedAt, f.lastPresenceAt ?? 0);
}

/** Why the hero is handing its cell back, or null to keep holding. */
export type ReleaseReason = 'never-driven' | 'hidden';

/**
 * Is the visitor's minute running right now?
 *
 * Both halves are required and neither is enough. The budget is sixty seconds
 * of CONNECTED time, so a visitor holding no machine spends nothing; and since
 * 2026-09-10 it is sixty seconds of connected time AFTER THE FIRST TOUCH, so a
 * visitor who has not engaged spends nothing either. The server keeps the
 * authoritative clock and this only decides whether the mirror ticks — but a
 * mirror that ticks when the server's number is standing still runs away from
 * it and then snaps back on the next poll, which reads as a broken countdown.
 */
export function budgetRunning(f: { holding: boolean; engaged: boolean }): boolean {
  return f.holding && f.engaged;
}

/**
 * Should this held cell go back to the pool right now?
 *
 * Order matters, and it is the order of how sure we are that nobody is there:
 *
 *   1. Never engaged AND the tab is hidden — the strongest signal there is. A
 *      page that was claimed and immediately backgrounded was opened by
 *      software or by a person who has already moved on. No grace at all.
 *   2. Never engaged, visible, past the grace — the crawler case, and the
 *      "opened in a tab to read later" case. A hundred seconds is long enough
 *      for a real person to read the page and reach for the mouse, and short
 *      enough that twenty-four cells are not held by nobody. A press anywhere
 *      on the hero pushes it out again; it does not cancel it, because a
 *      visitor who pressed one chip and left is still a visitor who left.
 *   3. Engaged, but hidden past the longer grace — a real visitor who left.
 *
 *  A visible, engaged cell is never released here: from that point it is the
 *  broker's TTL and idle windows that own the session (walkin/sessionEnd.ts),
 *  and a second, shorter client-side rule would only end sessions the server
 *  believes are alive.
 */
export function releaseDue(f: HoldFacts): ReleaseReason | null {
  const engaged = f.engagedAt !== null;
  const hidden = f.hiddenSince !== null;
  if (!engaged && hidden) return 'hidden';
  if (!engaged && f.now - untouchedSince(f) >= UNENGAGED_GRACE_MS) return 'never-driven';
  if (engaged && hidden && f.now - (f.hiddenSince as number) >= HIDDEN_GRACE_MS) return 'hidden';
  return null;
}

/** Seconds left before an un-engaged cell is handed back — the caption's number. */
export function graceSecondsLeft(f: Pick<HoldFacts, 'now' | 'claimedAt' | 'lastPresenceAt'>): number {
  return Math.max(0, Math.ceil((UNENGAGED_GRACE_MS - (f.now - untouchedSince(f))) / 1000));
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
 *
 * `connected` is not a refinement, it is the definition. The budget is sixty
 * seconds of CONNECTED time, so a visitor holding no machine is spending
 * nothing and their clock must stand still. Ticking it down anyway would run
 * the display away from the server between polls and then jump it back up on
 * the next one — which is exactly what a staged probe saw when the page's own
 * idle-release handed the machine back at fifteen seconds and the countdown
 * kept counting.
 */
export function mirroredRemaining(
  serverSeconds: number,
  polledAt: number,
  now: number,
  connected = true,
): number {
  const floor = Math.max(0, Math.floor(serverSeconds));
  if (!connected) return floor;
  return Math.max(0, floor - Math.floor(Math.max(0, now - polledAt) / 1000));
}

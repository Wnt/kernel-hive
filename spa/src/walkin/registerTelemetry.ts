// ============================================================================
//  registerTelemetry — everything the analytics plane wants to know about one
//  stranger's attempt to get a walk-in account, in one object.
//  ---------------------------------------------------------------------------
//  WHY THIS IS ITS OWN MODULE. Same reason as three/connectTelemetry.ts: the
//  landing page is a page, and threading a funnel, four clocks and a counter
//  through it directly would make every future measurement a negotiation with
//  that file's readability. The page calls named things; the reasoning lives
//  here.
//
//  THE THREE PLANES, SIDE BY SIDE, WHICH IS WHERE THE DISTINCTION IS EASIEST:
//
//    the FLOW  says how far an attempt got, and where it stopped.
//    the CLOCKS say how long the visitor spent on each stage of it.
//    the PROBE says a visitor was REFUSED — which is not the same as lost.
//
//  REFUSAL IS NOT ABANDONMENT, and this is the whole reason `registerRefused`
//  exists. The operator can close the walk-in plane (WALKIN-BRIEF §7,
//  reasons.ts). A stranger who arrives then never gets a machine to attempt, so
//  no flow is opened for them at all — if one were, the funnel would show a
//  cliff at `landing` and read as a broken landing page, and somebody would
//  rewrite copy to fix a switch. Refusals are counted as their own fact; the
//  funnel's drop-off then means only what it says.
//
//  A RETURNING VISITOR OPENS NOTHING. Somebody who already has an account is
//  not registering. Putting them in the funnel would mean a population that
//  legitimately skips three of the four steps, which does not make the funnel
//  bigger — it makes it wrong.
//
//  WHAT IS DELIBERATELY NOT MEASURED HERE. No handle, no credential id, no
//  which-machine-this-visitor-chose, no attempt count per person, no wall-clock
//  timestamps. This plane is a durable aggregate with no identity column by
//  construction (scripts/serve/analytics.py), and the walk-in door — a stranger
//  typing at a form — is the last place that should be the exception. What
//  travels is a bucketed duration and a bucketed count, and nothing else can be
//  reassembled from those.
// ============================================================================

import { beginFlow, reach, recordMetric, startTiming, type Timing } from '../analytics';
import type { FlowHandle } from '../analytics/flows';

/** The stranger met a closed door. Counted, never funnelled — see the header. */
export function registerRefused(): void {
  reach('walkin.register.refused', 'show');
}

/** One registration attempt. Every method is safe to call in any order and any
 *  number of times; the underlying handles settle exactly once. */
export interface RegisterTelemetry {
  /** The door is open, this visitor has no account, and the page is in front of
   *  them. Starts the landing stage and the hesitation clock. */
  landed(): void;
  /** This browser cannot make a passkey at all. A FENCE, like a closed door —
   *  reported as its own failure reason so it is never read as a visitor who
   *  could have signed up and did not. */
  unsupported(): void;
  /** A passkey ceremony is starting. Every start after the first is a retry. */
  passkeyStarted(): void;
  /** An account exists. Opens the machine-picking stage if a machine has not
   *  already been chosen (the one-tap path chooses first, and there is then no
   *  picking stage to measure). */
  accountReady(): void;
  /** A machine was chosen. Closes the landing and picking stages; does NOT
   *  advance the funnel, because on the one-tap path this happens before the
   *  account exists and the funnel has one order (see catalogue/walkin.ts). */
  chose(): void;
  /** The visitor is being sent to their machine. The attempt succeeded. */
  reachedMachine(): void;
  /** Torn down — navigated away, or the effect unmounted. Reports NOTHING: the
   *  abandonment is already the funnel's drop-off, and reporting it as a
   *  failure would double-count every departure as a fault. Not calling it is
   *  the real bug; both handle sets are bounded and a leak silently stops the
   *  plane measuring. */
  abandoned(): void;
}

/** Input types that count as "the visitor did something with this page". The
 *  same set analytics/intent.ts witnesses, and for the same reason: a wheel or
 *  a touch is a person engaging with a page just as much as a click is. */
const FIRST_TOUCH_EVENTS = ['pointerdown', 'keydown', 'wheel', 'touchstart'] as const;

export function registerTelemetry(): RegisterTelemetry {
  const flow: FlowHandle = beginFlow('walkin.register');
  const hesitation: Timing = startTiming('walkin.register.hesitationMs');
  const landing: Timing = startTiming('walkin.register.landingMs');
  let passkey: Timing | null = null;
  let picking: Timing | null = null;
  let attempts = 0;
  let chosen = false;
  let settled = false;
  let detach: (() => void) | null = null;

  /** Stop the hesitation clock at the visitor's first act on the page, and stop
   *  listening. Untrusted events are ignored: a dispatched click is software
   *  acting, and hesitation is a fact about a person. */
  const watchFirstTouch = () => {
    if (typeof document === 'undefined' || detach) return;
    const onEdge = (event: Event) => {
      if (!event.isTrusted) return;
      hesitation.stop();
      detach?.();
    };
    const opts = { capture: true, passive: true } as const;
    try {
      for (const type of FIRST_TOUCH_EVENTS) document.addEventListener(type, onEdge, opts);
      detach = () => {
        for (const type of FIRST_TOUCH_EVENTS) document.removeEventListener(type, onEdge, opts);
        detach = null;
      };
    } catch { /* no listener: we lose the hesitation sample, not the page */ }
  };

  /** Every clock this attempt owns, dropped without a sample. */
  const abandonClocks = () => {
    hesitation.abandon();
    landing.abandon();
    passkey?.abandon();
    picking?.abandon();
    detach?.();
  };

  return {
    landed() {
      watchFirstTouch();
    },
    unsupported() {
      if (settled) return;
      settled = true;
      abandonClocks();
      flow.fail('nopasskey');
    },
    passkeyStarted() {
      // The landing stage ends the moment the ceremony begins, whichever button
      // started it. Hesitation ends here too if nothing else had touched the
      // page — pressing the button IS the first interaction.
      hesitation.stop();
      landing.stop();
      detach?.();
      attempts += 1;
      // One clock for the whole STAGE, not one per attempt: three cancelled
      // sheets and a fourth that works is one stage that took a long time, and
      // timing each attempt separately would report the successful fourth as a
      // fast passkey.
      if (!passkey) passkey = startTiming('walkin.register.passkeyMs');
      flow.step('passkey');
    },
    accountReady() {
      passkey?.stop();
      if (attempts > 0) {
        // Attempts only. A zero here means "enrolled first try", which is the
        // finding; a zero from a visitor who never started a ceremony would be
        // a zero about a stage they never entered, and enough of those would
        // hide a real retry problem under a floor of them.
        recordRetries(attempts - 1);
      }
      flow.step('account');
      if (!chosen && !picking) picking = startTiming('walkin.register.exhibitPickMs');
    },
    chose() {
      chosen = true;
      hesitation.stop();
      landing.stop();
      detach?.();
      picking?.stop();
    },
    reachedMachine() {
      if (settled) return;
      settled = true;
      abandonClocks();
      flow.step('machine');
      flow.ok();
    },
    abandoned() {
      if (settled) return;
      settled = true;
      abandonClocks();
      flow.close();
    },
  };
}

/** Split out so the retry count has one call site and one comment. */
function recordRetries(retries: number): void {
  recordMetric('walkin.register.passkeyRetries', retries);
}

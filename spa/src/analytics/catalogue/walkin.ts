// ============================================================================
//  analytics/catalogue/walkin — the walk-in plane and the on-screen keyboard
//  ---------------------------------------------------------------------------
//  One area per file so a parallel wave of instrumentation work has no shared
//  editing surface. See catalogue/types.ts for what each field means and
//  catalogue/index.ts for how these merge; the rules that make a declaration
//  worth making — and the gate that stops a declared-but-uncalled probe from
//  reading as a dead feature — are in the index.
//
//  WHAT EVERY NUMBER IN THIS FILE IS, AND IS NOT. The walk-in door and the
//  touch keyboard are the two places in the gallery where a STRANGER meets the
//  software with nobody to ask, so the interesting question about both is how
//  much work they are. Hesitation, retries, corrections and layer switches are
//  BEHAVIOURAL PROXIES for that work: they observe what a visitor's hands did,
//  which is evidence about the interface and not a measurement of the person.
//  A long hesitation is evidence the page does not say what to do next; it is
//  not "the visitor found this hard", and no row here may be read that way.
//  Each `what` below therefore names a DECISION, never a state of mind.
//
//  THE PRIVACY LINE, WHICH IS TIGHTER HERE THAN ANYWHERE ELSE IN THE PLANE.
//  This is a stranger typing — sometimes their own name — into a form and into
//  a guest. Nothing about the CONTENT of that leaves the tab: not the text, not
//  its length, not a per-keystroke timing series, not a handle, not a clone id,
//  not which of the three machines a given visitor took. Corrections travel as
//  a bucketed PERCENTAGE and hesitation as a bucketed DURATION, and that is the
//  whole of it. scripts/serve/analytics.py stores no identity by construction;
//  this area must not become the exception that makes that sentence false.
// ============================================================================

import type { FlowSpec, MetricSpec, ProbeSpec } from './types.ts';

export const WALKIN_PROBES = {
  'keyboard.osk.used': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/OnScreenKeyboard.tsx',
    what: 'a key was pressed on the ON-SCREEN keyboard, not a physical one',
    grades: ['act'],
  },
  // ---- refusal is not abandonment -----------------------------------------
  // The walk-in door has a switch on it (WALKIN-BRIEF §7): the operator can
  // close the plane, and a stranger who arrives then is shown the frozen closed
  // sentence instead of the three machines. That visitor never got to attempt
  // registration, so no `walkin.register` flow is opened for them — if one were,
  // the funnel would report a fence the lab deliberately built as a UX failure,
  // and somebody would go and "fix" the landing page. The refusal is counted
  // HERE instead, as its own fact, so it is visible without being blamed on the
  // door. Read the two together: refusals are the switch, funnel drop-off is the
  // page.
  'walkin.register.refused': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a stranger reached the walk-in door while access was closed and was shown the closed sentence',
    grades: ['show'],
  },
  // ---- the pool's own answer, split at the only place it matters ----------
  // Every claim comes back one of two ways, and fusing them is how an exhausted
  // pool and a healthy one produce the same picture. The RATIO of these two is
  // the first half of the poolSize argument; `walkin.play.queueMs` is the
  // second half (how long the queued ones actually waited). One is worthless
  // without the other: 30% queued for four seconds is fine, 2% queued for four
  // minutes is not, and neither number alone can tell you which you have.
  'walkin.play.claimInstant': {
    area: 'walkin',
    owner: 'src/walkin/playTelemetry.ts',
    what: 'a claim was answered with a clone immediately — the pool had a free machine for this visitor',
    grades: ['auto'],
  },
  'walkin.play.claimQueued': {
    area: 'walkin',
    owner: 'src/walkin/playTelemetry.ts',
    what: 'a claim was answered with a queue position — every clone of that station was taken at that moment',
    grades: ['auto'],
  },
} as const satisfies Record<string, ProbeSpec>;

export const WALKIN_FLOWS = {
  // ---- the operator's question, by name -----------------------------------
  // "How many people who arrive at the walk-in door end up playing something?"
  // The funnel answers the how-many half for free; the per-stage dwell metrics
  // below answer the which-stage-costs-most half. Neither is derivable from the
  // other, which is why both exist.
  //
  // ONE ORDER, TWO PATHS. There are two ways through this door — press "Create
  // my passkey" and then choose a machine, or press "Play it" on a card and get
  // the passkey on the way — and a monotonic funnel (analytics/flows.ts) can
  // only have one order. So `machine` is reported when the visitor is actually
  // SENT to a machine, which on both paths is after the account exists. The
  // click that expressed the choice is not the step; arriving is.
  //
  // A VISITOR WHO ALREADY HAS AN ACCOUNT OPENS NO FLOW. They are not attempting
  // registration, and counting them would put a population that skips three
  // steps into a funnel whose whole purpose is to measure those three steps.
  'walkin.register': {
    area: 'walkin',
    what: 'a stranger with no account getting one and reaching a machine to play',
    steps: ['landing', 'passkey', 'account', 'machine'],
  },
  // Claiming a private clone. `driven` — not `held`, and not a painted frame —
  // is the end, because a clone the visitor never touches is one the pool spent
  // and the museum got nothing for. The painted frame is already measured by
  // `station.open.toFirstFrameMs` on the station plane; repeating it here would
  // be a fourth number that disagrees with three better ones.
  'walkin.play': {
    area: 'walkin',
    what: 'claiming a private clone and getting a machine the visitor actually drives',
    steps: ['claim', 'held', 'driven'],
  },
  // The on-screen keyboard as an ATTEMPT: it came up, did anything get typed?
  // `firstKey` catches a keyboard opened by accident or not understood at all;
  // `text` catches one where the visitor found modifiers and arrows but never a
  // character — which on a per-machine layout is a layout finding, not a
  // visitor one.
  'keyboard.compose': {
    area: 'keyboard',
    what: 'typing something at a guest with the on-screen keyboard sheet',
    steps: ['shown', 'firstKey', 'text'],
  },
} as const satisfies Record<string, FlowSpec>;

export const WALKIN_METRICS = {
  // ======== walkin.register — where the door costs the most ================
  // PER STAGE, NOT ONE TOTAL. A single "registration took 40 s" says the door
  // is slow and gives nobody anything to do about it. Split three ways it says
  // WHICH stage to work on, and — just as usefully — which one is not ours to
  // fix: `passkeyMs` is mostly the platform's own sheet, and no copy change on
  // this side moves it.
  //
  // All of these are VISIBLE time (analytics/metrics.ts). That is what makes
  // the hesitation number honest: a stranger who opens the walk-in door, tabs
  // away to finish something else and comes back did not hesitate for four
  // minutes, and a handful of those would move every percentile into fiction.
  'walkin.register.hesitationMs': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a high value means the walk-in page does not tell an arriving stranger what to do — rewrite the lede and the call to action before optimising anything downstream',
    scale: 'ms',
  },
  // The stage dwell, which is a different quantity from the hesitation above:
  // hesitation ends at the visitor's FIRST touch of anything, this ends when
  // they leave the stage. Read together they separate "could not tell what to
  // do" (long hesitation) from "read all three cards carefully" (short
  // hesitation, long dwell) — and the second is the page working, not failing.
  'walkin.register.landingMs': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a high value means the landing page is where registrations stall, so shortening it beats speeding up anything after it',
    scale: 'ms',
  },
  // Mostly the platform's passkey sheet, and worth knowing precisely because it
  // is: a high value here is an argument for warning the visitor what is about
  // to happen, never for rewording our own button.
  'walkin.register.passkeyMs': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a high value means the platform passkey ceremony is where the door spends its time, so the fix is preparing the visitor for it rather than changing our copy',
    scale: 'ms',
  },
  // Only measured on the path where the stage EXISTS: a visitor who made a
  // passkey first and then still had to pick one of three machines. On the
  // one-tap path the machine was chosen before the account, so there is no
  // picking stage at all and recording a zero for it would invent one.
  'walkin.register.exhibitPickMs': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a high value means a visitor who already has an account still cannot choose between the three cards, so the cards are not telling the machines apart',
    scale: 'ms',
  },
  // The single strongest friction signal at this door. Passkey enrolment fails
  // for platform reasons a visitor cannot diagnose or report — a cancelled
  // sheet, an authenticator that will not, a browser that half-supports it —
  // and without a count the operator cannot tell "this is a bit fiddly" from
  // "this is broken on some phone". Attempts only: a visitor who never started
  // a ceremony contributes nothing, because a zero from them would be a zero
  // about a stage they never entered.
  'walkin.register.passkeyRetries': {
    area: 'walkin',
    owner: 'src/walkin/registerTelemetry.ts',
    what: 'a high value means passkey enrolment is failing for platform reasons visitors cannot fix, so the door needs a diagnosable failure path rather than better wording',
    scale: 'count',
  },

  // ======== walkin.play — is poolSize 3 enough ============================
  // Recorded ONLY for visitors who were actually told to wait. An instant claim
  // is not a zero-length queue wait, it is the absence of a queue, and folding
  // the two into one distribution is exactly how a healthy pool and an
  // exhausted one come out looking the same. How MANY were queued is the
  // claimInstant/claimQueued probe pair above; this is how long those ones sat.
  'walkin.play.queueMs': {
    area: 'walkin',
    owner: 'src/walkin/playTelemetry.ts',
    what: 'a high value means visitors who meet a full pool wait long enough to give up, which is the argument for raising poolSize past 3',
    scale: 'ms',
  },
  // Claim accepted → the visitor demonstrably driving the machine. It ends at
  // their first deliberate input on the clone rather than at a painted frame,
  // for two reasons: the frame is already measured by the station plane, and a
  // clone that paints perfectly and is never touched is still a clone the pool
  // spent for nothing.
  'walkin.play.toPlayableMs': {
    area: 'walkin',
    owner: 'src/walkin/playTelemetry.ts',
    what: 'a high value means the gap between being handed a clone and being able to use it is where walk-ins are lost, so the resume path is worth more than the claim path',
    scale: 'ms',
  },
  // A RESET is deliberately not a retry: the visitor asked for a fresh machine
  // and got one, which is the feature working. Counting it here would report a
  // working feature as friction.
  'walkin.play.claimRetries': {
    area: 'walkin',
    owner: 'src/walkin/playTelemetry.ts',
    what: 'a high value means one press of Play does not get a machine, so the queue card is doing work the pool should be doing',
    scale: 'count',
  },

  // ======== keyboard.compose — is the hand-maintained layout data working ==
  // keyboardProfiles.data.exotic.ts is 400+ lines of per-machine layout,
  // maintained by hand, with no evidence either way about whether it earns
  // that. These three are that evidence. All of them are scoped to the mobile
  // SHEET, deliberately: the desktop inline footer is always on screen (so
  // nothing "appears"), has no layers, and its free-text field is driven by a
  // PHYSICAL keyboard — instrumenting it would glue two populations into one
  // distribution and call the result a measurement.
  'keyboard.compose.toFirstKeyMs': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/composeTelemetry.ts',
    what: 'a high value means the keyboard comes up and the key people came for is not findable at a glance, so the layout needs reordering rather than more keys',
    scale: 'ms',
  },
  // Backspaces as a percentage of characters committed, per episode. On a
  // layout the lab wrote by hand, a high rate is a defect in the LAYOUT DATA —
  // a key in the wrong place, a glyph that sends something else — and not a
  // defect in the visitor. What it cannot tell apart is a mistyped key from a
  // visitor changing their mind, and that limit is why it is a rate rather than
  // an error count: a rate that doubles between two machines' layouts is a
  // finding even if neither absolute number means much on its own.
  'keyboard.compose.correctionsPct': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/composeTelemetry.ts',
    what: 'a high value means this machine\'s hand-written key layout puts keys where people do not expect them, so the profile data is wrong and worth fixing before adding another',
    scale: 'pct',
  },
  // Movements between the ABC / ?123 / OS layers in one episode. This observes
  // NAVIGATION COST, not confusion: switching to ?123 for a digit is a correct
  // use of the layer split, and it still cost the visitor a round trip. Shift
  // is deliberately excluded — shift is how you type a capital, and cycling to
  // caps lock is two deliberate presses, so counting either as hunting would
  // report ordinary typing as a defect.
  'keyboard.compose.layerSwitches': {
    area: 'keyboard',
    owner: 'src/ui/keyboard/composeTelemetry.ts',
    what: 'a high value means the characters people need are spread across layers, so the split is costing more round trips than it saves screen space',
    scale: 'count',
  },
} as const satisfies Record<string, MetricSpec>;

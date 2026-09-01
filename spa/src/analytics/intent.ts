// ============================================================================
//  analytics/intent — WHY a code path ran, not just THAT it ran.
//  ---------------------------------------------------------------------------
//  The whole point of this plane is to separate three things a plain hit
//  counter fuses into one number:
//
//    auto  the path ran because the page loaded, a poll fired, a component
//          mounted, or a retry came round. Nobody asked for it. An endpoint
//          that is only ever `auto` is pure cost: it is called, and its answer
//          changes nothing anyone sees or does.
//    show  the result was actually PUT IN FRONT OF A HUMAN — rendered, in a
//          visible tab, and (where a DOM anchor is given) intersecting the
//          viewport. A row rendered into a collapsed panel or a background tab
//          is not `show`; counting it as one is how a dead feature keeps its
//          budget.
//    act   a human deliberately operated it. Requires a TRUSTED input edge
//          (`isTrusted`), a visible document, and a recent pointer/key edge —
//          see `witnessHumanEdge`.
//
//  These grade UP and never down: a probe that reports `act` implies the thing
//  was also shown. The report keeps them as three independent counters anyway,
//  because "shown 900 times, acted on 12 times" is the sentence the operator
//  wants and a collapsed total destroys it.
//
//  WHO IS ASKING. This lab drives its own SPA with a fleet of headless and
//  headed browser probes (scripts/e2e/*.mjs, the CT950 typing-pace probe, the
//  scene-shot rigs). They click and type for real, so every heuristic above
//  says "human". Left unclassified they would not merely add noise — they would
//  be the MAJORITY of the traffic on a 63-station private gallery, and every
//  drop/keep decision made from this data would be a decision about what the
//  test fleet exercises. So class is a first-class dimension on every event and
//  the report defaults to `human` only.
// ============================================================================

/** How deliberate an observation was. Ordered weakest to strongest. */
export type Intent = 'auto' | 'show' | 'act';

/** Who produced the event. `probe` is this lab's own automation. */
export type ClientClass = 'human' | 'probe' | 'unknown';

/**
 * A trusted input edge older than this cannot vouch for an `act`. Long enough
 * to cover a click that lands after a React re-render and a state update
 * (a few frames plus an async hop), short enough that a timer firing a second
 * later cannot borrow the credit from a click the visitor has forgotten.
 */
const HUMAN_EDGE_TTL_MS = 1000;

let lastHumanEdgeAt = 0;
let installed = false;
/** Depth of the synthetic bracket — see `withSyntheticInput` in usageStats. */
let synthetic = 0;
let classOverride: ClientClass | null = null;

declare global {
  interface Window {
    /** Set by scripts/e2e/*.mjs before the bundle boots, to declare itself. */
    __khClientClass?: ClientClass;
  }
}

/**
 * Record that a genuine human edge just happened. Called from the capture-phase
 * listeners installed by `installIntentWitness`, and directly by the input wire
 * for edges that reach the guest without a DOM event of their own.
 */
export function witnessHumanEdge(at = Date.now()): void {
  if (synthetic > 0) return;
  lastHumanEdgeAt = at;
}

/**
 * Listen for trusted input in the CAPTURE phase, so an edge is witnessed before
 * any handler has had a chance to stop it propagating. Untrusted (synthesised)
 * events are ignored: a dispatched click is the software acting, and the whole
 * value of `act` is that it is not.
 */
export function installIntentWitness(): void {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  const on = (type: string) => {
    try {
      window.addEventListener(type, (e: Event) => {
        if (e.isTrusted) witnessHumanEdge();
      }, { capture: true, passive: true });
    } catch { /* a listener we cannot install costs us grading, not the app */ }
  };
  for (const type of ['pointerdown', 'keydown', 'wheel', 'touchstart']) on(type);
}

/** Run `fn` with human-edge witnessing suppressed — for input the SOFTWARE
 *  generates (type-in demos, the win9x boot-modal auto-dismiss). Mirrors
 *  usageStats.withSyntheticInput, and for the same reason: one click that
 *  starts a demo is one act, not the four hundred key edges it puts on the
 *  wire. */
export function withoutHumanCredit<T>(fn: () => T): T {
  synthetic += 1;
  try {
    return fn();
  } finally {
    synthetic -= 1;
  }
}

/** Is the tab actually in front of somebody right now? */
function documentVisible(): boolean {
  try {
    return typeof document === 'undefined' || document.visibilityState !== 'hidden';
  } catch {
    return true;
  }
}

/**
 * Can this observation honestly be reported at `want`? Returns the strongest
 * grade the evidence supports, which may be weaker than what the call site
 * asked for. Call sites therefore state their INTENT and this states the FACT —
 * a render that happens in a hidden tab reports `auto`, not `show`, without the
 * call site having to know it was hidden.
 */
export function gradeFor(want: Intent): Intent {
  if (want === 'auto') return 'auto';
  if (!documentVisible()) return 'auto';
  if (want === 'show') return 'show';
  if (synthetic > 0) return 'show';
  const age = Date.now() - lastHumanEdgeAt;
  return age >= 0 && age <= HUMAN_EDGE_TTL_MS ? 'act' : 'show';
}

/**
 * Which fleet this tab belongs to. An explicit declaration wins; otherwise
 * `navigator.webdriver` is the honest automatic signal — Puppeteer, Playwright
 * and every remote-debugging attach set it, which covers this lab's own probe
 * fleet without any of them having to be edited.
 */
export function clientClass(): ClientClass {
  if (classOverride) return classOverride;
  try {
    const declared = window.__khClientClass;
    if (declared === 'human' || declared === 'probe' || declared === 'unknown') {
      classOverride = declared;
      return declared;
    }
    if (navigator.webdriver === true) return 'probe';
    return 'human';
  } catch {
    return 'unknown';
  }
}

/** Test seam: forget every witnessed edge and cached classification. */
export function __resetIntent(): void {
  lastHumanEdgeAt = 0;
  synthetic = 0;
  classOverride = null;
  installed = false;
}

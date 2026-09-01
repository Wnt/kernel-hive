// ============================================================================
//  fleetFindEpisode — how much work it is to answer a question with the table.
//  ---------------------------------------------------------------------------
//  The fleet table is 61 rows by ~20 columns with a `width: max-content` body.
//  FleetTable.tsx already measures the SIDEWAYS cost of that (hScrollScreens,
//  hScrollReversals). This measures the other half: how long before a visitor
//  makes their first move, how many moves it takes to isolate one machine, and
//  whether they ever leave the table by opening one.
//
//  ONE EPISODE = ONE MOUNT OF THE TABLE, deliberately the same boundary the
//  scroll pair uses. Both are opened when the table mounts and settled when it
//  unmounts, so a visit's action count and its scroll distance are two numbers
//  about the same episode and can be read together. That pairing is the whole
//  diagnosis — see catalogue/fleet.ts — and it only holds while the boundaries
//  agree, so moving one means moving the other.
//
//  WHAT THESE ARE. Behavioural proxies for effort: a hesitation delay and a
//  steps-to-goal count. They observe what a pointer did. They are not a
//  measurement of attention, difficulty or cognitive load, and describing them
//  as one would put a confident word on evidence that cannot carry it.
//
//  WHY A MODULE AND NOT AN EFFECT IN FleetTable.tsx. Two reasons, both
//  practical: the episode has four exits (first action, station chosen,
//  unmount, unmount-after-choosing) and every one of them has to settle a flow,
//  a timing and an accumulator in a consistent state — which is a state machine
//  worth testing on its own — and FleetTable.tsx is already 300 lines against a
//  600-line hard cap.
// ============================================================================

import { accumulator, beginFlow, startTiming, type Timing } from '../analytics';

export interface FleetFindEpisode {
  /** A deliberate act that narrows the table: a sort, a facet toggle, or the
   *  free-text filter going from empty to non-empty. Called once per act.
   *
   *  ONE USE IS ONE USE: the caller must NOT report a keystroke. Per keystroke
   *  the free-text filter would be the most-used feature in the gallery by
   *  twenty times, and `actionsToStation` would count typing speed. */
  narrowed(): void;
  /** A station link in the table was clicked — the outcome the table exists
   *  for. Settles the action count; later calls are ignored. */
  choseStation(): void;
  /** The table went away. Settles anything still open. */
  end(): void;
}

const NOOP: FleetFindEpisode = { narrowed() {}, choseStation() {}, end() {} };

/**
 * Open one episode. Never throws; always returns a handle whose `end()` is safe
 * to call more than once.
 *
 * MUST NOT be called from inside a `setState` updater. React StrictMode invokes
 * updaters twice, which would open two flows and double every count — the same
 * trap `reach` carries, for the same reason.
 */
export function beginFleetFindEpisode(): FleetFindEpisode {
  try {
    const flow = beginFlow('fleet.find');
    // Landing to the first sort/filter/search. A hesitation proxy: how long
    // before somebody knows what to do with the table. Abandoned rather than
    // stopped if they never act, because a visit with no first action has no
    // first-action time — recording the whole visit as one would invent the
    // slowest samples in the distribution out of visits that never took part.
    let hesitation: Timing | null = startTiming('fleet.find.toFirstActionMs');
    // Discrete acts between arriving and opening a machine. Committed ONLY when
    // a machine is actually opened: this is steps-to-GOAL, and a visit that
    // never reached the goal has no step count for it. Committing those would
    // silently blend "it took nine sorts to find it" with "they gave up after
    // nine sorts", which are opposite findings.
    const actions = accumulator('fleet.find.actionsToStation');
    let chosen = false;
    let ended = false;

    return {
      narrowed() {
        try {
          if (ended || chosen) return;
          flow.step('narrow');
          if (hesitation) {
            hesitation.stop();
            hesitation = null;
          }
          actions.add(1);
        } catch { /* instrumentation never throws into the app */ }
      },
      choseStation() {
        try {
          if (ended || chosen) return;
          chosen = true;
          // A visitor who opens a machine without touching a control at all is
          // a ZERO, and a real one: the default order answered the question.
          // The accumulator commits zeros for exactly this case.
          actions.commit();
          flow.step('chooseStation');
          flow.ok();
          // They acted on the table without ever narrowing it, so there is no
          // first-action time to record. Not a zero — see metrics.ts.
          if (hesitation) {
            hesitation.abandon();
            hesitation = null;
          }
        } catch { /* noop */ }
      },
      end() {
        try {
          if (ended) return;
          ended = true;
          if (hesitation) {
            hesitation.abandon();
            hesitation = null;
          }
          // `close()`, never `fail()`: a visitor leaving the table is already
          // the funnel's drop-off, and reporting it as a fault would count
          // every abandonment twice. Harmless after `ok()`.
          flow.close();
        } catch { /* noop */ }
      },
    };
  } catch {
    return NOOP;
  }
}

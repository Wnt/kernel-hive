// ============================================================================
//  hallEngagement — does the 3D hall convert, or is it scenery?
//  ---------------------------------------------------------------------------
//  The hall (`/museum`, SceneV2) is the most expensive thing in this UI: a
//  parametric room, a dressing layer, grounding shadows, a machine assembly and
//  a live-textured screen per station. Nothing in the repo has ever answered
//  whether anybody reaches a machine THROUGH it, which makes "should we keep
//  spending on the hall" a question that has only ever been answered by taste.
//
//  WHAT "APPROACHED" MEANS HERE, AND WHY IT IS HONEST
//  --------------------------------------------------
//  It is not a proximity model invented for this metric. It is the scene's OWN
//  focus state, exactly as `screenTiers.ts` already computes it every frame:
//
//    a screen is APPROACHED when it becomes the ACTIVE focus — the nearest
//    visible screen to the centre of the view (inside the +/-0.55 x +/-0.65 NDC
//    focus window) AND it stayed that way for SCREEN_FOCUS_DWELL_MS.
//
//  Three reasons that definition is the right one and not a convenient one:
//
//   1. It is ALREADY LOAD-BEARING. The same condition decides whether the
//      gallery spends a live WebTransport texture on that screen. The scene
//      already believes this means "the visitor is at this machine"; the metric
//      does not get to believe something softer.
//   2. It is the UI's OWN gate for opening a machine. In ScreenPlane, clicking
//      a screen that is NOT focused does not open it — it walks the camera over
//      and shows the info card. Only a click on a FOCUSED screen navigates to
//      /os/<id>. So "approached but not opened" is literally "they were in the
//      one state from which opening was possible, and did not".
//   3. The 1.5 s dwell is what keeps it from counting the corridor. Machines
//      swept past during a rail move become the focus CANDIDATE for a few
//      frames and never become active, so passing a row of desks is not eleven
//      approaches.
//
//  WHAT IT CANNOT TELL YOU, stated beside it because this plane's rule is that
//  a measurement's limits travel with it:
//   - It is a CAMERA fact, not an attention fact. It says a machine was centred
//     in the view for a second and a half. It does not say anybody looked at
//     it, read its placard, or considered it. Approached-but-not-opened is
//     evidence that the labels are not converting; it is not a measurement of
//     interest, and nothing without eye tracking would be.
//   - A visitor who parks the camera and walks away accrues one approach, not
//     zero and not many. The distinct-set below is what stops an idle tab from
//     accruing hundreds.
//   - `hallTest`/`lineup` debug URLs mount synthetic desks. Those sessions are
//     driven by the probe fleet, which the plane already separates by client
//     class, so they do not need a second exclusion here.
// ============================================================================

import { accumulator, beginFlow, reach, startTiming, type Timing } from '../analytics';

interface Episode {
  flow: ReturnType<typeof beginFlow>;
  toFirstStation: Timing | null;
  /** Distinct tile ids that reached the active-focus state this episode. A SET,
   *  not a counter: a visitor drifting back and forth between two desks has
   *  approached two machines, not nine. */
  approached: Set<string>;
  /** Distinct tile ids actually opened, removed from the count at the end. */
  opened: Set<string>;
}

/** At most one hall is mounted at a time; a module-level episode is what lets
 *  screenTiers report an approach without every screen knowing about analytics.
 *  Bounded by `MAX_APPROACHED` so a tab left running overnight cannot grow it. */
let episode: Episode | null = null;
const MAX_APPROACHED = 128;

/**
 * The hall was mounted. Called from SceneV2's mount effect — NOT from a render
 * body and NOT from a `setState` updater, both of which StrictMode runs twice.
 * A second call without an `endHallEpisode` is ignored rather than stacking.
 */
export function beginHallEpisode(): void {
  try {
    if (episode) return;
    // The share-of-visits number: paired against `boot.index.fetch`, which every
    // visit fetches once, this says what fraction of visits ever enter the hall
    // at all. `reach` downgrades it to `auto` on its own if the tab is hidden.
    reach('hall.entered', 'show');
    episode = {
      flow: beginFlow('hall.navigate'),
      toFirstStation: startTiming('hall.navigate.toFirstStationMs'),
      approached: new Set(),
      opened: new Set(),
    };
  } catch { /* instrumentation never throws into the app */ }
}

/**
 * A screen became the scene's ACTIVE focus — see the header for exactly what
 * that is. Called from screenTiers.ts at the one place the dwell completes.
 */
export function noteHallApproach(tileId: string): void {
  try {
    if (!episode || !tileId) return;
    if (episode.approached.size >= MAX_APPROACHED) return;
    if (episode.approached.has(tileId)) return;
    episode.approached.add(tileId);
    episode.flow.step('approach');
  } catch { /* noop */ }
}

/** A machine was opened FROM the hall (ScreenPlane navigates to /os/<id>). */
export function noteHallOpen(tileId: string): void {
  try {
    if (!episode) return;
    if (tileId) episode.opened.add(tileId);
    episode.flow.step('open');
    episode.flow.ok();
    if (episode.toFirstStation) {
      // Entering the hall to opening the FIRST machine. Visible time only: a
      // hall left open in a background tab is not a visitor deliberating.
      episode.toFirstStation.stop();
      episode.toFirstStation = null;
    }
  } catch { /* noop */ }
}

/**
 * The hall went away — navigated away from, or unmounted. Settles everything.
 *
 * Note the ordering that makes the count mean what it says: this runs AFTER
 * `noteHallOpen`, because opening a machine unmounts the hall, so the opened
 * machine is already known and can be taken out of the approached set.
 */
export function endHallEpisode(): void {
  try {
    const ended = episode;
    if (!ended) return;
    episode = null;
    // Never opened one: there is no time-to-first-station for this visit, and
    // inventing one out of how long they wandered would put the hall's worst
    // sessions in the same distribution as its successes. The DROP-OFF is
    // already visible in the flow — that is the number for "they never did".
    ended.toFirstStation?.abandon();
    const approachedNotOpened = accumulator('hall.navigate.stationsApproached');
    let n = 0;
    for (const id of ended.approached) if (!ended.opened.has(id)) n += 1;
    approachedNotOpened.add(n);
    // Committed even at zero, and zero is the GOOD outcome twice over: the
    // visitor who walked to one machine and opened it, and the visitor who
    // never got near anything. The flow tells those two apart; dropping zeros
    // would leave a distribution made only of the wanderers.
    approachedNotOpened.commit();
    ended.flow.close();
  } catch { /* noop */ }
}

/** Test seam: forget any episode left open by a failed test. */
export function __resetHallEngagement(): void {
  episode = null;
}

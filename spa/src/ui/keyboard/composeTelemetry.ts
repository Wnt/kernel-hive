// ============================================================================
//  composeTelemetry — is the hand-maintained per-machine keyboard data working?
//  ---------------------------------------------------------------------------
//  THE BUDGET QUESTION. keyboardProfiles.data.exotic.ts is 400+ lines of
//  per-machine key layout written and maintained BY HAND, one profile per OS
//  family, and there has never been any evidence about whether it earns that.
//  `keyboard.osk.used` says the on-screen keyboard is pressed; it cannot say
//  whether the layout it presents is any good. These three numbers can:
//
//    toFirstKeyMs     the sheet is up — how long before a key is found at all
//    correctionsPct   backspaces as a share of characters actually committed
//    layerSwitches    round trips between ABC / ?123 / OS to reach a character
//
//  WHAT THEY ARE EVIDENCE FOR, STATED PLAINLY. They observe what a visitor's
//  hands did. They are behavioural proxies for how much work the layout is, and
//  they are not measurements of anybody's understanding: a long time to a first
//  key is evidence that the key somebody wanted is not findable at a glance,
//  and it is equally consistent with a visitor who put the phone down. That is
//  why the clock counts VISIBLE time only (analytics/metrics.ts) and why the
//  conclusion these support is "reorder this layout", never "visitors struggle".
//
//  SHEET ONLY, AND THAT IS A DESIGN DECISION. The desktop inline footer has no
//  layers, is always on screen (so nothing ever "appears"), and its free-text
//  field is driven by a PHYSICAL keyboard through a keydown proxy. Measuring it
//  alongside the mobile sheet would glue two unlike populations into one
//  distribution and call the result a number. The inline footer is therefore
//  outside every metric here — `keyboard.osk.used` still covers both, and is
//  deliberately left exactly as it was.
//
//  IT DOES NOT TOUCH THE osk.used : station.key.used RATIO. That pair is what
//  says how much of the gallery's typing goes through the touch keyboard, and
//  it is per KEY PRESS on both sides. Everything here is per EPISODE and
//  declares no probe, so nothing in this file can move that ratio in either
//  direction.
//
//  THE PRIVACY LINE. A visitor typing at a guest may be typing anything,
//  including their own name. Nothing about the CONTENT leaves the tab: not the
//  characters, not how many of them there were, not when each one was pressed.
//  Characters are counted only as the DENOMINATOR of a percentage that is then
//  bucketed into deciles before it is queued, so the count itself never travels
//  and cannot be recovered from what does. If a change to this file would need
//  one more field to make a number better, that is the signal to stop.
//
//  SYNTHETIC INPUT GETS NO CREDIT, and here it gets none by construction: every
//  counter below is driven from the on-screen keyboard's own pointer and input
//  handlers, which the type-in demo and the win9x boot-modal auto-dismiss never
//  call — they talk to the stream control directly. A future demo that drives
//  the OSK programmatically must bracket itself with `withoutHumanCredit` at
//  that call site, exactly as those two already do.
// ============================================================================

import { accumulator, beginFlow, recordMetric, startTiming, type Timing } from '../../analytics';
import type { FlowHandle } from '../../analytics/flows';
import { XK } from '../../three/useStreamControl';
import type { KeyDef } from './keyTypes';

/** The space bar is a `tap` on keysym 0x20 rather than a `char`, so it has to
 *  be named here or every space typed would be missing from the denominator. */
const SPACE_KEYSYM = 0x20;

/** What one on-screen key press DID, for the correction rate.
 *
 *  - `commit`   a character went into the guest (a glyph, or the space bar).
 *  - `correct`  a character was taken back out again (Backspace).
 *  - `other`    a modifier, an arrow, Enter, a macro, a function key. Real
 *               keyboard work, but neither a character nor a correction, so it
 *               belongs in neither half of the rate.
 */
export type KeyEffect = 'commit' | 'correct' | 'other';

export function effectOf(def: Pick<KeyDef, 'action' | 'keysym'>): KeyEffect {
  if (def.action === 'tap' && def.keysym === XK.BackSpace) return 'correct';
  if (def.action === 'char') return 'commit';
  if (def.action === 'tap' && def.keysym === SPACE_KEYSYM) return 'commit';
  return 'other';
}

/**
 * Backspaces as a percentage of characters committed, or null when the episode
 * cannot honestly produce one.
 *
 * NULL, NOT ZERO, WHEN NOTHING WAS TYPED. A visitor who pressed only Backspace
 * — deleting something the guest already had on screen — has a correction rate
 * of "corrections over nothing", and reporting that as any number at all would
 * be inventing one. It is dropped, and the episode is still visible in the
 * `keyboard.compose` funnel as one that never reached `text`.
 *
 * ZERO IS REPORTED. An episode with characters and no corrections is the layout
 * working, and dropping those would leave a distribution made only of the
 * episodes that went badly.
 *
 * OVER 100 IS ALLOWED THROUGH. More deletions than characters typed is a real
 * thing — clearing a field the guest already had text in — and it lands in the
 * `inf` bucket, which says exactly that. Clamping it to 100 would quietly merge
 * it with the merely-terrible episodes.
 */
export function correctionRatePct(corrections: number, commits: number): number | null {
  if (!Number.isFinite(corrections) || !Number.isFinite(commits)) return null;
  if (commits <= 0) return null;
  if (corrections <= 0) return 0;
  return (corrections / commits) * 100;
}

/** One compose episode: the sheet came up, and this is what happened on it. */
export interface ComposeTelemetry {
  /** One on-screen key press. */
  key(def: Pick<KeyDef, 'action' | 'keysym'>): void;
  /** A free-text commit through the device IME proxy: `backspaces` deletions
   *  and `chars` characters. Only the two COUNTS are passed — never the text —
   *  and they exist solely to be the two halves of a bucketed percentage. */
  freeText(backspaces: number, chars: number): void;
  /** The visitor moved between the ABC / ?123 / OS layers. */
  layerSwitch(): void;
  /** The sheet closed or the station session ended. Commits the episode. */
  ended(): void;
}

export function composeTelemetry(): ComposeTelemetry {
  const flow: FlowHandle = beginFlow('keyboard.compose');
  const toFirstKey: Timing = startTiming('keyboard.compose.toFirstKeyMs');
  const layers = accumulator('keyboard.compose.layerSwitches');
  let corrections = 0;
  let commits = 0;
  let anyKey = false;
  let done = false;

  /** The funnel's first two steps, reported off whichever input arrived first —
   *  a grid key or a free-text commit are equally "the visitor typed". */
  const noteKey = () => {
    if (anyKey) return;
    anyKey = true;
    toFirstKey.stop();
    flow.step('firstKey');
  };

  return {
    key(def) {
      noteKey();
      const effect = effectOf(def);
      // A held Backspace or Space is ONE press here and several characters at
      // the guest (keySender's tap-repeat owns the rest), so both halves of the
      // rate undercount a held key. Stated rather than corrected: reaching into
      // the repeat timer to count its ticks would put an instrumentation
      // requirement inside the send path, and the rate is being read as a
      // comparison between layouts rather than as an absolute.
      if (effect === 'correct') corrections += 1;
      if (effect === 'commit') {
        commits += 1;
        flow.step('text');
      }
    },
    freeText(backspaces, chars) {
      if (backspaces > 0 || chars > 0) noteKey();
      if (Number.isFinite(backspaces) && backspaces > 0) corrections += backspaces;
      if (Number.isFinite(chars) && chars > 0) {
        commits += chars;
        flow.step('text');
      }
    },
    layerSwitch() {
      layers.add(1);
    },
    ended() {
      if (done) return;
      done = true;
      // A sheet opened and closed without a key is not a zero-length hunt for
      // the first key; it is an episode with no first key at all.
      toFirstKey.abandon();
      // Zero layer switches is a finding — the visitor found everything on one
      // layer, which is the split working — so this commits either way.
      layers.commit();
      const rate = correctionRatePct(corrections, commits);
      if (rate !== null) recordMetric('keyboard.compose.correctionsPct', rate);
      // An episode that put characters into the guest is one that COMPLETED —
      // that is the whole of what the visitor came to the keyboard to do. One
      // that did not is left to the funnel's drop-off rather than reported as a
      // failure: a keyboard opened and dismissed is an abandonment, and calling
      // it a fault would double-count it (analytics/flows.ts).
      if (commits > 0) flow.ok();
      else flow.close();
    },
  };
}

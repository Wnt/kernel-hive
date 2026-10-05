import type { TypeInConfig } from '../../types';
import { keyboardFor } from '../../data/keyboards';
import {
  DEMO_ENTER_DELAY_MS, DEMO_LINE_DELAY_MS, applyKeyboard, typeLines,
  type DemoTypist, type TypingPace, type TypingProgress,
} from '../grid/StreamView/typeDemoProgram';
import type { DialectSpec } from './basicDialects';
import { transcodeLine, type KeywordMachine } from './keywordEntry';
import { applyCase, withEnterAfter } from './listingText';

// ---------------------------------------------------------------------------
//  typeInRun — one editor run, pure and injectable so Stop and a dropped
//  stream are unit-testable without a live session (useTypeInEditor drives it).
// ---------------------------------------------------------------------------

export type RunOutcome = 'done' | 'stopped' | 'disconnected';

/** The station's declared pace (registry `typeIn`) for THESE lines: demo-typist
 *  defaults for the two optional settles, the longer `settleAfter` settle after
 *  a named direct command (samcoupe: NEW redraws a banner that eats the next
 *  key; the 48K Spectrum's NEW re-tests its memory), and `index` times
 *  `enterDelayPerLineMs` on a machine whose redraw grows with the listing (the
 *  1 KB ZX81). */
export function paceFor(config: TypeInConfig, lines: readonly string[]): TypingPace {
  const enterMs = config.enterDelayMs ?? DEMO_ENTER_DELAY_MS;
  const growth = config.enterDelayPerLineMs ?? 0;
  return {
    perCharMs: config.perCharMs,
    wrapPause: config.wrapPause,
    lineDelayMs: config.lineDelayMs ?? DEMO_LINE_DELAY_MS,
    enterDelayMs: (index) =>
      Math.max(enterMs, config.settleAfter?.[(lines[index] ?? '').trim().toUpperCase()] ?? 0) + index * growth,
  };
}

/** The keystrokes for one listing line on this machine: the station's case
 *  rule first, then its keyboard (charMap / upper-only), as the demo does. */
export function prepareFor(osId: string, config: TypeInConfig, spec: DialectSpec): (line: string) => string {
  const keyboard = keyboardFor(osId);
  return (line) => applyKeyboard(applyCase(line, config.case, spec), keyboard);
}

/** A wait that ends EARLY when `signal` aborts, so Stop never sits out a
 *  600 ms ENTER settle before the run notices. */
export function abortableSleep(signal: AbortSignal): (ms: number) => Promise<void> {
  return (ms) => new Promise<void>((resolve) => {
    if (signal.aborted) { resolve(); return; }
    const timer = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
  });
}

/** `keywords`: a keyword-entry machine's transcoder. Each line then goes in as
 *  key chords (typeChord), never as characters; the editor refuses to start a
 *  listing with transcoder issues, so none is typed half-right. */
export async function typeListing({
  osId, config, spec, keywords, lines, handle, signal, onProgress, sleep = abortableSleep(signal),
}: {
  osId: string;
  config: TypeInConfig;
  spec: DialectSpec;
  keywords?: KeywordMachine;
  lines: readonly string[];
  handle: DemoTypist & { isConnected(): boolean };
  signal: AbortSignal;
  onProgress?: (progress: TypingProgress) => void;
  sleep?: (ms: number) => Promise<void>;
}): Promise<RunOutcome> {
  let dropped = false;
  // Polled before EVERY key: an abort or a closed channel means no further
  // edge leaves typeLines.
  const cancelled = () => {
    if (signal.aborted) return true;
    if (!handle.isConnected()) { dropped = true; return true; }
    return false;
  };
  const chords = keywords ? (line: string) => transcodeLine(line, keywords).chords : undefined;
  // typeIn.enterAfter: a bare ENTER after the named direct commands, paced as
  // its own line (the command keeps its settleAfter, the ENTER the default).
  const typed = withEnterAfter(lines, config.enterAfter);
  const done = await typeLines({
    lines: typed, handle, pace: paceFor(config, typed), prepare: prepareFor(osId, config, spec), chords, sleep, cancelled, onProgress,
  });
  return done ? 'done' : dropped ? 'disconnected' : 'stopped';
}

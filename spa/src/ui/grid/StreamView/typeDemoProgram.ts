import type { DemoProgram, GuestKeyboard } from '../../../types';

// ---------------------------------------------------------------------------
//  typeDemoProgram — key a registry type-in listing into the live guest.
//
//  Delivery reuses the SAME path as the on-screen keyboard's paste:
//  StreamControlHandle.typeText(), i.e. per-character set1 scancodes (ASCII
//  only, which is all a BASIC listing needs — see three/guestQuirks.ts).
//
//  Two deliberate properties:
//   - ONE LINE PER CALL, with a pause between them, so the guest's editor gets
//     the listing a line at a time and it reads as a person typing — which is
//     the point of the exhibit. This is a PRESENTATION pace only: per-KEY timing
//     (minimum hold/gap so an emulator sampling its input ports once per emulated
//     frame actually observes each press) is streamhost's responsibility, in
//     streamhost/src/input.rs — never something to compensate for here.
//   - THE RUN COMMAND IS TYPED WITHOUT ITS NEWLINE. Starting the program is the
//     visitor's act, not ours; they press ENTER themselves.
//
//  Pure and injectable (handle/sleep/cancel) so it is unit-testable without a
//  live stream.
// ---------------------------------------------------------------------------

/** Pause between typed lines. Slow enough for an 8-bit editor, brisk enough to
 *  watch. */
export const DEMO_LINE_DELAY_MS = 260;

/**
 * Milliseconds a single character takes to REACH the guest.
 *
 * streamhost paces keys per station (SH_KEY_MIN_HOLD_MS + SH_KEY_MIN_GAP_MS) so an
 * emulator sampling its input ports once per emulated frame actually observes
 * every press -- on mpf2 that is 32 + 32, i.e. ~64 ms per character. typeText()
 * returns immediately and the daemon drains the queue at that rate, so a line
 * of 25 characters is still arriving ~1.6 s later. Waiting a FIXED time between
 * lines therefore submits faster than the guest can consume, the backlog grows,
 * and characters are lost -- seen as the first digit of a line number going
 * missing partway down a listing. Scale the wait by line length instead.
 *
 * This is only the DEFAULT. A station whose drain rate exceeds it declares its own
 * `demoProgram.perCharMs` in the registry (vic20 paces 80+80, so 170), and
 * `validate_demo_pacing` in scripts/stations-registry.py fails the build if the
 * value that applies is below that station's hold+gap.
 */
export const DEMO_PER_CHAR_MS = 70;

/** Extra settle after the ENTER that commits a line. An 8-bit BASIC tokenises
 *  the line it just received, and while it does its keyboard buffer can miss
 *  the next character — observed as the first digit of the following line
 *  number going missing. Longer than DEMO_LINE_DELAY_MS on purpose. */
export const DEMO_ENTER_DELAY_MS = 600;

/**
 * Rewrite a listing into the host keystrokes that produce it on this machine.
 *
 * typeText() maps ASCII to US set1 scancodes, so a character only survives where
 * the guest's matrix agrees with a US keyboard. The MPF-II puts '=' on Shift+O
 * and '-' on Shift+I -- a PC's own '=' and '-' keys are absent from its matrix,
 * so untranslated those characters simply VANISH -- and its shifted number row
 * is offset by one, landing every bracket a key over. The corruption reads like
 * dropped keystrokes, which sends you hunting a timing bug that is not there.
 *
 * `letterCase: 'upper-only'` is the other half: on such a machine the shifted
 * letter row is punctuation, so an upper-case letter must be sent UNSHIFTED.
 * Expressed as a flag rather than 26 charMap entries.
 *
 * Declared per station in the registry `keyboard` block; derive one with
 * scripts/dev/mame-keymap.py.
 */
export function applyKeyboard(text: string, kb?: GuestKeyboard): string {
  if (!kb) return text;
  let out = '';
  for (const ch of text) {
    const c = kb.letterCase === 'upper-only' && ch >= 'A' && ch <= 'Z' ? ch.toLowerCase() : ch;
    out += kb.charMap?.[c] ?? c;
  }
  return out;
}

export interface DemoTypist {
  typeText(text: string): void;
}

const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function typeDemoProgram({
  program,
  handle,
  keyboard,
  delayMs = DEMO_LINE_DELAY_MS,
  perCharMs = DEMO_PER_CHAR_MS,
  enterDelayMs = DEMO_ENTER_DELAY_MS,
  sleep = wait,
  cancelled = () => false,
}: {
  program: DemoProgram;
  handle: DemoTypist;
  keyboard?: GuestKeyboard;
  delayMs?: number;
  perCharMs?: number;
  enterDelayMs?: number;
  sleep?: (ms: number) => Promise<void>;
  cancelled?: () => boolean;
}): Promise<boolean> {
  // The station's own drain rate wins over the fleet default; an explicit caller
  // argument (tests) still wins over both.
  const charMs = perCharMs === DEMO_PER_CHAR_MS ? (program.perCharMs ?? perCharMs) : perCharMs;
  for (const line of program.lines) {
    if (cancelled()) return false;
    // An EMPTY line is a bare ENTER: nothing to type, so no per-line pace
    // either -- the ENTER below is the whole line. bootOS's `enter` command
    // reads hex lines until it gets one, and the registry validator admits
    // exactly '' for it (never whitespace, which would type as nothing but
    // read as content).
    if (line.length > 0) {
      handle.typeText(applyKeyboard(line, keyboard));
      // Long enough for the whole line to have actually reached the guest.
      await sleep(Math.max(delayMs, line.length * charMs));
      if (cancelled()) return false;
    }
    // ENTER commits the line; give the guest time to tokenise it before the
    // next character arrives.
    handle.typeText('\n');
    await sleep(enterDelayMs);
  }
  if (cancelled()) return false;
  // No newline: the visitor supplies it.
  handle.typeText(applyKeyboard(program.runCommand, keyboard));
  await sleep(program.runCommand.length * charMs);
  return true;
}

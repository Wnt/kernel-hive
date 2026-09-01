// ============================================================================
//  analytics/errors — grouping, so a thousand of the same fault is one row.
//  ---------------------------------------------------------------------------
//  /clientlog already stores every error verbatim, with the stack, and that is
//  the right thing for DEBUGGING one session. It is the wrong thing for
//  DECIDING what to fix: an operator reading a rolling JSONL cannot tell that
//  one broken station accounts for four fifths of the day's exceptions, because
//  each occurrence looks like a fresh disaster. So this plane keeps the counts
//  and lets clientlog keep the evidence — the fingerprint is printed into both,
//  which is how you get from "this is the top error" back to a real stack.
//
//  THE FINGERPRINT. Message plus the first stack frame, with everything
//  session-specific scrubbed out: numbers, hex, uuids, urls and query strings.
//  Two things follow from that choice, both deliberate:
//    - `Failed to fetch https://<host>/signal/beos.json` and the same for
//      `irix` collapse into ONE row. That is what you want when asking "is
//      signalling broken", and the per-station breakdown you then want comes
//      from the flow the error was attributed to, not from the message.
//    - a message that is nothing but numbers degenerates to a near-empty
//      fingerprint, so the source is always mixed in.
//
//  NO STACK IN THE COUNTER ROW — because a counter row is a COUNT, not because
//  a stack is unwelcome. This lane's durable table is keyed by
//  (day, fingerprint, flow, step, class) and holds an `n`; a stack is per
//  occurrence and would have nowhere to live in it that was not a lie about
//  which occurrence it came from. So the stack goes where per-occurrence data
//  goes: onto the TRACE, as the OTel `exception` event this function also
//  writes (since 2026-09-01 it carries `exception.stacktrace` in full), and
//  into /clientlog. The fingerprint is printed into all three, which is how an
//  operator gets from "this is the top error" to a real stack in one hop.
//
//  Until 2026-09-01 this header read "NEVER THE STACK, NEVER THE URL" as a
//  privacy rule covering the whole plane, and the trace lane obeyed it. That
//  was an AI-invented constraint, not an operator one, and it is gone;
//  docs/ANALYTICS.md §0 is the policy. Instana, which captures stack and page
//  URL by its own default, is now consistent with our own planes rather than
//  the exception it used to be described as.
// ============================================================================

import { currentFlow } from './flows';
import { queueError } from './sink';
import { currentSpan } from './trace';

/** How much of a message survives into the durable aggregate. Enough to
 *  recognise the fault, not enough to be a log. */
const MESSAGE_MAX = 200;

/** Everything that makes two occurrences of one fault look different. */
const VOLATILE = [
  /\bhttps?:\/\/\S+/gi,       // urls (and with them, station ids and tokens)
  /\b0x[0-9a-f]+\b/gi,        // hex
  /\b[0-9a-f]{8}-[0-9a-f-]{27,}\b/gi, // uuids
  /\b\d+\b/g,                 // any number: line numbers, sizes, timestamps
];

/** A short stable hash. djb2 — not cryptographic, and does not need to be:
 *  a collision costs two faults sharing a row in a private lab's report. */
function hash(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i += 1) h = (((h << 5) + h) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(16).padStart(8, '0');
}

/** The first frame of a stack, normalised, or '' when there is none. */
function topFrame(stack: string): string {
  const line = stack.split('\n').find((l) => /\bat\b|@/.test(l));
  return line ? line.trim().slice(0, 160) : '';
}

/** Group key for one fault. Exported for the tests and for printing into the
 *  /clientlog record, which is how an operator gets from a count to a stack. */
export function fingerprint(message: string, source: string, stack = ''): string {
  let key = `${source}|${message}|${topFrame(stack)}`;
  for (const re of VOLATILE) key = key.replace(re, '#');
  return hash(key);
}

/** Record one error against whichever flow was open when it happened. */
export function reportError(input: {
  message: string;
  source: string;
  stack?: string;
}): string {
  const fp = fingerprint(input.message, input.source, input.stack ?? '');
  try {
    // Also onto the open span, as an OTel `exception` event. That is what turns
    // "this fingerprint happened 40 times" into "open one of them and see the
    // journey it happened inside", which is the entire point of the trace lane.
    // The fingerprint travels with it, so the grouped count and the individual
    // trace are joinable in both directions.
    const span = currentSpan();
    if (span) {
      const stack = input.stack ?? '';
      span.event('exception', {
        'exception.type': input.source,
        // NOT clipped to MESSAGE_MAX here: that cap belongs to the durable
        // COUNTER row below, where one message stands for every occurrence in
        // a day. The span records one occurrence and can afford the whole
        // thing (`trace.ts` LONG_ATTRS, `traces.py` ATTR_STR_MAX_LONG).
        'exception.message': String(input.message ?? ''),
        ...(stack ? { 'exception.stacktrace': stack } : {}),
        'kh.fingerprint': fp,
      });
      span.attr('error.type', input.source);
    }
    const flow = currentFlow();
    queueError({
      fp,
      message: String(input.message ?? '').slice(0, MESSAGE_MAX),
      source: input.source,
      flow: flow?.flow,
      step: flow?.step,
    });
  } catch { /* an error in the error path must not raise a second one */ }
  return fp;
}

let installed = false;

/** Catch the two faults nothing else in the app has a handler for. React render
 *  errors arrive through the boundary in main.tsx instead, which knows the
 *  component stack. */
export function installErrorCapture(): void {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  try {
    window.addEventListener('error', (e: ErrorEvent) => {
      reportError({
        message: e.message || 'window error',
        source: 'window',
        stack: e.error instanceof Error ? (e.error.stack ?? '') : '',
      });
    });
    window.addEventListener('unhandledrejection', (e: PromiseRejectionEvent) => {
      const r: unknown = e.reason;
      reportError({
        message: r instanceof Error ? r.message : String(r ?? 'unhandled rejection'),
        source: 'promise',
        stack: r instanceof Error ? (r.stack ?? '') : '',
      });
    });
  } catch { /* no capture is worse than capture, but not worth a crash */ }
}

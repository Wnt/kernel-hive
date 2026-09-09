// ============================================================================
//  analytics/beacon — the ONE way this tab uploads telemetry, and the 64 KiB
//  budget that made every other way lose data.
//  ---------------------------------------------------------------------------
//  THE BUG THIS FILE EXISTS FOR, measured on the live gallery 2026-09-01.
//
//  Six senders in this app posted their batches with `keepalive: true`,
//  unconditionally, on every flush: `/traces` (analytics/index.ts), `/analytics`
//  (sink.ts), `/logs` (logSink.ts), `/clientlog` (three/clientDebug.ts),
//  `/usage` (three/usageStats.ts) and `/coverage` (coverage.ts). `keepalive` was
//  chosen for one real reason — the LAST batch of a visit has to outlive the
//  tab — and then applied to all the others for free.
//
//  It is not free. A document gets ONE 64 KiB keepalive allowance, and in
//  Chrome it is not returned when the request finishes: it is spent for the
//  life of the document. Probed against the real gallery in Chrome 150 (the
//  browser this wall serves), posting 4 KiB keepalive bodies to `/traces`:
//
//      15 succeed  ->  the 16th rejects `TypeError: Failed to fetch`
//      every later keepalive fetch rejects IMMEDIATELY, forever
//      a plain (non-keepalive) fetch to the same URL still succeeds, 20/20
//
//  ~61 KiB, and the tab's telemetry is over. Every sender swallows the
//  rejection in a `.catch(() => {})`, so nothing is logged, nothing is retried,
//  and the access log shows the tab still healthy — `/clientcmd` polling every
//  five seconds, the vendor's `/eum` beacons flowing — while `/traces`,
//  `/analytics`, `/clientlog` and `/logs` all stop in the same second and never
//  resume. Both of those routes read their response bodies; ours did not, and
//  neither did they draw on the keepalive budget.
//
//  That is the whole of the orphaned-span problem the trace plane had. The
//  daemon's spans for a sampled input edge travel on a completely independent
//  path and keep arriving; the browser's `input.edge` — the ROOT of that trace
//  — was destroyed in the tab, because `flushSpans()` drains its buffer BEFORE
//  the POST and the failure path threw the batch away. Measured over 24 h:
//  175 of 459 `input.dispatch` spans (38%) named a parent the store never had,
//  in long unbroken runs that start mid-session and never recover, plus whole
//  sessions with 81 daemon spans and not one browser span of any kind.
//
//  THE RULE, and it is the only thing this module enforces:
//
//    **`keepalive` is for the LAST batch of a visit and nothing else.**
//
//  A flush on the interval is an ordinary fetch: it has a live document to
//  complete in, it costs nothing from the budget, and it can be retried. A
//  flush from `pagehide` (or `visibilitychange` -> hidden, which is the only
//  thing iOS Safari reliably gives) is the one that must outlive the tab, and
//  it is the only one that spends the allowance. A visit now spends a handful
//  of KiB at the end rather than exhausting the budget in its first two
//  minutes.
//
//  AND THE RESPONSE BODY IS ALWAYS CONSUMED. Not politeness: an undrained
//  response holds its allocation open, which is what turned a per-request
//  budget into a per-document one. `void fetch(...)` is banned here for that
//  reason.
// ============================================================================

/**
 * What happened to one telemetry upload, in the three flavours a caller
 * genuinely treats differently:
 *
 *  - `sent`     — the server answered 2xx. The batch is delivered; drop it.
 *  - `refused`  — the server answered, and said no (401 signed-out, 413 too
 *                 big, a plane that is switched off). A SETTLED answer: drop
 *                 the batch. Re-queueing a refusal is how one lost row becomes
 *                 an unbounded queue of them, which is the rule `sink.ts` has
 *                 always stated.
 *  - `failed`   — no answer at all: the box is unreachable, the link died, or
 *                 the keepalive budget above is gone. KEEP THE BATCH and try
 *                 again on the next flush.
 */
export type BeaconResult = 'sent' | 'refused' | 'failed';

/** How a flush was reached. `final` is `pagehide`/hidden — the one flush that
 *  has to survive the document, and therefore the only one allowed to spend
 *  the keepalive allowance. */
export interface BeaconOpts {
  final?: boolean;
  headers?: Record<string, string>;
  credentials?: RequestCredentials;
}

/** Send one telemetry batch. Never throws; never leaves a response body
 *  undrained; only spends the keepalive budget on a final flush. */
export async function postTelemetry(
  url: string,
  body: string,
  opts: BeaconOpts = {},
): Promise<BeaconResult> {
  try {
    const res = await fetch(url, {
      method: 'POST',
      // THE WHOLE POINT — see the module header.
      keepalive: opts.final === true,
      credentials: opts.credentials ?? 'same-origin',
      headers: { 'Content-Type': 'application/json', ...(opts.headers ?? {}) },
      body,
    });
    // Drain, always. An unread body holds its allocation, and the allocation
    // is the resource this module exists to stop leaking.
    try {
      await res.text();
    } catch { /* a body we could not read is still a body we asked for */ }
    return res.ok ? 'sent' : 'refused';
  } catch {
    return 'failed';
  }
}

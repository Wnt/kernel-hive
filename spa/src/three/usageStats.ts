// ============================================================================
//  usageStats — how much each station gets used, and by whom.
//  ---------------------------------------------------------------------------
//  WHY THE COUNTING IS HERE. The input plane goes straight from this tab to the
//  station's QUIC listener; the gallery server never sees a click, and the
//  ticket that gates the stream carries a station and an expiry but no identity.
//  So the only place that knows BOTH "a button went down" and "whose cookie this
//  tab holds" is the tab, and the count is reported to the server rather than
//  observed by it. These are therefore a visitor's own account of what they did:
//  right for a scoreboard, wrong for anything that has to be true.
//
//  WHAT COUNTS AS ONE. A press, not a press and its release: countClick and
//  countKeystroke are called on the DOWN edge only (streamClient/inputWire), so
//  the numbers are acts, not wire events. Auto-repeat is left in — a held key
//  really is sending keystrokes to the guest — and the wheel and pointer motion
//  are left out.
//
//  WHY IT BATCHES. A click is 20 bytes of intent; a request per click would be
//  a request per click. Tallies are folded per station and flushed on a timer,
//  and again when the page goes away, where `keepalive` is what lets the last
//  batch outlive the tab (sendBeacon cannot, since it would omit the Origin the
//  server insists on).
// ============================================================================

import { activeDebugTile } from './clientDebug';

/** Flush cadence. Long enough that a busy session is a handful of requests, short
 *  enough that a tab closed by force loses only a few seconds of counting. */
const FLUSH_MS = 20_000;
/** Mirrors serve/usage.py MAX_EDGES_PER_REPORT: the server clamps a single
 *  report to this, so sending more would silently discard the excess. A tab that
 *  has been offline long enough to hit this stops accumulating instead. */
const MAX_EDGES = 5000;
/** Mirrors serve/usage.py MAX_STATIONS_PER_REPORT. */
const MAX_TILES = 32;

/** Set-1 make codes for the modifier keys, which are NOT counted as keystrokes.
 *  Two reasons, and the second is the load-bearing one: nobody thinks of holding
 *  Shift as "a keystroke", and the char path SYNTHESISES a Shift press around
 *  every shifted character (useStreamControl sendCharEvent), so counting them
 *  would make a capital letter worth twice a lowercase one. */
const MODIFIER_SCANCODES = new Set([
  0x2a, 0x36,          // Shift L / R
  0x1d, 0xe01d,        // Ctrl L / R
  0x38, 0xe038,        // Alt L / AltGr
  0xe05b, 0xe05c,      // Meta/Super L / R
  0x3a,                // Caps Lock
]);

interface Tally { clicks: number; keys: number }

let pending = new Map<string, Tally>();
let flushTimer = 0;
let hooked = false;
/** Depth of the synthetic-input bracket (see withSyntheticInput). */
let synthetic = 0;

function bump(field: keyof Tally): void {
  try {
    if (synthetic > 0) return;
    const tile = activeDebugTile();
    if (!tile) return; // an edge with no station open belongs to no machine
    let tally = pending.get(tile);
    if (!tally) {
      if (pending.size >= MAX_TILES) return;
      tally = { clicks: 0, keys: 0 };
      pending.set(tile, tally);
    }
    if (tally[field] >= MAX_EDGES) return;
    tally[field] += 1;
    ensureTimer();
  } catch { /* counting must never break the app */ }
}

/** One mouse/touch/pen button press on the open station. */
export function countClick(): void { bump('clicks'); }

/** One key press on the open station. Modifiers do not count — see
 *  MODIFIER_SCANCODES. */
export function countKeystroke(scancode: number): void {
  if (MODIFIER_SCANCODES.has(scancode)) return;
  bump('keys');
}

/** Run `fn` with counting suppressed, for input the SOFTWARE is generating.
 *
 *  A type-in demo puts hundreds of key edges on the wire from one click, and the
 *  win9x boot-modal dismissal types Esc and Enter on every single connect with
 *  nobody touching anything. Counted, either would drown out what people
 *  actually did — the demo would make its runner the most industrious visitor in
 *  the gallery, and the auto-dismiss would give every passive viewer two
 *  keystrokes per station they merely looked at. The click that STARTED a demo
 *  is the act, and it is counted where it happens. */
export function withSyntheticInput<T>(fn: () => T): T {
  synthetic += 1;
  try {
    return fn();
  } finally {
    synthetic -= 1;
  }
}

function ensureTimer(): void {
  if (typeof window === 'undefined') return;
  if (!hooked) {
    hooked = true;
    try {
      // Both, deliberately: pagehide is the reliable one on desktop, and iOS
      // Safari can go straight to hidden and never fire it.
      window.addEventListener('pagehide', () => flushUsage());
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') flushUsage();
      });
    } catch { /* noop */ }
  }
  if (!flushTimer) flushTimer = window.setInterval(() => flushUsage(), FLUSH_MS);
}

/** Send what has been counted so far. A failed send folds the tally back in, so
 *  a box that is briefly unreachable costs nothing but a delay. */
export function flushUsage(): void {
  try {
    if (!pending.size) return;
    const batch = pending;
    pending = new Map();
    const stations: Record<string, Tally> = {};
    for (const [tile, tally] of batch) stations[tile] = tally;
    void fetch('/usage', {
      method: 'POST',
      keepalive: true,
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ stations }),
      // Only a NETWORK failure folds the batch back. An HTTP refusal (a
      // signed-out tab, a deployment with no counter plane) is a settled
      // answer, and retrying it forever would turn one lost tally into an
      // unbounded queue of them.
    }).catch(() => { foldBack(batch); });
  } catch { /* never throw */ }
}

function foldBack(batch: Map<string, Tally>): void {
  for (const [tile, tally] of batch) {
    const cur = pending.get(tile);
    if (!cur) {
      if (pending.size >= MAX_TILES) continue;
      pending.set(tile, tally);
      continue;
    }
    cur.clicks = Math.min(MAX_EDGES, cur.clicks + tally.clicks);
    cur.keys = Math.min(MAX_EDGES, cur.keys + tally.keys);
  }
}

/** Test seam: what is counted but not yet sent. */
export function __usageTallies(): Record<string, Tally> {
  const out: Record<string, Tally> = {};
  for (const [tile, tally] of pending) out[tile] = { ...tally };
  return out;
}

/** Test seam: start from nothing, timer included. */
export function __usageReset(): void {
  pending = new Map();
  if (flushTimer) { clearInterval(flushTimer); flushTimer = 0; }
  hooked = false;
}

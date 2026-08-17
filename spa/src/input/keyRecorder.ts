// ============================================================================
//  input/keyRecorder — raw key-edge capture, in the bundle, behind a flag.
//  ---------------------------------------------------------------------------
//  The keyboard-lag investigation (sinclairql/vic20, 2026-08-17) needs the
//  browser's own send timing as evidence: WHEN each key edge left the client,
//  so the daemon's `[key-tel] recv` line and the emulator module's pacing queue
//  can be measured against it, and so a real typing burst can be REPLAYED
//  against candidate pacing knobs (scripts/dev/key-replay.py). Synthetic bursts
//  don't cut it — overlapping, browser-timed key edges expose defects socket
//  bursts never will (docs/lab/INPUT-DEBUGGING.md, the pen-recorder lesson).
//
//  Same shape as input/pointerRecorder: capped ring for live poking, periodic
//  push of packed rows to /clientlog as `key` telemetry events. It records at
//  the WIRE choke point (streamClient.sendKeyScancode) rather than a DOM
//  listener, so the on-screen keyboard, typeText's synthetic Shift chords and
//  the physical-keyboard forwarder are all captured exactly as sent.
//
//  ARMED BY DEFAULT while the keyboard-lag investigation is open, so a
//  reproduction is never lost to an unarmed tab. **Flip DEFAULT_ON back to
//  false when the investigation closes**; the switches below then arm it
//  per-session:
//    * `window.__osgKeyRec = true` in the tab (or the operator eval plane), or
//    * `?keyrec=1` on the URL (survives the reload it is on).
//  Either also works as an OPT-OUT while the default stands: `= false`/`?keyrec=0`.
//
//  TWO CLOCKS PER ROW: `now` (performance.now()) orders edges within the
//  session at monotonic precision for replay; `ep` (Date.now()) is the only
//  clock that can be laid next to server-side lines at all — though the
//  browser's wall clock is NOT labhost's, so cross-machine deltas are for
//  ordering, not measurement. Decode with scripts/serve/key-trace.py.
// ============================================================================

import { logClientEvent } from '../three/clientDebug';

/** One key edge as it went on the wire. Short names: rows travel packed. */
interface KeyRecRow {
  /** 'd' down, 'u' up */
  t: string;
  /** performance.now() at the send call — the replay clock. */
  now: number;
  /** Date.now() at the send call — the (skewed) correlation clock. */
  ep: number;
  /** XT set-1 wire scancode, exactly the u16 of the type=3 record. */
  code: number;
}

const RING_CAP = 400;
/** Push cadence — long enough to pack a burst, short enough that a repro
 *  reaches labhost while the visitor is still describing it. */
const PUSH_MS = 2000;
/** Rows per telemetry event: a packed row is ~30 chars, `detail` caps at 512. */
const ROWS_PER_EVENT = 15;

let ring: KeyRecRow[] = [];
let unsent: KeyRecRow[] = [];
let pushTimer = 0;

/** Armed unless something turns it off — see the header. Temporary: `true`
 *  only while the keyboard-lag work is open. */
const DEFAULT_ON = true;

/** True when capture is armed. Read live so the flag flips in a running tab
 *  without a reload. An explicit setting wins over the default, both ways. */
function keyRecorderOn(): boolean {
  if (typeof window === 'undefined') return false;
  const w = window as unknown as { __osgKeyRec?: unknown };
  if (typeof w.__osgKeyRec === 'boolean') return w.__osgKeyRec;
  try {
    const q = new URLSearchParams(window.location.search).get('keyrec');
    if (q === '1') return true;
    if (q === '0') return false;
  } catch { /* no location */ }
  return DEFAULT_ON;
}

/** One row as `t,now,ep,code` — code in hex to match every server-side line. */
function pack(r: KeyRecRow): string {
  return `${r.t},${r.now},${r.ep},${r.code.toString(16)}`;
}

/** Ship what has been captured since the last push, split under the 512 cap. */
function pushBatch(): void {
  if (!unsent.length) return;
  const rows = unsent;
  unsent = [];
  for (let i = 0; i < rows.length; i += ROWS_PER_EVENT) {
    logClientEvent('key', rows.slice(i, i + ROWS_PER_EVENT).map(pack).join(';'));
  }
}

function ensurePushTimer(): void {
  if (pushTimer || typeof window === 'undefined') return;
  pushTimer = window.setInterval(pushBatch, PUSH_MS);
}

/** Record one key edge exactly as it goes on the wire. Called from
 *  streamClient.sendKeyScancode; cheap while disarmed (one boolean read). */
export function recordKeyEdge(code: number, down: boolean): void {
  if (!keyRecorderOn()) return;
  const row: KeyRecRow = {
    t: down ? 'd' : 'u',
    now: Math.round(performance.now()),
    ep: Date.now(),
    code: code & 0xffff,
  };
  // Queue for labhost FIRST — the push is the durable record, the ring is
  // for live poking through the operator plane.
  unsent.push(row);
  if (unsent.length > RING_CAP) unsent.shift();
  ensurePushTimer();
  ring.push(row);
  if (ring.length > RING_CAP) ring.shift();
}

/** Everything captured, as a JSON string (what the operator plane returns). */
function keyRecorderDump(): string {
  return JSON.stringify({ on: keyRecorderOn(), keys: ring });
}

/** Drop the buffer — call before a labelled reproduction so the capture
 *  contains that burst and nothing else. */
function keyRecorderReset(): void {
  ring = [];
}

declare global {
  interface Window {
    /** Live capture switch + readers, exposed for the operator eval plane. */
    __osgKeyRec?: boolean;
    keyRecorderDump?: () => string;
    keyRecorderReset?: () => void;
  }
}

/** Expose the readers on `window` so the operator plane can call them by name. */
export function exposeKeyRecorder(): void {
  if (typeof window === 'undefined') return;
  window.keyRecorderDump = keyRecorderDump;
  window.keyRecorderReset = keyRecorderReset;
}

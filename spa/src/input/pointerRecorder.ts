// ============================================================================
//  input/pointerRecorder — raw pointer capture, in the bundle, behind a flag.
//  ---------------------------------------------------------------------------
//  Input bugs on a stylus cannot be reproduced synthetically: a real hand wobbles
//  and Chrome-Android synthesizes events with timings no probe reproduces (see
//  input/penRightClick for one that cost a whole round of fixes). So the raw
//  event stream from the visitor's OWN device is the primary evidence, and this
//  is the thing that captures it.
//
//  It used to be a snippet injected through the operator eval plane, which meant
//  it died on every reload — and each reload is exactly what a client-side fix
//  requires, so debugging cost a re-arm round trip per iteration. It lives in the
//  bundle now and needs no arming step at all.
//
//  ARMED BY DEFAULT while the pen-input investigation is open (2026-08-05), so a
//  reproduction is never lost to an unarmed tab. It costs two capped rings and a
//  rounded read per event, and it sends NOTHING on its own — the buffers are only
//  read when someone asks. **Flip DEFAULT_ON back to false when the investigation
//  closes**; the switches below then arm it per-session:
//
//    * `window.__osgPenRec = true` in the tab (or via the operator eval plane), or
//    * `?penrec=1` on the URL, which survives the reload it is on.
//
//  Either switch also works as an OPT-OUT while the default stands: `= false`, or
//  `?penrec=0`.
//
//  MOUSE ROWS are dropped by default (a mouse would drown the pen rings). The
//  relative-pointer bridge work (docs/lab/research/rel-pointer-rehome-and-rate-cap.md)
//  needs them: `?ptrrec=1` (or `window.__osgPtrRec = true`) keeps mouse rows AND
//  adds one `w` (wire) row per absolute move datagram — the MAPPED guest
//  coordinates and the wire `cseq`, which is exactly what the daemon's
//  `[input-tel rel] cseq=…` lines carry, so the two logs join row for row.
//
//  IT PUSHES, so nobody has to ask. Every ~2 s the captured rows are packed into
//  `ptr` telemetry events and POSTed to /clientlog like any other client event,
//  where the server keeps them in its rotating log. That means a reproduction is
//  recorded even if the phone is in a pocket and the tab is in the background —
//  the operator eval plane needs a FOREGROUND tab to answer its poll, so every
//  earlier round of this investigation required the user to hold their phone
//  awake and me to ask for each capture. Decode a session with
//    scripts/serve/pen-trace.py [--session ID] [--since-min 15]
//
//  The in-memory rings remain, and `penRecorderDump()` still reads them through
//  the operator plane (`OSG_ADMIN_EVAL=1 clientcmd.sh eval <session> "return
//  penRecorderDump()"`, and note the harness wraps code as an async function
//  body, so `return`). That path stays for live poking at a running tab.
//  Full workflow: docs/lab/INPUT-DEBUGGING.md.
//
//  TWO CLOCKS PER ROW, and the reason is the bug above: a contextmenu
//  synthesized from a long-press carries the SOURCE pointerdown's `timeStamp`,
//  so an event-stamp delta reads 0 ms across a three-second hold. `now` is
//  performance.now() read inside the handler — the only clock that says when the
//  event actually arrived. A recorder that logged one clock could not have shown
//  this, and did not.
//
//  TWO RINGS, for the same kind of reason: a hovering stylus emits ~30 moves a
//  second, which evicted every contact and contextmenu from a single shared
//  buffer and left one usable row in a live capture. Contacts are what the
//  decisions turn on, so they get a ring the move stream cannot flood.
// ============================================================================

/** One event. Short field names because the whole buffer travels as one JSON
 *  string through the telemetry batch. */
interface PointerRecRow {
  /** d=down u=up c=cancel m=move X=contextmenu A=auxclick */
  t: string;
  /** The event's own timeStamp — NOT trustworthy for synthesized events. */
  ts: number;
  /** performance.now() read in the handler: when this actually arrived. */
  now: number;
  /** 'p'=pen 't'=touch 'm'=mouse '-'=not a pointer event; 'g' = a wire row
   *  (t='w'): x,y are GUEST coordinates and btn carries the wire cseq. */
  pt: string;
  btn: number;
  x: number;
  y: number;
}

import { logClientEvent } from '../three/clientDebug';

const CONTACT_CAP = 200;
const MOVE_CAP = 300;
/** Push cadence. Short enough that a gesture reaches labhost while the user is
 *  still describing it, long enough to pack many rows per request. */
const PUSH_MS = 2000;
/** Rows per telemetry event. `detail` is capped at 512 chars server-side and a
 *  packed row is ~22, so this stays comfortably inside one record. */
const ROWS_PER_EVENT = 20;

let contacts: PointerRecRow[] = [];
let moves: PointerRecRow[] = [];
let installed = false;
/** Rows captured since the last push, in arrival order (contacts and moves
 *  interleaved — the ORDER between them is what most of these bugs turn on). */
let unsent: PointerRecRow[] = [];
let pushTimer = 0;

/** Armed unless something turns it off — see the header. Temporary: this is
 *  `true` only while the pen-input work is open. */
const DEFAULT_ON = true;

/** True when capture is armed. Read live so the flag can be flipped in a running
 *  tab (`window.__osgPenRec = …`) without a reload or a rebuild. An explicit
 *  setting always wins over the default, in both directions. */
function penRecorderOn(): boolean {
  if (typeof window === 'undefined') return false;
  const w = window as unknown as { __osgPenRec?: unknown };
  if (typeof w.__osgPenRec === 'boolean') return w.__osgPenRec;
  try {
    const q = new URLSearchParams(window.location.search).get('penrec');
    if (q === '1') return true;
    if (q === '0') return false;
  } catch { /* no location */ }
  return DEFAULT_ON;
}

/** Mouse + wire rows: an explicit opt-in per tab (never on by default — a
 *  mouse at 60-120 Hz for minutes is fine for the rotating clientlog, but only
 *  when someone asked for it). */
function ptrRecOn(): boolean {
  if (typeof window === 'undefined') return false;
  const w = window as unknown as { __osgPtrRec?: unknown };
  if (typeof w.__osgPtrRec === 'boolean') return w.__osgPtrRec;
  try {
    return new URLSearchParams(window.location.search).get('ptrrec') === '1';
  } catch { return false; }
}

/** One absolute move as it went on the wire (inputWire.sendMoveAbs): the mapped
 *  guest point and its `cseq`. Only recorded under the `ptrrec` switch. */
export function recordWireMove(gx: number, gy: number, cseq: number): void {
  if (!ptrRecOn()) return;
  push({ t: 'w', ts: 0, now: Math.round(performance.now()), pt: 'g', btn: cseq >>> 0, x: gx, y: gy });
}

/** One row as a compact string: `t,now,pt,btn,x,y`. Packed rather than JSON
 *  because 20 of these fit in one 512-char `detail` where 4 JSON objects would. */
function pack(r: PointerRecRow): string {
  return `${r.t},${r.now},${r.pt},${r.btn},${r.x},${r.y}`;
}

/** Ship what has been captured since the last push. Split across events so no
 *  single `detail` is truncated by the server's 512-char cap. */
function pushBatch(): void {
  if (!unsent.length) return;
  const rows = unsent;
  unsent = [];
  for (let i = 0; i < rows.length; i += ROWS_PER_EVENT) {
    logClientEvent('ptr', rows.slice(i, i + ROWS_PER_EVENT).map(pack).join(';'));
  }
}

function ensurePushTimer(): void {
  if (pushTimer || typeof window === 'undefined') return;
  pushTimer = window.setInterval(pushBatch, PUSH_MS);
}

function push(row: PointerRecRow): void {
  // Queue for labhost FIRST, so a row is shipped even if the ring later evicts
  // it — the rings are for live poking, the push is the durable record.
  unsent.push(row);
  if (unsent.length > CONTACT_CAP + MOVE_CAP) unsent.shift();
  ensurePushTimer();
  if (row.t === 'm') {
    moves.push(row);
    if (moves.length > MOVE_CAP) moves.shift();
    return;
  }
  contacts.push(row);
  if (contacts.length > CONTACT_CAP) contacts.shift();
}

const TAG: Record<string, string> = {
  pointerdown: 'd', pointerup: 'u', pointercancel: 'c', pointermove: 'm',
  contextmenu: 'X', auxclick: 'A',
};

/** Install the capture listeners once, in the CAPTURE phase so they see events
 *  the app will preventDefault or stopPropagation. Cheap while disarmed: the
 *  handler reads one boolean and returns. */
export function installPointerRecorder(): void {
  if (installed || typeof window === 'undefined') return;
  installed = true;
  const on = (e: Event) => {
    const mouseToo = ptrRecOn();
    if (!penRecorderOn() && !mouseToo) return;
    const p = e as PointerEvent;
    const t = TAG[e.type];
    if (!t) return;
    // Pen and touch only for pointer events; a mouse would drown the ring and is
    // not what these bugs are about — unless the `ptrrec` switch asked for it.
    // contextmenu/auxclick have no pointerType.
    if (p.pointerType && p.pointerType !== 'pen' && p.pointerType !== 'touch' && !mouseToo) return;
    push({
      t,
      ts: Math.round(p.timeStamp),
      now: Math.round(performance.now()),
      pt: p.pointerType ? p.pointerType[0] : '-',
      btn: p.buttons ?? 0,
      x: Math.round(p.clientX),
      y: Math.round(p.clientY),
    });
  };
  for (const type of Object.keys(TAG)) window.addEventListener(type, on, true);
}

/** Everything captured, as a JSON string (what the operator plane returns). */
function penRecorderDump(): string {
  return JSON.stringify({ on: penRecorderOn(), contacts, moves });
}

/** Drop what is buffered — call before a labelled reproduction so the capture
 *  contains that gesture and nothing else. */
function penRecorderReset(): void {
  contacts = [];
  moves = [];
}

declare global {
  interface Window {
    /** Live capture switch + readers, exposed for the operator eval plane. */
    __osgPenRec?: boolean;
    /** Mouse + wire rows switch (see header). */
    __osgPtrRec?: boolean;
    penRecorderDump?: () => string;
    penRecorderReset?: () => void;
  }
}

/** Expose the readers on `window` so the operator plane can call them by name. */
export function exposePointerRecorder(): void {
  if (typeof window === 'undefined') return;
  window.penRecorderDump = penRecorderDump;
  window.penRecorderReset = penRecorderReset;
}

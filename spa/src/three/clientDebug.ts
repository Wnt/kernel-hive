// ============================================================================
//  clientDebug — client telemetry batching + operator command poller.
//  ---------------------------------------------------------------------------
//  Shared protocol contract (serve plane implements the other side):
//    POST /clientlog          — X-Admin-Token + JSON body: ONE event object or an ARRAY of
//                               events. Event fields: ts (ms epoch), sessionId
//                               (8-hex per page load), station (osId or ''), ua
//                               (only on the FIRST event of a batch), event,
//                               detail (<=512 chars). 16KiB body cap.
//    GET  /clientcmd?since=N  — X-Admin-Token; {"seq":N,"cmds":[...]}
//                               with only cmds seq>since. cmd is one of
//                               snapshot | verbose | reload | eval;
//                               station '<osId>'|'*'. eval may also target one
//                               sessionId through args.sessionId.
//  This module NEVER throws into the app: telemetry is best-effort diagnostics
//  for an authenticated operator (clientlog.jsonl on the box), not a dependency.
//  It is intentionally free of any streamClient import (streamClient imports
//  US) and free of React.
// ============================================================================

import { getAdminToken } from './adminAuth';

const FLUSH_MS = 5000;          // normal batching cadence
const VERBOSE_FLUSH_MS = 1000;  // verbose mode lowers batching latency
const POLL_MS = 5000;           // /clientcmd poll cadence while a station is open
const MAX_DETAIL = 512;         // per-contract detail cap
const MAX_PENDING = 200;        // drop-oldest bound so a failing POST can't grow RAM
const MAX_BATCH_CHARS = 14000;  // stay under the server's 16KiB body cap
const SNAP_CHUNK = 480;         // snapshot JSON is chunked to respect MAX_DETAIL
const EVAL_RESULT_MAX = 16 * 1024; // cap reassembled eval-result telemetry

/** Bundle marker so a snapshot proves WHICH client build is running. */
const BUNDLE_MARKER = 'spa-webrtc-phase1-20260716';

interface ClientLogEvent {
  ts: number;
  sessionId: string;
  tile: string;
  ua?: string;
  event: string;
  detail: string;
}

interface ClientCmd {
  seq?: number;
  ts?: number;
  cmd?: string;
  tile?: string;
  args?: Record<string, unknown>;
}

// ---- session id: 8 hex chars per page load ---------------------------------
function makeSessionId(): string {
  try {
    const b = new Uint8Array(4);
    crypto.getRandomValues(b);
    return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
  } catch {
    return Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, '0');
  }
}
const sessionId = makeSessionId();

// ---- module state -----------------------------------------------------------
let pending: ClientLogEvent[] = [];
let flushTimer = 0;
let verbose = false;

let activeTile: string | null = null;
let snapshotHook: (() => unknown) | null = null;
let pollTimer = 0;
let lastSeq = -1; // -1 → next poll is a BASELINE sync (record seq, execute nothing)
let pagehideHooked = false;

/** Verbose debug flag (toggled by the operator's `verbose` command). While on,
 *  streamClient logs every decoder-config / AU-feed anomaly to the console and
 *  telemetry batching drops to 1s. */
export function isVerboseDebug(): boolean { return verbose; }

// ---- event intake -----------------------------------------------------------
/** Queue one telemetry event (batched; flushed every 5s / 1s verbose). Never throws. */
export function logClientEvent(event: string, detail: string): void {
  try {
    const d = detail.length > MAX_DETAIL ? `${detail.slice(0, MAX_DETAIL - 1)}…` : detail;
    pending.push({ ts: Date.now(), sessionId, tile: activeTile ?? '', event, detail: d });
    if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING);
    ensureFlushTimer();
    ensurePagehideFlush();
  } catch { /* telemetry must never break the app */ }
}

function ensurePagehideFlush() {
  if (pagehideHooked || typeof window === 'undefined') return;
  pagehideHooked = true;
  try {
    window.addEventListener('pagehide', () => flushNow(true));
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') flushNow(true);
    });
  } catch { /* noop */ }
}

function ensureFlushTimer() {
  if (flushTimer || typeof window === 'undefined') return;
  flushTimer = window.setInterval(() => flushNow(), verbose ? VERBOSE_FLUSH_MS : FLUSH_MS);
}

function restartFlushTimer() {
  if (typeof window === 'undefined') return;
  if (flushTimer) { window.clearInterval(flushTimer); flushTimer = 0; }
  ensureFlushTimer();
}

/** Flush the pending batch now. Authenticated keepalive fetch survives page
 *  teardown (sendBeacon cannot carry X-Admin-Token). The batch is capped under
 *  the 16KiB body limit; any overflow stays queued for the next flush. */
export function flushNow(_useBeacon = false): void {
  try {
    if (!pending.length) return;
    // Greedily take events while staying under the body cap.
    let take = 0;
    let chars = 2; // []
    while (take < pending.length) {
      const evChars = JSON.stringify(pending[take]).length + 1;
      if (take > 0 && chars + evChars > MAX_BATCH_CHARS) break;
      chars += evChars;
      take++;
    }
    const batch = pending.slice(0, take);
    pending = pending.slice(take);
    // ua rides only the first event of each batch (contract: keeps bodies small).
    try { batch[0].ua = navigator.userAgent; } catch { /* noop */ }
    const body = JSON.stringify(batch);
    // /clientlog is not token-gated (LAN/VPN-only box), so telemetry uploads with
    // no operator setup. If a token happens to be present (an operator tab) send it
    // too — harmless. keepalive fetch (not sendBeacon) so it survives page teardown.
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const adminToken = getAdminToken();
    if (adminToken) headers['X-Admin-Token'] = adminToken;
    void fetch('/clientlog', {
      method: 'POST',
      keepalive: true,
      headers,
      body,
    }).catch(() => { /* box offline — telemetry is best-effort */ });
    if (pending.length) window.setTimeout(() => flushNow(_useBeacon), 250); // drain overflow
  } catch { /* never throw */ }
}

// ---- station lifecycle + command poller -----------------------------------------
/**
 * Mark a station as open: subsequent events carry its osId and the /clientcmd
 * poller runs (commands execute only when cmd.tile === '*' or matches this
 * station). `getSnapshot` feeds the operator `snapshot` command (full metrics).
 */
export function setDebugTile(tile: string, hooks: { getSnapshot: () => unknown }): void {
  activeTile = tile;
  snapshotHook = hooks.getSnapshot;
  startPoller();
}

/** Station closed. A stale unmount (older station) is ignored via the station guard. */
export function clearDebugTile(tile?: string): void {
  if (tile != null && activeTile !== tile) return;
  activeTile = null;
  snapshotHook = null;
  stopPoller();
}

function startPoller() {
  if (typeof window === 'undefined') return;
  if (!pollTimer) pollTimer = window.setInterval(() => { void poll(); }, POLL_MS);
  void poll(); // immediate first poll (baseline sync on a fresh page)
}

function stopPoller() {
  if (pollTimer) { window.clearInterval(pollTimer); pollTimer = 0; }
}

// Set once the server has told us this tab may not poll (no operator token and
// no admin session). Without it a plain visitor's tab would 403 every 5 s.
let pollDenied = false;

async function poll(): Promise<void> {
  // NEVER throw out of the poller — everything is fenced.
  try {
    if (activeTile == null || pollDenied) return;
    const adminToken = getAdminToken();
    // The token is optional. On the PUBLIC origin an admin's passkey session
    // authenticates the poll on its own, which is the only way to drive this
    // plane from a phone: there is no console there to paste a token into, and
    // the phone is where the touch/stylus bugs actually live.
    const res = await fetch(`/clientcmd?since=${lastSeq < 0 ? 0 : lastSeq}`, {
      cache: 'no-store',
      headers: adminToken ? { 'X-Admin-Token': adminToken } : {},
    });
    if (res.status === 401 || res.status === 403 || res.status === 404) {
      pollDenied = true; // not an operator tab — stop asking
      return;
    }
    if (!res.ok) return;
    const doc = (await res.json()) as { seq?: number; cmds?: ClientCmd[] };
    const top = typeof doc.seq === 'number' ? doc.seq : 0;
    if (lastSeq < 0) {
      // BASELINE sync: a fresh page must not replay up to 100 stale commands
      // (a queued `reload` would loop forever). Record the head, execute nothing.
      lastSeq = top;
      return;
    }
    for (const c of Array.isArray(doc.cmds) ? doc.cmds : []) {
      if (typeof c?.seq === 'number' && c.seq > lastSeq) lastSeq = c.seq;
      await execCmd(c);
    }
    if (top > lastSeq) lastSeq = top;
  } catch { /* box offline / bad JSON — try again next tick */ }
}

async function execCmd(c: ClientCmd): Promise<void> {
  try {
    if (!c || typeof c.cmd !== 'string') return;
    if (c.tile !== '*' && c.tile !== activeTile) return;
    if (c.args?.sessionId && c.args.sessionId !== sessionId) return;
    const seq = typeof c.seq === 'number' ? c.seq : -1;
    if (c.cmd === 'snapshot') {
      emitSnapshot();
    } else if (c.cmd === 'verbose') {
      // Explicit args.on wins; otherwise toggle.
      const on = c.args && typeof c.args.on === 'boolean' ? c.args.on : !verbose;
      verbose = on;
      restartFlushTimer();
      console.info(`[clientDebug] verbose ${on ? 'ON' : 'OFF'} (operator command)`);
    } else if (c.cmd === 'reload') {
      logClientEvent('cmd-ack', `reload seq=${seq} executed`);
      flushNow(true);
      window.setTimeout(() => window.location.reload(), 100);
      return;
    } else if (c.cmd === 'eval') {
      let payload: string;
      try {
        const fn = new Function(
          'return (async () => {' + String(c.args?.code) + '})()',
        ) as () => Promise<unknown>;
        const out = await fn();
        payload = fitEvalEnvelope({
          seq,
          sessionId,
          ok: true,
          // Keep the safely serialized value as JSON text. This lets the
          // operator helper parse it when complete while keeping the outer
          // envelope valid even when the value must be truncated.
          result: safeSerializeEvalValue(out),
        });
      } catch (err) {
        payload = fitEvalEnvelope({
          seq,
          sessionId,
          ok: false,
          error: thrownString(err),
          stack: thrownStack(err),
        });
      }
      emitEvalResult(payload);
      logClientEvent('cmd-ack', `eval seq=${seq} executed`);
      flushNow();
      return;
    } else {
      return; // unknown command — ignore, no ack
    }
    logClientEvent('cmd-ack', `${c.cmd} seq=${seq} executed`);
  } catch { /* command execution must never take the poller down */ }
}

/** JSON serialization for arbitrary diagnostic values. The replacer avoids
 * throwing on the common browser values that plain JSON.stringify cannot
 * represent and gives DOM nodes a compact, non-recursive summary. */
function safeSerializeEvalValue(out: unknown): string {
  try {
    const seen = new WeakSet<object>();
    const encoded = JSON.stringify(out, (_key, value: unknown) => {
      if (typeof value === 'undefined') return '[Undefined]';
      if (typeof value === 'function') return '[Function]';
      if (typeof value === 'bigint') return `[BigInt ${String(value)}]`;
      if (typeof value === 'symbol') return String(value);
      if (value && typeof value === 'object') {
        if (seen.has(value)) return '[Circular]';
        seen.add(value);
        if (value instanceof Error) {
          return {
            name: value.name,
            message: value.message,
            stack: value.stack,
            cause: (value as Error & { cause?: unknown }).cause,
          };
        }
        if (typeof Node !== 'undefined' && value instanceof Node) {
          const node = value as Node & {
            tagName?: string;
            id?: string;
            className?: string;
          };
          const tag = node.tagName || node.nodeName || 'Node';
          const id = node.id ? `#${node.id}` : '';
          const cls = typeof node.className === 'string' && node.className.trim()
            ? `.${node.className.trim().split(/\s+/).join('.')}`
            : '';
          return `[DOM ${tag}${id}${cls}]`;
        }
      }
      return value;
    });
    if (typeof encoded === 'string') return encoded;
  } catch { /* fall through to String */ }
  try { return String(out); } catch { return '[Unserializable]'; }
}

function thrownString(err: unknown): string {
  try { return String(err); } catch { return '[Unprintable thrown value]'; }
}

function thrownStack(err: unknown): string {
  try {
    if (err && typeof err === 'object' && 'stack' in err) {
      const stack = (err as { stack?: unknown }).stack;
      return stack == null ? '' : String(stack);
    }
  } catch { /* hostile getter */ }
  return '';
}

/** Keep the complete eval-result as valid JSON while bounding it to 16 KiB.
 * String fields are proportionally shortened until the encoded envelope fits;
 * the explicit marker makes loss visible to the operator. */
function fitEvalEnvelope(envelope: Record<string, unknown>): string {
  try {
    let payload = asciiJson(envelope);
    if (payload.length <= EVAL_RESULT_MAX) return payload;

    const strings = Object.entries(envelope)
      .filter((entry): entry is [string, string] =>
        ['result', 'error', 'stack'].includes(entry[0]) && typeof entry[1] === 'string');
    const marker = '…[truncated]';
    let lo = 0;
    let hi = 1;
    let best = asciiJson({
      seq: envelope.seq,
      sessionId: envelope.sessionId,
      ok: envelope.ok,
      truncated: true,
    });
    for (let attempt = 0; attempt < 24; attempt++) {
      const ratio = (lo + hi) / 2;
      const candidate: Record<string, unknown> = { ...envelope, truncated: true };
      for (const [key, value] of strings) {
        const keep = Math.floor(value.length * ratio);
        candidate[key] = keep < value.length ? `${value.slice(0, keep)}${marker}` : value;
      }
      payload = asciiJson(candidate);
      if (payload.length <= EVAL_RESULT_MAX) {
        best = payload;
        lo = ratio;
      } else {
        hi = ratio;
      }
    }
    return best;
  } catch (err) {
    return asciiJson({
      seq: envelope.seq,
      sessionId: envelope.sessionId,
      ok: false,
      error: `eval result serialization failed: ${thrownString(err)}`,
    });
  }
}

/** The server caps request bodies in bytes while telemetry batching measures
 * JSON text length. Escaping non-ASCII code units keeps those units identical
 * for eval payloads, including astral characters represented as surrogate
 * pairs, so a 16 KiB character cap cannot become a larger UTF-8 upload. */
function asciiJson(value: unknown): string {
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (char) =>
    `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`,
  );
}

/** Queue one complete eval response using the snapshot chunk wire format. */
function emitEvalResult(payload: string): void {
  const n = Math.max(1, Math.ceil(payload.length / SNAP_CHUNK));
  for (let i = 0; i < n; i++) {
    pending.push({
      ts: Date.now(),
      sessionId,
      tile: activeTile ?? '',
      event: 'eval-result',
      detail: `[${i + 1}/${n}] ${payload.slice(i * SNAP_CHUNK, (i + 1) * SNAP_CHUNK)}`,
    });
  }
  ensureFlushTimer();
  ensurePagehideFlush();
}

/** Emit the full metrics snapshot as `snapshot` events. The JSON (metrics + UA
 *  + bundle marker) usually exceeds the 512-char detail cap, so it is split
 *  into `[i/n] <chunk>` parts — reassemble with jq/sort on the box. */
function emitSnapshot(): void {
  let payload: string;
  try {
    payload = JSON.stringify({
      metrics: snapshotHook ? snapshotHook() : null,
      ua: typeof navigator !== 'undefined' ? navigator.userAgent : '',
      bundle: BUNDLE_MARKER,
    });
  } catch (e) {
    payload = `snapshot failed: ${String(e)}`;
  }
  const n = Math.max(1, Math.ceil(payload.length / SNAP_CHUNK));
  for (let i = 0; i < n; i++) {
    // logClientEvent re-caps at 512; "[i/n] " + 480 chars stays under it.
    pending.push({
      ts: Date.now(),
      sessionId,
      tile: activeTile ?? '',
      event: 'snapshot',
      detail: `[${i + 1}/${n}] ${payload.slice(i * SNAP_CHUNK, (i + 1) * SNAP_CHUNK)}`,
    });
  }
  ensureFlushTimer();
  ensurePagehideFlush();
  flushNow(); // land snapshots promptly — the operator is waiting
}

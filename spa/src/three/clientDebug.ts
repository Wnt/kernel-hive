// ============================================================================
//  clientDebug — client telemetry batching + operator command poller.
//  ---------------------------------------------------------------------------
//  Shared protocol contract (serve plane implements the other side):
//    POST /clientlog          — NO token. JSON body: ONE event object or an ARRAY of
//                               events. Event fields: ts (ms epoch), sessionId
//                               (8-hex per page load), station (osId or ''), ua
//                               (only on the FIRST event of a batch), event,
//                               detail (<=512 chars). 16KiB body cap.
//    GET  /clientcmd?since=N  — NO token. Any authenticated gallery session may
//                               poll; {"seq":N,"cmds":[...]} with only cmds
//                               seq>since. cmd is one of snapshot | verbose |
//                               reload | eval; station '<osId>'|'*'. eval may
//                               also target one sessionId through args.sessionId.
//                               Only the BOX can enqueue (loopback + operator
//                               token); no UI session has a path to issue one.
//  EVERY session polls and every session logs — deliberately. The visitor whose
//  stream never came up is exactly the one worth reaching, and gating the poll
//  on an admin session made those sessions invisible and unreachable. Reaching
//  them is safe because the issuing side is box-side only: a tab can RECEIVE a
//  command, never send one.
//  This module NEVER throws into the app: telemetry is best-effort diagnostics
//  (clientlog.jsonl on labhost), not a dependency.
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
/** Opaque identity for the mount that currently owns the station tag. */
export type DebugTileOwner = number;
let tileOwner: DebugTileOwner = 0;
let nextTileOwner = 1;
let snapshotHook: (() => unknown) | null = null;
let pollTimer = 0;
let lastSeq = -1; // -1 → next poll is a BASELINE sync (record seq, execute nothing)
let pagehideHooked = false;
let bootLogged = false;

/** Which station this tab currently has open, or null between stations. The
 *  usage counters read it rather than keeping their own copy: two answers to
 *  "which station is this?" is one answer too many, and the mount-overlap rule
 *  that clearDebugTile encodes is subtle enough to be worth having once. */
export function activeDebugTile(): string | null { return activeTile; }

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
    // The network came back: deliver whatever a failed-flush outage re-queued,
    // and poll for commands NOW — an operator is likely mid-debug of exactly
    // that outage (STREAM-DEBUGGING.md, Mode D).
    window.addEventListener('online', () => { flushNow(); void poll(); });
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

/** A failed POST puts its batch BACK (front, order preserved) instead of
 *  dropping it — dropping is what made the 2026-08-25 network outage invisible
 *  in clientlog.jsonl (Mode D). Bounded by MAX_PENDING dropping OLDEST, so the
 *  freshest evidence survives a long outage; retries ride the 5 s interval
 *  timer only (never a tight drain loop). */
let flushInFlight = false;
function requeueBatch(batch: ClientLogEvent[]): void {
  pending = batch.concat(pending);
  if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING);
}

/** Flush the pending batch now. Authenticated keepalive fetch survives page
 *  teardown (sendBeacon cannot carry X-Admin-Token). The batch is capped under
 *  the 16KiB body limit; any overflow stays queued for the next flush. `force`
 *  (the pagehide/hidden path) bypasses the single-flight guard so the tail is
 *  never held back by an in-flight request during teardown. */
export function flushNow(force = false): void {
  try {
    if (!pending.length) return;
    if (flushInFlight && !force) return; // one at a time; the interval retries
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
    // /clientlog is never token-gated: on the public edge the visitor's own
    // session cookie authorizes it, on LAN it is open. Telemetry therefore
    // uploads with no operator setup at all, from every session. If a token
    // happens to be present (an operator tab) send it too — harmless.
    // keepalive fetch (not sendBeacon) so it survives page teardown.
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    const adminToken = getAdminToken();
    if (adminToken) headers['X-Admin-Token'] = adminToken;
    flushInFlight = true;
    void fetch('/clientlog', {
      method: 'POST',
      keepalive: true,
      headers,
      body,
    }).then((res) => {
      flushInFlight = false;
      if (!res.ok) { requeueBatch(batch); return; }
      if (pending.length) window.setTimeout(() => flushNow(), 250); // drain overflow
    }).catch(() => {
      flushInFlight = false;
      requeueBatch(batch); // box unreachable — keep the evidence, retry on the interval
    });
  } catch { /* never throw */ }
}

// ---- station lifecycle + command poller -----------------------------------------
/**
 * Mark a station as open: subsequent events carry its osId and the /clientcmd
 * poller runs (commands execute only when cmd.tile === '*' or matches this
 * station). `getSnapshot` feeds the operator `snapshot` command (full metrics).
 */
export function setDebugTile(tile: string, hooks: { getSnapshot: () => unknown }): DebugTileOwner {
  activeTile = tile;
  snapshotHook = hooks.getSnapshot;
  tileOwner = nextTileOwner++;
  // THE FIRST EVENT OF EVERY SESSION. Until this existed, the earliest thing a
  // session could log was `connect` — transport SUCCESS — so a visitor whose
  // stream never came up produced literally nothing (measured: 306 of 380
  // sessions in clientlog.jsonl opened with `connect`, and a 25-minute failing
  // session logged zero rows). A session that fails is the one whose telemetry
  // matters most, so opening a station is now recorded unconditionally, before
  // anything can go wrong, together with the capability probe that explains
  // most early failures.
  logClientEvent('station-open', describeEnvironment(tile));
  startPoller();
  return tileOwner;
}

/** Compact one-line environment probe: the facts that explain an early failure
 *  before any transport exists (missing WebTransport/WebCodecs, an insecure
 *  context, a restricted network's blocked QUIC). Kept well under the 512-char
 *  detail cap and free of anything identifying beyond the UA we already log. */
function describeEnvironment(tile: string | null): string {
  const probe: Record<string, unknown> = { tile: tile ?? '', bundle: BUNDLE_MARKER };
  try {
    probe.wt = typeof WebTransport !== 'undefined';
    probe.vd = typeof VideoDecoder !== 'undefined';
    probe.rtc = typeof RTCPeerConnection !== 'undefined';
    probe.secure = typeof isSecureContext !== 'undefined' ? isSecureContext : null;
    probe.sw = typeof navigator !== 'undefined' && 'serviceWorker' in navigator
      ? (navigator.serviceWorker.controller ? 'controlled' : 'registered-or-none')
      : 'unsupported';
    const conn = (navigator as Navigator & {
      connection?: { effectiveType?: string; downlink?: number; rtt?: number };
    }).connection;
    if (conn) probe.net = { t: conn.effectiveType, dl: conn.downlink, rtt: conn.rtt };
    probe.hidden = typeof document !== 'undefined' ? document.visibilityState : null;
    probe.href = typeof location !== 'undefined' ? location.pathname : '';
  } catch { /* a probe must never be why telemetry is missing */ }
  try { return JSON.stringify(probe); } catch { return `tile=${tile ?? ''}`; }
}

/** Station closed. Pass the token setDebugTile returned: a guard on the tile NAME
 *  alone cannot tell two overlapping mounts of the SAME station apart, so the
 *  outgoing mount's cleanup used to wipe the incoming one's tag — after which
 *  every event it logged carried an EMPTY `tile`. In clientlog.jsonl an empty
 *  tile on a `connect` is a 100% predictor of a black stream (0 of 14 such
 *  sessions ever decoded a frame); it is the fingerprint of exactly this
 *  overlap. The token makes the clear a no-op unless the caller still owns
 *  the tag. */
export function clearDebugTile(tile?: string, owner?: DebugTileOwner): void {
  if (tile != null && activeTile !== tile) return;
  if (owner != null && tileOwner !== owner) return;
  activeTile = null;
  snapshotHook = null;
  tileOwner = 0;
  // The poller deliberately keeps running: it belongs to the TAB, not to the
  // station. A visitor who backed out of a broken station is exactly who an
  // operator still wants to reach.
}

/**
 * Start telemetry + operator reachability for the WHOLE PAGE, at app boot.
 *
 * This is the fix for the session that logs nothing. Everything here used to
 * hang off setDebugTile, which runs inside the stream effect — so a tab that
 * never started a stream (a manifest that did not load, a non-streamable
 * binding, a visitor sitting on the grid) emitted NOTHING and, because the
 * poller started there too, could not be reached by an operator command
 * either. It was invisible and unreachable at the same time, for as long as
 * the visitor sat there.
 *
 * Now the first row of every session is written when the app boots, before any
 * station is chosen and before anything can fail, and the command poller runs
 * for the lifetime of the tab. Idempotent: safe to call more than once.
 */
export function initClientDebug(): void {
  if (bootLogged) return;
  bootLogged = true;
  try {
    logClientEvent('session-start', describeEnvironment(null));
    startPoller();
  } catch { /* telemetry must never break app startup */ }
}

function startPoller() {
  if (typeof window === 'undefined') return;
  if (!pollTimer) pollTimer = window.setInterval(() => { void poll(); }, POLL_MS);
  void poll(); // immediate first poll (baseline sync on a fresh page)
}

// Set only if the server tells us this tab may not poll at all — which now means
// "not signed in", not "not an operator". Without it a signed-out tab would
// retry every 5 s forever.
let pollDenied = false;

async function poll(): Promise<void> {
  // NEVER throw out of the poller — everything is fenced.
  try {
    if (pollDenied) return;
    const adminToken = getAdminToken();
    // The token is optional and no longer the point: ANY authenticated gallery
    // session may poll, so every open tab is reachable for debugging. A tab
    // still only ACTS on a command addressed to it (station + optional
    // sessionId), and only the operator can issue one.
    const res = await fetch(`/clientcmd?since=${lastSeq < 0 ? 0 : lastSeq}`, {
      cache: 'no-store',
      headers: adminToken ? { 'X-Admin-Token': adminToken } : {},
    });
    if (res.status === 401 || res.status === 403 || res.status === 404) {
      pollDenied = true; // not signed in — stop asking
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
 *  into `[i/n] <chunk>` parts — reassemble with jq/sort on labhost. */
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

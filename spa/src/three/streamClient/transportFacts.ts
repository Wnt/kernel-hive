// ============================================================================
//  three/streamClient/transportFacts — WHAT THE INPUT HOP ACTUALLY RIDES ON.
//  ---------------------------------------------------------------------------
//  THERE IS NO HTTP REQUEST BEHIND A KEYSTROKE, and no span here pretends
//  there is. A key or a click leaves this tab as a length-prefixed record on a
//  client-opened QUIC unidirectional stream inside one WebTransport session
//  (`streamClient.ts::writeReliableClass`); pointer motion leaves as a QUIC
//  DATAGRAM. Both are inside an HTTP/3 CONNECT session, which is the only
//  sense in which HTTP is involved at all — there is no request, no method, no
//  status code, and inventing `http.client.request` to make a flame graph look
//  familiar would be the same false claim `docs/lab/TRACE-CONTEXT.md` §8
//  forbids about a span's causal shape.
//
//  SO THE HOP IS DESCRIBED BY ITS REAL PROPERTIES INSTEAD: which endpoint,
//  which protocol, which reliability class, and — the number that actually
//  answers "where did the time go" — the connection's own smoothed RTT, read
//  from `WebTransport.getStats()`.
//
//  `getStats()` IS NOT THERE, AND THIS SAYS SO. Measured on the browser this
//  gallery actually serves — Chrome 150 on CT950, 2026-09-01:
//  `typeof WebTransport.prototype.getStats === 'undefined'`. The whole
//  prototype is `ready`/`closed`/`close`/`datagrams`/`protocol`/the two stream
//  factories and nothing else. So the spec'd connection stats — smoothed RTT,
//  estimated send rate, datagram loss counters — are simply not obtainable
//  from a browser here, and an attribute that is always absent would be worse
//  than none: it reads as "the poll has not run" forever.
//
//  WHAT WE HAVE INSTEAD, and it is not a consolation prize. The stream client
//  already runs a liveness PING over this very connection (`streamClient.ts::
//  pingRtt`, a type-9 datagram the daemon echoes, re-taken by the ABR loop
//  every few seconds) and keeps the result in `lastRtt`. Both ends of that
//  measurement are `performance.now()` readings in THIS tab, so unlike a
//  cross-machine span subtraction it needs no clock agreement — and unlike
//  `smoothedRtt` it is an APPLICATION-level round trip, which is the number a
//  visitor's finger actually waits on. It is carried here with
//  `kh.transport.rtt_source` naming which of the two produced it, so a reader
//  is never left guessing what kind of RTT they are looking at. The moment a
//  UA ships `getStats()`, the transport's own figure wins and the source
//  attribute says so, with no other change.
//
//  WHY A CACHE AND NOT A CALL PER EDGE. `getStats()` returns a PROMISE and the
//  input senders are synchronous (`sendKeyScancodeImpl` runs inside the key
//  handler and must not yield before the record hits the wire). So this module
//  polls once every `STATS_EVERY_MS` on a timer of its own and hands the last
//  snapshot back synchronously. An RTT that is up to a few seconds stale is
//  the right trade: it is a SMOOTHED figure over the connection anyway, so a
//  fresh read would not be a per-edge measurement even if we could afford one.
//
//  NOTHING HERE IS COMMITTED. Every address and port below is read at RUNTIME
//  from the signalling document this tab just fetched. No default, fixture or
//  test in this repo carries a real one (AGENTS.md rule 1) — `facts.test.ts`
//  uses `https://labhost:443/wt`, the same placeholder the rest of the repo
//  uses.
//
//  WHAT IS DELIBERATELY ABSENT.
//    * `net.peer.ip` — the browser cannot see the peer's resolved address, and
//      the daemon is forbidden from putting it in a span (contract §7: no peer
//      address). It is not "not yet done"; it is not going to exist.
//    * `network.peer.port` — the LOCAL port of a QUIC connection is likewise
//      invisible to JS. Only the SERVER port is knowable, and it is emitted.
// ============================================================================
import type { Attrs } from '../../analytics/trace';

/** How often the connection's stats are re-read. Cheap (one promise per
 *  interval per session) and deliberately slow: `smoothedRtt` is a moving
 *  average, so sampling it faster measures nothing new. */
const STATS_EVERY_MS = 5000;

/** OTel semantic-convention naming, emitted in BOTH spellings on purpose.
 *  `server.address`/`server.port` is the current convention and is what our
 *  own plane is the product of; `net.peer.name`/`net.peer.port` is the older
 *  spelling Instana's documented consumed-attribute list still reads to
 *  populate its call-detail and dependency panes. This is the same
 *  emit-both migration shape the OTel SDKs spell `http/dup`, applied here by
 *  hand because our emitter is our own. When the HTTP side of this repo
 *  settles on one bridging rule, this is the second place that has to follow
 *  it — the rule is "our plane's naming is the product, the vendor is the
 *  temporary consumer", never a third convention invented here. */
interface Endpoint {
  host: string;
  port: number;
}

interface Facts {
  endpoint: Endpoint | null;
  /** `webtransport`. There is exactly ONE input transport: every input record
   *  goes through `StreamClient.writeReliableClass`/`writeDatagram`, which are
   *  WebTransport-only. The WebRTC fallback client carries VIDEO and nothing
   *  else (`webRtcFallbackClient.ts` has no send path at all), so a fallback
   *  session is not a second input transport — it is the same one. Recorded
   *  explicitly rather than assumed, so the day that stops being true the
   *  trace says so instead of silently reading the same. */
  kind: string;
  /** Per-CONNECTION id, minted here, so many sampled edges over one session
   *  can be grouped without any of them carrying a session ticket. Not a
   *  secret and not derived from one. */
  connId: string;
  stats: Stats | null;
  /** The negotiated ALPN, when the UA exposes it (`WebTransport.protocol`).
   *  Empty string until the handshake names one; omitted from the span
   *  rather than emitted blank. */
  alpn: string;
  /** The stream client's own liveness-ping RTT, read at emit time so it is
   *  as fresh as the ABR loop last made it. Null when no ping has answered. */
  pingRtt: (() => number | null) | null;
  /** Whether `WebTransport.getStats` exists in this browser at all. Recorded
   *  so an absent RTT is legible as "this UA has no such API" rather than as
   *  "the poll has not run yet". */
  statsApi: boolean;
}

interface Stats {
  rttMs: number | null;
  minRttMs: number | null;
  /** Outgoing datagrams the connection gave up on. Pointer motion rides
   *  datagrams, so this is the loss number that matters for the input plane —
   *  a stream record is retransmitted until it lands and is never lost. */
  dgramLost: number | null;
}

let facts: Facts | null = null;
let timer = 0;

/** A `WebTransport` as far as this module needs to know it. Typed structurally
 *  because `getStats()` is not in every lib.dom this repo builds against — a
 *  UA that lacks it is a supported case (see `statsApi`), not a build error. */
type StatsCapableTransport = {
  getStats?: () => Promise<Record<string, unknown>>;
  protocol?: string;
};

function hex(n: number): string {
  const b = new Uint8Array(n);
  try { (globalThis.crypto as Crypto | undefined)?.getRandomValues(b); } catch { /* below */ }
  let empty = true;
  for (const v of b) if (v !== 0) { empty = false; break; }
  if (empty) for (let i = 0; i < b.length; i += 1) b[i] = Math.floor(Math.random() * 256);
  return Array.from(b, (v) => v.toString(16).padStart(2, '0')).join('');
}

/** The endpoint this session's WebTransport URL names. Returns null rather
 *  than throwing on anything unparseable — a missing attribute is always
 *  better than an instrumentation module that can break a connect. */
export function parseEndpoint(url: string): Endpoint | null {
  try {
    const u = new URL(url);
    if (!u.hostname) return null;
    return { host: u.hostname, port: Number(u.port || '443') };
  } catch { return null; }
}

function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? Math.round(v * 1000) / 1000 : null;
}

/** Read one `WebTransportConnectionStats` into the three numbers worth a span
 *  attribute. Everything else it reports (byte and packet counters, stream
 *  counts, estimated send rate) is a CUMULATIVE session total: useful in a
 *  dashboard, meaningless stamped on one keystroke's span, so it is not
 *  carried. */
export function readStats(raw: Record<string, unknown>): Stats {
  const dg = raw.datagrams;
  const dgRec = (dg && typeof dg === 'object') ? dg as Record<string, unknown> : {};
  return {
    rttMs: num(raw.smoothedRtt),
    minRttMs: num(raw.minRtt),
    dgramLost: num(dgRec.expiredOutgoing ?? dgRec.droppedIncoming ?? dgRec.lostOutgoing),
  };
}

/** Record what this session's transport IS, and start polling what it is
 *  doing. Called once, right after `wt.ready` settles. Returns nothing: the
 *  poll is torn down by `clearTransportFacts` on close, and a tab that never
 *  calls it simply has no transport attributes on its spans. */
export function setTransportFacts(
  url: string, wt: unknown, pingRtt?: () => number | null,
): void {
  clearTransportFacts();
  const t = wt as StatsCapableTransport | null;
  const statsApi = typeof t?.getStats === 'function';
  facts = {
    endpoint: parseEndpoint(url),
    kind: 'webtransport',
    connId: hex(8),
    stats: null,
    statsApi,
    alpn: typeof t?.protocol === 'string' ? t.protocol : '',
    pingRtt: pingRtt ?? null,
  };
  if (!statsApi) return;
  const poll = () => {
    try {
      void t?.getStats?.().then(
        (raw) => { if (facts && raw && typeof raw === 'object') facts.stats = readStats(raw); },
        () => { /* a closing session rejects; the last snapshot stands */ },
      );
    } catch { /* never throw out of instrumentation */ }
  };
  poll();
  timer = (globalThis.setInterval as typeof setInterval)(poll, STATS_EVERY_MS) as unknown as number;
}

/** Forget this connection. Called on close/dispose so a reconnect's spans
 *  never carry the previous connection's RTT or id. */
export function clearTransportFacts(): void {
  if (timer) { try { clearInterval(timer); } catch { /* noop */ } timer = 0; }
  facts = null;
}

/** The attribute set for ONE `input.wire` span. `reliability` is the caller's
 *  own fact — `stream` for a key/button record on its per-class QUIC stream,
 *  `datagram` for pointer motion — and it is here because the two have
 *  genuinely different loss and latency behaviour and a trace that could not
 *  tell them apart would be answering the wrong question.
 *
 *  BUDGET: at most 13 keys, well inside `traces.py`'s ATTR_MAX of 24, and
 *  every string here is a hostname, a token or a fixed literal — nothing that
 *  can approach ATTR_STR_MAX (120). Chosen small on purpose: an attribute set
 *  that gets silently truncated at intake is worse than a smaller one. */
export function transportAttrs(reliability: 'stream' | 'datagram'): Attrs {
  const a: Attrs = {
    'network.transport': 'quic',
    'network.protocol.name': 'http',
    'network.protocol.version': '3',
    'peer.service': 'kernel-hive-daemon',
    'kh.wire.reliability': reliability,
  };
  if (!facts) return a;
  a['kh.transport'] = facts.kind;
  a['kh.transport.conn'] = facts.connId;
  if (facts.endpoint) {
    a['server.address'] = facts.endpoint.host;
    a['server.port'] = facts.endpoint.port;
    a['net.peer.name'] = facts.endpoint.host;
    a['net.peer.port'] = facts.endpoint.port;
  }
  if (facts.alpn) a['network.protocol.alpn'] = facts.alpn;
  const s = facts.statsApi ? facts.stats : null;
  if (s && s.rttMs !== null) {
    // The transport's own figure, when a UA has one.
    a['kh.transport.rtt_ms'] = s.rttMs;
    a['kh.transport.rtt_source'] = 'getstats';
    if (s.minRttMs !== null) a['kh.transport.rtt_min_ms'] = s.minRttMs;
    if (s.dgramLost !== null) a['kh.transport.dgram_lost'] = s.dgramLost;
    return a;
  }
  // No `getStats()` (every browser this gallery serves today — see the header)
  // or it has not answered yet: fall back to the liveness ping, which is a
  // real round trip over this same connection rather than an estimate.
  const ping = facts.pingRtt?.() ?? null;
  if (ping !== null && Number.isFinite(ping)) {
    a['kh.transport.rtt_ms'] = Math.round(ping * 1000) / 1000;
    a['kh.transport.rtt_source'] = 'ping';
    return a;
  }
  // Nothing measured yet — say WHICH kind of nothing.
  a['kh.transport.rtt_source'] = facts.statsApi ? 'none-yet' : 'no-getstats';
  return a;
}

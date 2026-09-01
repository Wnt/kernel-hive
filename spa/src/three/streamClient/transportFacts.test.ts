// The transport hop's attributes: what is emitted, what is deliberately
// absent, and that the whole set fits our own intake budget.
import { describe, it, expect, afterEach, vi } from 'vitest';
import {
  parseEndpoint, readStats, transportAttrs, setTransportFacts, clearTransportFacts,
} from './transportFacts';

const ATTR_MAX = 24;        // scripts/serve/traces.py
const ATTR_STR_MAX = 120;   // scripts/serve/traces.py

afterEach(() => { clearTransportFacts(); vi.useRealTimers(); });

describe('parseEndpoint', () => {
  it('reads host and explicit port from the signalling url', () => {
    // A scrubbed placeholder, per AGENTS.md rule 1 — never a real host.
    expect(parseEndpoint('https://labhost:8443/wt')).toEqual({ host: 'labhost', port: 8443 });
  });
  it('defaults the port to 443 when the url omits it', () => {
    expect(parseEndpoint('https://labhost/wt')).toEqual({ host: 'labhost', port: 443 });
  });
  it('returns null rather than throwing on junk', () => {
    expect(parseEndpoint('not a url')).toBeNull();
  });
});

describe('readStats', () => {
  it('keeps the three latency/loss numbers and ignores cumulative counters', () => {
    expect(readStats({
      smoothedRtt: 12.3456, minRtt: 9, bytesSent: 999, packetsSent: 42,
      datagrams: { expiredOutgoing: 3 },
    })).toEqual({ rttMs: 12.346, minRttMs: 9, dgramLost: 3 });
  });
  it('reports nulls when the UA returns an empty dictionary', () => {
    expect(readStats({})).toEqual({ rttMs: null, minRttMs: null, dgramLost: null });
  });
});

describe('transportAttrs', () => {
  it('carries the protocol identity even with no connection recorded', () => {
    const a = transportAttrs('stream');
    expect(a['network.transport']).toBe('quic');
    expect(a['network.protocol.name']).toBe('http');
    expect(a['network.protocol.version']).toBe('3');
    expect(a['peer.service']).toBe('kernel-hive-daemon');
    expect(a['kh.wire.reliability']).toBe('stream');
  });

  it('emits the endpoint in BOTH semantic-convention spellings', () => {
    setTransportFacts('https://labhost:8443/wt', {});
    const a = transportAttrs('stream');
    expect(a['server.address']).toBe('labhost');
    expect(a['server.port']).toBe(8443);
    expect(a['net.peer.name']).toBe('labhost');
    expect(a['net.peer.port']).toBe(8443);
  });

  it('never claims a peer IP — the browser cannot see one', () => {
    setTransportFacts('https://labhost:8443/wt', {});
    expect(transportAttrs('stream')['net.peer.ip']).toBeUndefined();
  });

  it('names the absence when NO browser API and no ping has produced an RTT', () => {
    // Chrome 150, measured 2026-09-01: WebTransport.prototype.getStats does
    // not exist. An always-absent attribute would read as "the poll has not
    // run" forever, so the reason is emitted instead.
    setTransportFacts('https://labhost:8443/wt', {});
    const a = transportAttrs('stream');
    expect(a['kh.transport.rtt_source']).toBe('no-getstats');
    expect(a['kh.transport.rtt_ms']).toBeUndefined();
  });

  it('falls back to the liveness-ping RTT when getStats is absent', () => {
    setTransportFacts('https://labhost:8443/wt', {}, () => 4.25);
    const a = transportAttrs('stream');
    expect(a['kh.transport.rtt_ms']).toBe(4.25);
    expect(a['kh.transport.rtt_source']).toBe('ping');
  });

  it('carries the negotiated ALPN when the UA exposes one', () => {
    setTransportFacts('https://labhost:8443/wt', { protocol: 'h3' });
    expect(transportAttrs('stream')['network.protocol.alpn']).toBe('h3');
    setTransportFacts('https://labhost:8443/wt', { protocol: '' });
    expect(transportAttrs('stream')['network.protocol.alpn']).toBeUndefined();
  });

  it('reports the connection RTT once a poll has answered', async () => {
    const wt = { getStats: () => Promise.resolve({ smoothedRtt: 7.5, minRtt: 6 }) };
    setTransportFacts('https://labhost:8443/wt', wt);
    await Promise.resolve(); await Promise.resolve();
    const a = transportAttrs('datagram');
    expect(a['kh.transport.rtt_ms']).toBe(7.5);
    expect(a['kh.transport.rtt_min_ms']).toBe(6);
    expect(a['kh.wire.reliability']).toBe('datagram');
    expect(a['kh.transport.rtt_source']).toBe('getstats');
  });

  it('prefers the transport figure over the ping when both exist', async () => {
    const wt = { getStats: () => Promise.resolve({ smoothedRtt: 7.5 }) };
    setTransportFacts('https://labhost:8443/wt', wt, () => 99);
    await Promise.resolve(); await Promise.resolve();
    expect(transportAttrs('stream')['kh.transport.rtt_ms']).toBe(7.5);
    expect(transportAttrs('stream')['kh.transport.rtt_source']).toBe('getstats');
  });

  it('says "none-yet" while a supported getStats has not answered', () => {
    setTransportFacts('https://labhost:8443/wt', { getStats: () => new Promise(() => {}) });
    expect(transportAttrs('stream')['kh.transport.rtt_source']).toBe('none-yet');
  });

  it('gives each connection its own id, and forgets it on close', () => {
    setTransportFacts('https://labhost:8443/wt', {});
    const first = transportAttrs('stream')['kh.transport.conn'];
    setTransportFacts('https://labhost:8443/wt', {});
    expect(transportAttrs('stream')['kh.transport.conn']).not.toBe(first);
    clearTransportFacts();
    expect(transportAttrs('stream')['kh.transport.conn']).toBeUndefined();
  });

  it('fits our own intake budget in its fullest form', async () => {
    const wt = {
      getStats: () => Promise.resolve({
        smoothedRtt: 7.5, minRtt: 6, datagrams: { expiredOutgoing: 2 },
      }),
    };
    setTransportFacts('https://labhost:8443/wt', { ...wt, protocol: 'h3' }, () => 4);
    await Promise.resolve(); await Promise.resolve();
    const a = transportAttrs('stream');
    expect(Object.keys(a).length).toBeLessThanOrEqual(ATTR_MAX);
    for (const v of Object.values(a)) {
      if (typeof v === 'string') expect(v.length).toBeLessThanOrEqual(ATTR_STR_MAX);
    }
  });
});

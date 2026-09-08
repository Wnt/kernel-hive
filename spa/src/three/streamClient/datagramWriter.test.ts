// The two WebTransport datagram API shapes, and that BOTH yield a working
// writer with the right facts. Safari 26 ships only the spec shape
// (`createWritable()`), Chromium 150 only the legacy one (`writable`); the
// bug this guards against burned every ladder attempt on iOS.
import { describe, it, expect } from 'vitest';
import { openDatagramWriter, OUTGOING_MAX_AGE_MS } from './datagramWriter';
import { setTransportFacts, transportAttrs, clearTransportFacts } from './transportFacts';

/** A WritableStream that records what was written, plus (optionally) the
 *  spec's `outgoingMaxAge` knob on the writable object itself. */
function fakeWritable(withKnob: boolean) {
  const chunks: Uint8Array[] = [];
  const ws = new WritableStream<Uint8Array>({ write(c) { chunks.push(c); } });
  if (withKnob) Object.defineProperty(ws, 'outgoingMaxAge', { value: null, writable: true, enumerable: true });
  return { ws, chunks };
}

describe('openDatagramWriter', () => {
  it('spec shape (Safari 26): only createWritable(), knob on the writable', async () => {
    const { ws, chunks } = fakeWritable(true);
    let created = 0;
    const dg = {
      readable: new ReadableStream<Uint8Array>(),
      createWritable: () => { created += 1; return ws; },
      // NO `writable` — exactly what `t.datagrams.writable.getWriter` threw on.
    };
    const { writer, facts } = openDatagramWriter(dg);
    expect(created).toBe(1);
    await writer.write(new Uint8Array([9, 1, 0, 0, 0]));
    expect(chunks).toHaveLength(1);
    expect(facts).toEqual({ api: 'createWritable', maxAgeOn: 'writable' });
    expect((ws as unknown as { outgoingMaxAge: number }).outgoingMaxAge).toBe(OUTGOING_MAX_AGE_MS);
  });

  it('legacy shape (Chromium): only writable, knob on the duplex stream', async () => {
    const { ws, chunks } = fakeWritable(false);
    const dg = { readable: new ReadableStream<Uint8Array>(), writable: ws, outgoingMaxAge: null as number | null };
    const { writer, facts } = openDatagramWriter(dg);
    await writer.write(new Uint8Array([9, 2, 0, 0, 0]));
    expect(chunks).toHaveLength(1);
    expect(facts).toEqual({ api: 'writable', maxAgeOn: 'duplex' });
    expect(dg.outgoingMaxAge).toBe(OUTGOING_MAX_AGE_MS);
  });

  it('prefers the spec method when a UA ships both', () => {
    const spec = fakeWritable(true);
    const legacy = fakeWritable(false);
    const dg = { writable: legacy.ws, createWritable: () => spec.ws };
    expect(openDatagramWriter(dg).facts.api).toBe('createWritable');
  });

  it('reports no knob owner rather than pretending an expando took', () => {
    const { ws } = fakeWritable(false);
    const dg = { writable: ws };
    const { facts } = openDatagramWriter(dg);
    expect(facts.maxAgeOn).toBe('none');
    expect('outgoingMaxAge' in dg).toBe(false);
  });

  it('a UA with neither fails loudly, naming the cause', () => {
    expect(() => openDatagramWriter({})).toThrow(/neither createWritable\(\) nor writable/);
  });
});

describe('transportFacts carries the datagram API', () => {
  it('emits kh.transport.dg_api for the span', () => {
    setTransportFacts('https://labhost:8443/wt', {}, undefined, { api: 'createWritable', maxAgeOn: 'writable' });
    expect(transportAttrs('datagram')['kh.transport.dg_api']).toBe('createWritable');
    clearTransportFacts();
  });
  it('omits it when the caller did not say', () => {
    setTransportFacts('https://labhost:8443/wt', {});
    expect(transportAttrs('datagram')['kh.transport.dg_api']).toBeUndefined();
    clearTransportFacts();
  });
});

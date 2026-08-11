// capture-aus.mjs — capture a REAL sequence of Annex-B AUs from a live station.
// Opens a chromium page on the UI https origin (SecureContext), then from page
// context opens a raw WebTransport to the station (signal doc = /signal/<tile>.json)
// and records the first N video AUs (kind=1 uni-streams, 9-byte header + Annex-B),
// starting from the first KEY AU. Saves base64 JSON to ~/e2e/aus-<tile>.json.
//
// Usage: node capture-aus.mjs [station] [count]
import { chromium } from 'playwright';
import fs from 'node:fs';

const TILE = process.argv[2] || 'freedos';
const COUNT = Number(process.argv[3] || 30);
const ORIGIN = process.env.GALLERY_URL || 'https://192.0.2.10:8443';

const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--ignore-certificate-errors'] });
const page = await browser.newPage({ ignoreHTTPSErrors: true });
page.on('console', (m) => console.log('[page]', m.text().slice(0, 200)));
await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded' });

const result = await page.evaluate(async ({ tile, count }) => {
  const b64 = (u8) => {
    let s = '';
    for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  };
  const sig = await (await fetch(`/signal/${tile}.json`, { cache: 'no-store' })).json();
  const hashStr = sig.certHashB64 ?? sig.certHash ?? sig.hashB64 ?? sig.hash;
  const hash = Uint8Array.from(atob(hashStr), (c) => c.charCodeAt(0));
  // sig.path carries the signed session ticket when the station runs with
  // SH_SESSION_KEY; a hardcoded /wt is refused before accept() in that case.
  const url = sig.url ?? `https://${sig.host}:${sig.udpPort ?? sig.port}${sig.path ?? '/wt'}`;
  const wt = new WebTransport(url, { serverCertificateHashes: [{ algorithm: 'sha-256', value: hash.buffer }] });
  await wt.ready;

  const aus = []; // { frameId, isKey, ts, b64 }
  let started = false;
  let streamsSeen = 0;
  const deadline = performance.now() + 90000;

  const readAll = async (rs) => {
    const r = rs.getReader();
    const chunks = [];
    let len = 0;
    for (;;) {
      const { value, done } = await r.read();
      if (done) break;
      if (value && value.length) { chunks.push(value); len += value.length; }
    }
    const out = new Uint8Array(len);
    let o = 0;
    for (const c of chunks) { out.set(c, o); o += c.length; }
    return out;
  };

  const acceptor = wt.incomingUnidirectionalStreams.getReader();
  const pending = [];
  while (aus.length < count && performance.now() < deadline) {
    const race = await Promise.race([
      acceptor.read(),
      new Promise((r) => setTimeout(() => r('timeout'), Math.max(0, deadline - performance.now()))),
    ]);
    if (race === 'timeout') break;
    const { value: rs, done } = race;
    if (done) break;
    streamsSeen++;
    // handle each stream concurrently; per-frame streams FIN quickly
    pending.push((async () => {
      const buf = await readAll(rs);
      if (buf.length < 10 || buf[0] !== 1) return; // KIND_VIDEO=1 only
      const dv = new DataView(buf.buffer, buf.byteOffset + 1, 9);
      const frameId = dv.getUint32(0, true);
      const isKey = dv.getUint8(4) === 1;
      const ts = dv.getUint32(5, true);
      if (!started) { if (!isKey) return; started = true; }
      if (aus.length < count) aus.push({ frameId, isKey, ts, b64: b64(buf.subarray(10)) });
    })());
  }
  await Promise.allSettled(pending);
  try { wt.close(); } catch { /* noop */ }
  aus.sort((a, b) => a.frameId - b.frameId);
  return { url, streamsSeen, aus };
}, { tile: TILE, count: COUNT });

console.log(`captured ${result.aus.length} AUs from ${result.url} (${result.streamsSeen} streams seen)`);
if (result.aus.length) {
  const first = result.aus[0];
  console.log(`first: frameId=${first.frameId} key=${first.isKey} bytes=${atob(first.b64).length}`);
  console.log('keys at idx:', result.aus.map((a, i) => (a.isKey ? i : null)).filter((x) => x != null).join(','));
}
fs.writeFileSync(`${process.env.HOME}/e2e/aus-${TILE}.json`, JSON.stringify(result.aus));
console.log(`wrote ~/e2e/aus-${TILE}.json`);
await browser.close();
process.exit(result.aus.length > 0 && result.aus[0].isKey ? 0 : 1);

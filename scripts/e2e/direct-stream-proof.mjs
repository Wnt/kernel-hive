// Direct WebTransport framebuffer/input proof for a streamhost signaling file.
// It deliberately bypasses the gallery catalog, making it suitable for a
// throwaway tile that must never be added to the live lineup.
//
// Usage: node direct-stream-proof.mjs <signaling.json> <out-prefix> [scancodes]
// Example scancodes: 2e,18,20,12,2d ("codex", XT set 1). Omit for capture-only.
import { chromium } from 'playwright';
import fs from 'node:fs';

const signalPath = process.argv[2];
const outPrefix = process.argv[3];
const keys = (process.argv[4] || '').split(',').filter(Boolean).map((v) => Number.parseInt(v, 16));
if (!signalPath || !outPrefix || keys.some((v) => !Number.isInteger(v))) {
  console.error('usage: direct-stream-proof.mjs <signaling.json> <out-prefix> [hex-scancodes]');
  process.exit(2);
}
const sig = JSON.parse(fs.readFileSync(signalPath, 'utf8'));
const browser = await chromium.launch({
  headless: true, channel: 'chrome', args: ['--no-sandbox', '--ignore-certificate-errors'],
});
const page = await browser.newPage({ ignoreHTTPSErrors: true });
await page.goto(process.env.GALLERY_URL || 'https://192.0.2.10:8443/', {
  waitUntil: 'domcontentloaded', timeout: 30000,
});

const result = await page.evaluate(async ({ sig, keys }) => {
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const hash = Uint8Array.from(atob(sig.certHashB64), (c) => c.charCodeAt(0));
  // sig.path carries the signed session ticket when the tile runs with
  // SH_SESSION_KEY; a hardcoded /wt is refused before accept() in that case.
  const url = sig.url || `https://${sig.host}:${sig.udpPort}${sig.path || '/wt'}`;
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  let frames = 0;
  let configured = false;
  let decodeError = '';
  const decoder = new VideoDecoder({
    output(frame) {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth; canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0);
      frames++;
      frame.close();
    },
    error(error) { decodeError = String(error); },
  });
  const readAll = async (stream) => {
    const reader = stream.getReader();
    const chunks = []; let length = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value?.length) { chunks.push(value); length += value.length; }
    }
    const out = new Uint8Array(length); let offset = 0;
    for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.length; }
    return out;
  };
  const wt = new WebTransport(url, {
    serverCertificateHashes: [{ algorithm: 'sha-256', value: hash.buffer }],
  });
  const incoming = wt.incomingUnidirectionalStreams.getReader();
  const consume = (async () => {
    for (;;) {
      const { value, done } = await incoming.read();
      if (done) return;
      void (async () => {
        const buf = await readAll(value);
        if (buf.length < 11 || buf[0] !== 1) return;
        const dv = new DataView(buf.buffer, buf.byteOffset + 1, 9);
        const isKey = dv.getUint8(4) === 1;
        const timestamp = dv.getUint32(5, true);
        if (isKey && !configured) {
          decoder.configure({
            codec: sig.video?.codec || 'avc1.640028',
            optimizeForLatency: true,
            hardwareAcceleration: 'no-preference',
          });
          configured = true;
        }
        if (!configured) return;
        decoder.decode(new EncodedVideoChunk({
          type: isKey ? 'key' : 'delta', timestamp, data: buf.subarray(10),
        }));
      })();
    }
  })();
  await wt.ready;

  const keyStream = await wt.createUnidirectionalStream();
  const keyWriter = keyStream.getWriter();
  await keyWriter.write(new Uint8Array([1])); // ICLASS_KEY
  const deadline = performance.now() + 30000;
  while (frames < 2 && !decodeError && performance.now() < deadline) await delay(50);
  if (frames < 1) throw new Error(`no decoded framebuffer: ${decodeError || 'timeout'}`);
  await delay(300);

  const snapshot = () => {
    const image = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
    const sample = [];
    let nonBlack = 0;
    for (let y = 0; y < canvas.height; y += 2) {
      for (let x = 0; x < canvas.width; x += 2) {
        const i = (y * canvas.width + x) * 4;
        const value = (image[i] + image[i + 1] + image[i + 2]) / 3;
        sample.push(value);
        if (value > 12) nonBlack++;
      }
    }
    let fnv = 2166136261;
    for (const value of sample) { fnv ^= value | 0; fnv = Math.imul(fnv, 16777619); }
    return {
      sample, hash: (fnv >>> 0).toString(16).padStart(8, '0'),
      nonBlackPct: 100 * nonBlack / sample.length,
      png: canvas.toDataURL('image/png').split(',')[1], frames,
    };
  };
  const before = snapshot();
  let after = before; let changedSamples = 0;
  for (const scancode of keys) {
    for (const down of [1, 0]) {
      const record = new Uint8Array([3, down, scancode & 0xff, (scancode >> 8) & 0xff]);
      const framed = new Uint8Array(2 + record.length);
      framed[0] = record.length; framed.set(record, 2);
      await keyWriter.write(framed);
      await delay(35);
    }
  }
  if (keys.length) {
    const inputDeadline = performance.now() + 10000;
    while (performance.now() < inputDeadline) {
      await delay(100);
      after = snapshot();
      changedSamples = after.sample.reduce(
        (n, value, i) => n + (Math.abs(value - before.sample[i]) > 15 ? 1 : 0), 0,
      );
      if (changedSamples >= 20) break;
    }
  }
  try { await keyWriter.close(); } catch { /* session teardown */ }
  try { wt.close(); } catch { /* session teardown */ }
  void consume;
  decoder.close();
  return {
    url, width: canvas.width, height: canvas.height,
    before: { hash: before.hash, nonBlackPct: before.nonBlackPct, frames: before.frames, png: before.png },
    after: { hash: after.hash, nonBlackPct: after.nonBlackPct, frames: after.frames, png: after.png },
    changedSamples, sampleCount: before.sample.length, decodeError,
  };
}, { sig, keys });

fs.writeFileSync(`${outPrefix}-before.png`, Buffer.from(result.before.png, 'base64'));
if (keys.length) fs.writeFileSync(`${outPrefix}-after.png`, Buffer.from(result.after.png, 'base64'));
delete result.before.png; delete result.after.png;
console.log(JSON.stringify(result, null, 2));
await browser.close();
const inputOk = !keys.length || result.changedSamples >= 20;
process.exit(result.before.nonBlackPct > 0.05 && inputOk && !result.decodeError ? 0 : 1);

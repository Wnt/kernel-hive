// Measure live VideoDecoder decode() submit -> output latency and whether another
// chunk was submitted before each output (the signature of a one-frame DPB hold).
// Runs headed on CT950's VNC desktop.
// Usage: node decoder-buffer-probe.mjs [station label] [sample target]
import { chromium } from 'playwright';

const TILE = process.argv[2] || 'Solaris';
const TARGET = Number(process.argv[3] || 40);
const ORIGIN = process.env.GALLERY_URL || 'https://192.0.2.10:8443';

const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
await page.addInitScript(() => {
  const RealVideoDecoder = window.VideoDecoder;
  const pending = new Map();
  let submitted = 0;
  window.__decoderProbe = { configs: [], samples: [], submitted: 0, outputs: 0 };
  window.VideoDecoder = class extends RealVideoDecoder {
    constructor(init) {
      super({
        output: (frame) => {
          const now = performance.now();
          const item = pending.get(frame.timestamp);
          if (item) {
            window.__decoderProbe.samples.push({
              timestamp: frame.timestamp,
              ms: now - item.at,
              laterSubmits: submitted - item.order,
            });
            pending.delete(frame.timestamp);
          }
          window.__decoderProbe.outputs++;
          init.output(frame);
        },
        error: (error) => init.error(error),
      });
    }
    configure(config) {
      window.__decoderProbe.configs.push({
        codec: config.codec,
        optimizeForLatency: config.optimizeForLatency ?? null,
        hardwareAcceleration: config.hardwareAcceleration ?? null,
        descriptionBytes: config.description?.byteLength ?? 0,
      });
      return super.configure(config);
    }
    decode(chunk) {
      submitted++;
      window.__decoderProbe.submitted = submitted;
      pending.set(chunk.timestamp, { at: performance.now(), order: submitted });
      return super.decode(chunk);
    }
  };
  window.VideoDecoder.isConfigSupported = RealVideoDecoder.isConfigSupported.bind(RealVideoDecoder);
});

await page.goto(`${ORIGIN}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
const label = new RegExp(TILE, 'i');
let card = page.locator('button.os-card').filter({ hasText: label }).first();
if (await card.count() === 0) card = page.getByText(label).first();
await card.scrollIntoViewIfNeeded();
await card.click();

// Pointer motion is state-safe and gives damage-gated streams enough samples
// without waiting for keyframe heartbeats on an otherwise static desktop.
const deadline = Date.now() + 30000;
while (Date.now() < deadline) {
  const samples = await page.evaluate(() => window.__decoderProbe.samples.length);
  if (samples >= TARGET) break;
  const video = page.locator('video').filter({ has: page.locator('source') }).first();
  const candidate = await video.count() ? video : page.locator('video').first();
  const box = await candidate.boundingBox().catch(() => null);
  if (box) {
    const phase = samples % 8;
    await page.mouse.move(
      box.x + box.width * (0.35 + 0.04 * phase),
      box.y + box.height * (0.45 + 0.02 * (phase & 1)),
    );
  }
  await page.waitForTimeout(80);
}

const probe = await page.evaluate(() => window.__decoderProbe);
const values = probe.samples.map((sample) => sample.ms).sort((a, b) => a - b);
const percentile = (p) => values[Math.min(values.length - 1, Math.floor(values.length * p))] ?? null;
const held = probe.samples.filter((sample) => sample.laterSubmits > 0).length;
console.log(JSON.stringify({
  tile: TILE,
  configs: probe.configs,
  submitted: probe.submitted,
  outputs: probe.outputs,
  measured: values.length,
  decodeMs: {
    min: values[0] ?? null,
    p50: percentile(0.50),
    p95: percentile(0.95),
    max: values.at(-1) ?? null,
  },
  outputsAfterLaterSubmit: held,
  maxLaterSubmits: Math.max(0, ...probe.samples.map((sample) => sample.laterSubmits)),
}, null, 2));

await browser.close();
process.exit(values.length >= Math.min(10, TARGET) ? 0 : 1);

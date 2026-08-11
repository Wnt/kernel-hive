// Verify an unmodified WebCodecs-capable desktop browser stays on the normal
// WebTransport+WebCodecs path even though every station advertises the platform
// native WebRTC fallback.
import { chromium, firefox } from 'playwright';

const browserName = process.argv[2] || 'chromium';
const tile = process.argv[3] || 'win95';
const origin = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const launcher = browserName === 'firefox' ? firefox : chromium;
const headfulChrome = browserName === 'chromium' && process.env.HEADFUL === '1';
const browser = await launcher.launch(headfulChrome ? {
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
} : { headless: true });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
const errors = [];
page.on('pageerror', (error) => errors.push(String(error)));

await page.goto(`${origin}/os/${tile}`, { waitUntil: 'domcontentloaded', timeout: 30_000 });
let probe = null;
for (let i = 0; i < 30; i += 1) {
  await page.waitForTimeout(1_000);
  probe = await page.evaluate(() => {
    let bestNonBlack = 0;
    let paintedSurface = null;
    const measure = (source, width, height, kind) => {
      if (width < 320 || height < 200) return;
      const sample = document.createElement('canvas');
      sample.width = width;
      sample.height = height;
      const ctx = sample.getContext('2d');
      if (!ctx) return;
      ctx.drawImage(source, 0, 0);
      const data = ctx.getImageData(0, 0, width, height).data;
      let nonBlack = 0;
      let sampled = 0;
      for (let p = 0; p < data.length; p += 400) {
        sampled += 1;
        if (data[p] + data[p + 1] + data[p + 2] > 30) nonBlack += 1;
      }
      const pct = Math.round(100 * nonBlack / Math.max(1, sampled));
      if (pct >= bestNonBlack) {
        bestNonBlack = pct;
        paintedSurface = { kind, width, height, nonBlackPct: pct };
      }
    };
    for (const canvas of document.querySelectorAll('canvas')) {
      if (canvas.width < 320 || canvas.height < 200) continue;
      try {
        if (canvas.getContext('2d')) measure(canvas, canvas.width, canvas.height, 'canvas');
      } catch { /* a WebGL canvas is intentionally not readable as 2D */ }
    }
    for (const video of document.querySelectorAll('video')) {
      if (!video.srcObject || video.readyState < 2) continue;
      try { measure(video, video.videoWidth, video.videoHeight, 'video'); } catch { /* not ready */ }
    }
    return {
      videoDecoder: typeof globalThis.VideoDecoder !== 'undefined',
      fallbackDebug: typeof globalThis.__kernelHiveWebRtcDebug === 'function',
      bodyText: document.body.innerText.replace(/\s+/g, ' ').slice(0, 300),
      paintedSurface,
    };
  });
  if (probe.videoDecoder && !probe.fallbackDebug
      && probe.paintedSurface?.nonBlackPct > 5) break;
}

const pass = Boolean(probe?.videoDecoder && !probe?.fallbackDebug
  && probe?.paintedSurface?.nonBlackPct > 5);
console.log(JSON.stringify({ browserName, tile, pass, probe, errors: errors.slice(0, 10) }));
await browser.close();
process.exit(pass ? 0 : 1);

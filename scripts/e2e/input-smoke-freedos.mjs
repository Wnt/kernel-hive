// Input smoke for the per-class QUIC input client: open the freedos station,
// wait for live video pixels, press 'c' at the RETRO GAMES boot menu to get
// a Command prompt, type 'ver' + Enter, screenshot before/after.
//
// NOTE: the UI's 2D StreamView renders a <video> element fed by
// canvas.captureStream() from an OFFSCREEN canvas — there is no stream
// <canvas> in the document. Pixel probes must drawImage() the video onto a
// temp canvas and getImageData() from that.
import { chromium } from 'playwright';
import fs from 'node:fs';
const GALLERY_URL = process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const TS = Date.now();

const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });

const logs = [];
page.on('console', m => logs.push(`[console.${m.type()}] ${m.text().slice(0, 300)}`));
page.on('pageerror', e => logs.push(`[pageerror] ${String(e).slice(0, 300)}`));

await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
console.error('# grid loaded');

// Click the FreeDOS card via its bounding box (the <span> intercepts clicks).
const card = page.getByText(/FreeDOS/i).first();
await card.scrollIntoViewIfNeeded();
const box = await card.boundingBox();
if (!box) { console.log('FAIL: no FreeDOS card bounding box'); await browser.close(); process.exit(1); }
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);

// Probe the stream <video>: srcObject-backed, readyState, videoWidth, and a
// pixel sample via a temp canvas (drawImage + getImageData).
const probeVideos = () => {
  const out = [];
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = { w: v.videoWidth, h: v.videoHeight, readyState: v.readyState, paused: v.paused };
    if (rec.w > 0 && rec.h > 0 && v.readyState >= 2) {
      try {
        const c = document.createElement('canvas');
        c.width = rec.w; c.height = rec.h;
        const ctx = c.getContext('2d');
        ctx.drawImage(v, 0, 0);
        const d = ctx.getImageData(0, 0, rec.w, rec.h).data;
        let nonBlack = 0, n = 0;
        for (let i = 0; i < d.length; i += 400) { n++; if (d[i] + d[i + 1] + d[i + 2] > 30) nonBlack++; }
        rec.nonBlackPct = Math.round(100 * nonBlack / Math.max(1, n));
      } catch (e) { rec.err = String(e).slice(0, 80); }
    }
    out.push(rec);
  }
  return out;
};

// Wait for live stream pixels: poll the video until >1% non-black
// (the FreeDOS boot menu is mostly dark with a bright banner).
let live = false, stats = null;
for (let i = 0; i < 30 && !live; i++) {
  await page.waitForTimeout(1000);
  stats = await page.evaluate(probeVideos);
  live = stats.some(s => s.readyState >= 2 && s.nonBlackPct > 1);
  if (i % 5 === 0 || live) console.error(`# poll ${i}: ${JSON.stringify(stats)}`);
}
logs.push(`[video] ${JSON.stringify(stats)} live=${live}`);
await page.screenshot({ path: `${OUT}/freedos-before-type-${TS}.png` });
if (!live) {
  console.log(logs.join('\n')); console.log('FAIL: no live stream video');
  await browser.close(); process.exit(1);
}

// Focus the stream (click the video center) then drive the guest.
const video = page.locator('video').last();
const vbox = await video.boundingBox();
if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
await page.waitForTimeout(1500);

// FreeDOS golden boots to a RETRO GAMES menu: 'c' = Command prompt.
await page.keyboard.press('c');
await page.waitForTimeout(4000);
await page.keyboard.type('ver', { delay: 150 });
await page.waitForTimeout(500);
await page.keyboard.press('Enter');
await page.waitForTimeout(4000);

const after = await page.evaluate(probeVideos);
logs.push(`[video-after] ${JSON.stringify(after)}`);
await page.screenshot({ path: `${OUT}/freedos-after-ver-${TS}.png` });

console.log(logs.join('\n'));
const ok = after.some(s => s.readyState >= 2 && s.nonBlackPct > 1);
console.log(`${ok ? 'PASS' : 'FAIL'} screenshots: ${OUT}/freedos-before-type-${TS}.png ${OUT}/freedos-after-ver-${TS}.png`);
await browser.close();
process.exit(ok ? 0 : 1);

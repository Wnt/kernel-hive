// Open a tile (arg1, default FreeDOS), open the Stats HUD, dump innerText +
// console + a stream-<video> probe. Screenshots go to ~/e2e/shots/ with a
// timestamp (a fixed filename used to EACCES-collide with stale root-owned
// files in a shared scratchpad).
import { chromium } from 'playwright';
import fs from 'node:fs';
const GALLERY_URL = process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const TILE = process.argv[2] || 'FreeDOS';
const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
const logs = [];
page.on('console', m => logs.push(`[c.${m.type()}] ${m.text().slice(0, 400)}`));
page.on('pageerror', e => logs.push(`[pageerror] ${String(e).slice(0, 400)}`));

await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
const card = page.getByText(new RegExp(TILE, 'i')).first();
await card.scrollIntoViewIfNeeded();
const box = await card.boundingBox();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(6000);
// open stats HUD (button if present, else Ctrl+n toggle)
try { await page.getByText(/Stats/i).first().click({ timeout: 3000 }); }
catch (e) { logs.push(`[stats-click] ${e}`.slice(0, 200)); await page.keyboard.press('Control+n'); }
await page.waitForTimeout(6000);
// Stream health: the SPA renders a <video> fed from an offscreen canvas via
// captureStream — probe the video element, not document canvases.
const vids = await page.evaluate(() => {
  const out = [];
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = { w: v.videoWidth, h: v.videoHeight, readyState: v.readyState, paused: v.paused };
    if (rec.w > 0 && v.readyState >= 2) {
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
});
logs.push(`[video] ${JSON.stringify(vids)}`);
const shot = `${OUT}/${TILE.toLowerCase()}-stats-${Date.now()}.png`;
await page.screenshot({ path: shot });
const text = await page.evaluate(() => document.body.innerText.slice(0, 1500));
logs.push(`[body] ${text.replace(/\n/g, ' | ')}`);
console.log(logs.join('\n'));
console.log(`SHOT: ${shot}`);
await browser.close();

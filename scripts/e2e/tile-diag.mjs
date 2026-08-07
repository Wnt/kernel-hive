// Per-tile diagnostics: open each tile named on the CLI (default: FreeDOS),
// log console/pageerror/signal traffic, probe the stream <video> element
// (the SPA feeds a <video> from an offscreen canvas via captureStream — no
// stream <canvas> exists in the document), and screenshot to ~/e2e/shots/.
import { chromium } from 'playwright';
import fs from 'node:fs';
const GALLERY_URL = process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const names = process.argv.slice(2);
const TILES = (names.length ? names : ['FreeDOS']).map(n => ({ name: n, match: new RegExp(n, 'i') }));

const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });

const logs = [];
page.on('console', m => logs.push(`[console.${m.type()}] ${m.text().slice(0, 500)}`));
page.on('pageerror', e => logs.push(`[pageerror] ${String(e).slice(0, 500)}`));
page.on('response', async r => {
  if (r.url().includes('/signal/')) logs.push(`[net] ${r.status()} ${r.url()} :: ${(await r.text().catch(() => '?')).slice(0, 200)}`);
});

await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(2000);

for (const t of TILES) {
  logs.push(`\n===== TILE ${t.name} =====`);
  const card = page.getByText(t.match).first();
  try {
    await card.scrollIntoViewIfNeeded();
    const box = await card.boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  } catch (e) { logs.push(`[click-fail] ${t.name}: ${String(e).slice(0, 200)}`); continue; }
  await page.waitForTimeout(12000);
  const stats = await page.evaluate(() => {
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
  logs.push(`[video] ${JSON.stringify(stats)}`);
  await page.screenshot({ path: `${OUT}/diag-${t.name}-${Date.now()}.png` });
  await page.keyboard.press('Escape');
  await page.waitForTimeout(1500);
  await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);
}

console.log(logs.join('\n'));
await browser.close();

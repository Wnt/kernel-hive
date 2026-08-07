import { chromium } from 'playwright';
const GALLERY_URL = process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;
const OUT = process.env.HOME + '/e2e';
const browser = await chromium.launch({ headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' } });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
await page.goto(GALLERY_URL, { waitUntil: 'networkidle', timeout: 30000 });
await page.waitForTimeout(2000);
const card = page.getByText(/FreeDOS/i).first();
await card.scrollIntoViewIfNeeded();
const box = await card.boundingBox();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(14000);
// toggle stats overlay
await page.keyboard.press('Control+n');
await page.waitForTimeout(1500);
const hud = await page.evaluate(() => document.body.innerText.replace(/\n+/g, ' | ').slice(0, 900));
console.log('HUD:', hud);
const canv = await page.evaluate(() => {
  const out = [];
  for (const c of document.querySelectorAll('canvas')) {
    if (c.width < 100) continue;
    try { const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
      let nb = 0, n = 0; for (let i = 0; i < d.length; i += 400) { n++; if (d[i] + d[i+1] + d[i+2] > 30) nb++; }
      out.push({ w: c.width, h: c.height, nonBlackPct: Math.round(100 * nb / n) });
    } catch (e) { out.push({ w: c.width, err: String(e).slice(0, 60) }); }
  }
  return out;
});
console.log('CANVAS:', JSON.stringify(canv));
await page.screenshot({ path: `${OUT}/fd-check-${Date.now()}.png` }).catch(e => console.log('shot-skip'));
console.log('SHOT-DIR:', OUT);
await browser.close();

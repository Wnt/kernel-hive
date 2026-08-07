// Diagnostic: drive a PEN double-tap through the deployed client and let the
// daemon's own telemetry (SH_INPUT_TELEMETRY=1 on the tile) say what arrived.
//
//   node pen-doubletap-probe.mjs "Windows 3.11" 218 178
//
// A stylus takes the mouse path in useStreamInput (pointerType 'pen' is neither
// 'touch' nor a touch-archetype tile), which is exactly the path this exercises.
// Expect 6 button events for a double-tap: DOWN,UP then DOWN,UP,DOWN,UP, with
// the burst sharing one atMove (no reposition between the pair).
import { chromium } from '@playwright/test';

const [tile = 'Windows 3.11', gx = '218', gy = '178'] = process.argv.slice(2);
const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const GAP = Number(process.env.PROBE_GAP_MS ?? 180);
const OFF = Number(process.env.PROBE_OFFSET_PX ?? 5);

const browser = await chromium.launch({ headless: true, args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({
  ignoreHTTPSErrors: true, hasTouch: true, isMobile: true, viewport: { width: 900, height: 700 },
});
const page = await ctx.newPage();

await page.goto(`${URL_BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
const re = new RegExp(tile, 'i');
let card = page.locator('.os-card').filter({ hasText: re }).first();
if ((await card.count()) === 0) card = page.getByText(re).first();
await card.scrollIntoViewIfNeeded();
const cbox = await card.boundingBox();
if (!cbox) throw new Error(`no card for ${tile}`);
await page.mouse.click(cbox.x + cbox.width / 2, cbox.y + cbox.height / 2);

const surface = page.locator('video, canvas').first();
await surface.waitFor({ state: 'visible', timeout: 45000 });
await page.waitForTimeout(6000);
const box = await surface.boundingBox();
const res = await page.evaluate(() => {
  const v = document.querySelector('video');
  if (v && v.videoWidth) return { w: v.videoWidth, h: v.videoHeight };
  const c = document.querySelector('canvas');
  return c ? { w: c.width, h: c.height } : null;
});
const scale = Math.min(box.width / res.w, box.height / res.h);
const ox = box.x + (box.width - res.w * scale) / 2;
const oy = box.y + (box.height - res.h * scale) / 2;
const toClient = (x, y) => ({ x: ox + x * scale, y: oy + y * scale });
console.log(`surface ${res.w}x${res.h} scale ${scale.toFixed(3)}`);

async function penTap(gxx, gyy) {
  const pts = [[gxx, gyy], [gxx, gyy + 1], [gxx + 1, gyy + 2]].map(([x, y]) => toClient(x, y));
  await page.evaluate(async ({ pts: p }) => {
    const el = document.querySelector('video') || document.querySelector('canvas');
    const mk = (type, x, y, buttons) => new PointerEvent(type, {
      pointerId: 7, pointerType: 'pen', isPrimary: true, bubbles: true, cancelable: true,
      clientX: x, clientY: y, buttons, button: buttons ? 0 : -1, pressure: buttons ? 0.5 : 0,
    });
    el.dispatchEvent(mk('pointerdown', p[0].x, p[0].y, 1));
    for (const q of p.slice(1)) {
      el.dispatchEvent(mk('pointermove', q.x, q.y, 1));
      await new Promise((r) => setTimeout(r, 12));
    }
    const last = p[p.length - 1];
    el.dispatchEvent(mk('pointerup', last.x, last.y, 0));
  }, { pts });
}

console.log(`tap 1 at guest ${gx},${gy}`);
await penTap(Number(gx), Number(gy));
await page.waitForTimeout(GAP);
console.log(`tap 2 (+${GAP} ms, +${OFF} px)`);
await penTap(Number(gx) + OFF, Number(gy) + OFF);
await page.waitForTimeout(9000); // clientlog uploads are batched (~5s) — let them flush
await browser.close();
console.log('probe done');

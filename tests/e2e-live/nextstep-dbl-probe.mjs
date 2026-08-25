// Diagnostic: DOUBLE CLICK the nextstep exhibit through the whole deployed
// client — browser -> WebTransport -> streamhost -> the mamesock sink ->
// Previous's mamectl/1 control socket -> tablet.c -> the NeXTSTEP tablet driver
// — with real `page.mouse` input (CDP), not synthesised PointerEvents, so the
// SPA's own coordinate mapping and its click coalescing (if any) are part of
// what is under test.
//
//   node nextstep-dbl-probe.mjs single 224,226        # one click, then dwell
//   node nextstep-dbl-probe.mjs dbl 224,226           # page.mouse.dblclick
//   node nextstep-dbl-probe.mjs dbl 224,226 403,70    # several, in order
//
// The framebuffer is the only proof: pair it with a shot on the box between
// steps (tools/fbshm.py against the station's fb.shm). The dwell is generous
// because the injector's own floors (PREVIOUS_CTL_BTN_HOLD + _GAP) put ~240 ms
// between the two presses before the guest ever sees them.
//
// Why this file exists: nextstep-abs-probe.mjs proved MOTION and a held drag,
// and a double click takes a different path through the injector's queue — the
// one that lost the first click's release for as long as the station has been
// live (docs/guests/nextstep.md §4).
import { chromium } from '@playwright/test';

const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const DWELL = Number(process.env.PROBE_DWELL_MS ?? 6000);
const mode = process.argv[2] || 'dbl';
const targets = process.argv.slice(3).map((a) => a.split(',').map(Number));
if (!targets.length) throw new Error('give at least one guest x,y target');

const browser = await chromium.launch({ headless: true, args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 1000 } });
const page = await ctx.newPage();

await page.goto(`${URL_BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
const re = /NeXTSTEP/i;
let card = page.locator('.os-card').filter({ hasText: re }).first();
if ((await card.count()) === 0) card = page.getByText(re).first();
await card.scrollIntoViewIfNeeded();
const cbox = await card.boundingBox();
if (!cbox) throw new Error('no NeXTSTEP card in the grid');
await page.mouse.click(cbox.x + cbox.width / 2, cbox.y + cbox.height / 2);

const surface = page.locator('video, canvas').first();
await surface.waitFor({ state: 'visible', timeout: 45000 });
await page.waitForTimeout(8000);
const box = await surface.boundingBox();
const res = await page.evaluate(() => {
  const v = document.querySelector('video');
  if (v && v.videoWidth) return { w: v.videoWidth, h: v.videoHeight };
  const c = document.querySelector('canvas');
  return c ? { w: c.width, h: c.height } : null;
});
if (!res) throw new Error('no live surface');
const scale = Math.min(box.width / res.w, box.height / res.h);
const ox = box.x + (box.width - res.w * scale) / 2;
const oy = box.y + (box.height - res.h * scale) / 2;
const toClient = (x, y) => [ox + (x + 0.5) * scale, oy + (y + 0.5) * scale];
console.log(`surface ${res.w}x${res.h} scale ${scale.toFixed(4)} origin ${ox.toFixed(1)},${oy.toFixed(1)}`);

// A move first, and a settle: the injector holds a button edge behind an
// unconverged pointer, and the FIRST move of a fresh session can land short
// (the session's wake and the sink's resync preamble share that moment).
for (const [gx, gy] of targets) {
  const [cx, cy] = toClient(gx, gy);
  await page.mouse.move(cx, cy, { steps: 8 });
  console.log(`${Date.now()} move guest ${gx},${gy}`);
  await page.waitForTimeout(1500);
  if (mode === 'dbl') {
    await page.mouse.dblclick(cx, cy);
    console.log(`${Date.now()} DBLCLICK guest ${gx},${gy}`);
  } else {
    await page.mouse.click(cx, cy);
    console.log(`${Date.now()} click guest ${gx},${gy}`);
  }
  await page.waitForTimeout(DWELL);
}

await browser.close();

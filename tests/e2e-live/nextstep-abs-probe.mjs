// Diagnostic: drive the nextstep exhibit's ABSOLUTE pointer through the whole
// deployed client — browser -> WebTransport -> streamhost -> the mamesock sink
// -> Previous's mamectl/1 control socket -> tablet.c -> the NeXTSTEP tablet
// driver — and print the schedule it drove, so a framebuffer poller on the box
// can say where the NeXT arrow actually was. (Before 2026-08-25 the middle of
// that chain was a QEMU usb-tablet, an Xorg and an SDL window in a captured
// Debian kiosk; the station is host-native now and has none of them.)
//
//   node nextstep-abs-probe.mjs 8,8 1111,823 560,416      # guest pixels
//
// It uses real page.mouse input (CDP), not synthesised PointerEvents, so the
// SPA's own coordinate mapping is part of what is under test. With the tile's
// `pointerRel` gone from the manifest there is no pointer lock: client
// coordinates map straight onto the 1120x832 guest screen.
//
// Pair it with, ON THE BOX, a poller that locates the NeXT arrow glyph and
// prints `epoch_ms x y`; every dwell window must contain the commanded target
// and nothing else. There is no QMP here any more — read the guest straight out
// of the shm framebuffer:
//
//   python3 -c "import sys; sys.path.insert(0, '<repo>/scripts/build-guests/nextstep');
//   import nextstep_rig as R; ..."   # R.Fb(...).rgb() + R.Rig.locate
//
// Measured 2026-08-25 through the deployed SPA: commanded 1000,700 -> arrow
// (1000,700); 300,200 -> (300,200); a button-held drag to 450,500 -> (450,500).
// The FIRST move of a fresh session can land short of its target (the session's
// wake and the sink's resync preamble share that moment); every move after it
// is exact.
import { chromium } from '@playwright/test';

const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const DWELL = Number(process.env.PROBE_DWELL_MS ?? 6000);
const args = process.argv.slice(2);
const targets = (args.length ? args : ['8,8', '1111,8', '8,823', '1111,823', '560,416'])
  .map((a) => a.split(',').map(Number));

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

for (const [gx, gy] of targets) {
  const [cx, cy] = toClient(gx, gy);
  await page.mouse.move(cx, cy, { steps: 8 });
  console.log(`${Date.now()} move guest ${gx},${gy} (client ${cx.toFixed(1)},${cy.toFixed(1)})`);
  await page.waitForTimeout(DWELL);
}

// Buttons and drag over the same wire: press at the last target, walk 150,300
// with the button held, release. On a NeXTSTEP title bar that moves a window.
const [dx0, dy0] = targets[targets.length - 1];
const [sx, sy] = toClient(dx0, dy0);
const [ex, ey] = toClient(dx0 + 150, dy0 + 300);
await page.mouse.move(sx, sy);
await page.mouse.down();
console.log(`${Date.now()} drag from ${dx0},${dy0}`);
await page.mouse.move(ex, ey, { steps: 15 });
await page.waitForTimeout(500);
await page.mouse.up();
console.log(`${Date.now()} drag to ${dx0 + 150},${dy0 + 300}`);
await page.waitForTimeout(DWELL);

await browser.close();
console.log('probe done');

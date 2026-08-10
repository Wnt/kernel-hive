// Diagnostic: drive the `star` exhibit's RELATIVE pointer through the whole
// deployed client — browser -> WebTransport -> streamhost's abs->rel bridge
// (corner-pin home, difference, <=256 px chunks, 16 ms pacing) -> QEMU PS/2 ->
// Linux X (acceleration off) -> SDL -> Darkstar's dx-from-DisplayBox-centre ->
// the Star's own cursor — and print the schedule it drove, so a framebuffer
// poller on the box can say where the Star arrow actually was.
//
//   node star-rel-probe.mjs 200,200 880,700 544,430      # guest pixels
//
// The Star has NO absolute pointer path (see docs/guests/star.md), so the SPA
// still sends absolute video coordinates and the DAEMON relativizes them. That
// is the whole point of the test: an absolute target must still land, because
// the bridge homes into the corner on its first sample and dead-reckons from
// there. Real `page.mouse` input (CDP), not synthesised PointerEvents, so the
// SPA's own coordinate mapping is part of what is under test.
//
// Pair it with, ON THE BOX, `python3 /root/starcur.py` in each dwell window —
// it finds the solid black arrow on the 50 %-dither desk and prints its tip.
import { chromium } from '@playwright/test';

const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const DWELL = Number(process.env.PROBE_DWELL_MS ?? 9000);
const args = process.argv.slice(2);
const targets = (args.length ? args : ['200,200', '880,700', '544,430'])
  .map((a) => a.split(',').map(Number));

const browser = await chromium.launch({ headless: true, args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 1000 } });
const page = await ctx.newPage();

await page.goto(`${URL_BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
const re = /Xerox Star/i;
let card = page.locator('.os-card').filter({ hasText: re }).first();
if ((await card.count()) === 0) card = page.getByText(re).first();
await card.scrollIntoViewIfNeeded();
const cbox = await card.boundingBox();
if (!cbox) throw new Error('no Xerox Star card in the grid');
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

// Start the walk where the pointer ACTUALLY is (the card we clicked), so the
// first target is reached by real travel. Handing the first target no travel at
// all is a trap: on a relative tile the session's very first sample only seeds
// the origin, so a target reached in one teleport never moves the guest and the
// whole run reads as broken tracking.
let last = { x: cbox.x + cbox.width / 2, y: cbox.y + cbox.height / 2 };
for (const [gx, gy] of targets) {
  const [cx, cy] = toClient(gx, gy);
  // Move the way a HAND moves — small steps spread over real time — not the
  // way `page.mouse.move(..., {steps})` moves, which emits every intermediate
  // sample inside a millisecond. That distinction is not cosmetic on a relative
  // tile: the daemon's homing pin holds the pointer mutex for its settle on the
  // first sample of a session, so a whole burst delivered inside that window is
  // lost and the session inherits an offset the size of the burst. A hand loses
  // only the few pixels it travelled during the settle.
  const from = last;
  const N = 40;
  for (let i = 1; i <= N; i++) {
    await page.mouse.move(from.x + ((cx - from.x) * i) / N, from.y + ((cy - from.y) * i) / N);
    await page.waitForTimeout(25);
  }
  last = { x: cx, y: cy };
  console.log(`${Date.now()} move guest ${gx},${gy} (client ${cx.toFixed(1)},${cy.toFixed(1)})`);
  await page.waitForTimeout(DWELL);
}

await browser.close();

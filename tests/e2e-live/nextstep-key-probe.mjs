// Diagnostic: type into the nextstep exhibit through the WHOLE deployed client —
// browser -> WebTransport -> streamhost -> the mamesock sink -> Previous's
// mamectl/1 control socket -> kms.c -> the NeXTSTEP keyboard driver — and leave
// the result on the guest's own framebuffer, where a poller on the box reads it.
//
//   node nextstep-key-probe.mjs [text] [delay_ms]
//
// `delay_ms` is Playwright's inter-key delay; the press and its release are
// ALWAYS the same tick, which is exactly what a phone's soft keyboard sends and
// what the 2026-08-25 one-key-in-ten bug was made of (docs/guests/nextstep.md
// §4). Run it with 0 AND with something human (120) — the fast case is the one
// that hides when a test client waits for acks.
//
// It types into OmniWeb's URL field, which is a text field the golden already
// has on screen; a `systemctl restart streamhost@nextstep` puts the scene back.
import { chromium } from '@playwright/test';

const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const TEXT = process.argv[2] ?? 'the quick brown fox';
const DELAY = Number(process.argv[3] ?? 0);
// OmniWeb's EDITABLE URL field in guest pixels, in the golden scene. Not the grey
// strip at y=227: that one is the read-only location display and swallows every
// keystroke silently, which is a fine way to misread a working keyboard as broken.
const FIELD = [400, 149];

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

// Focus the URL field: a click, then select-all so the typing replaces it.
const [fx, fy] = toClient(FIELD[0], FIELD[1]);
await page.mouse.move(fx, fy, { steps: 8 });
await page.waitForTimeout(1500);
// A DOUBLE click, not a single: it selects the word under the pointer, which is
// unambiguous proof on the framebuffer that the field took first responder, and
// it makes the typing REPLACE rather than insert.
await page.mouse.dblclick(fx, fy);
await page.waitForTimeout(4000);
console.log(`${Date.now()} focused the URL field at guest ${FIELD}`);

console.log(`${Date.now()} typing ${TEXT.length} characters, delay ${DELAY} ms`);
await page.keyboard.type(TEXT, { delay: DELAY });
console.log(`${Date.now()} typed`);
await page.waitForTimeout(6000);
await browser.close();
console.log('probe done');

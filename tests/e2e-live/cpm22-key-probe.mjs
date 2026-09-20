// Diagnostic: type into the cpm22 exhibit through the WHOLE deployed client —
// browser -> WebTransport -> streamhost -> the mamesock sink -> MAME's ctlsock
// module -> the kayproii driver's natural-keyboard path -> CP/M's CCP — and
// leave the result on the guest's own framebuffer, where a poller on the box
// reads it (labctl shot). Kaypro II is keyboard-only: no pointer, no field to
// click first, the whole screen is the CP/M A> prompt already.
//
//   node cpm22-key-probe.mjs [text] [delay_ms]
//
// `delay_ms` is Playwright's inter-key delay; 0 is the worst case (SPA key
// bursts becoming chords is the fleet's documented MAME-keyboard trap —
// docs/lab/) and 120 is closer to a human tap.
//
// REQUIRES AN AUTHENTICATED admin/viewer SESSION (pass --storage-state via
// Playwright, or run this from a context that already has one). Confirmed
// 2026-09-20 (cpm22 landing): `/os/:osId` only mounts the live <video>/
// <canvas> for role admin/viewer (spa/src/ui/grid/exhibitAccess.ts,
// `exhibitViewFor`); every other role — anonymous or walk-in — gets the
// read-only ExhibitPoster (year/lineage/RAM/screenshot) instead, by design,
// and a fresh unauthenticated Playwright context (as this repo's sandbox has
// no passkey credentials to complete a WebAuthn ceremony with) can never
// reach the stream no matter what it clicks. Verified this is NOT a cpm22
// regression: an unmodified nextstep-key-probe.mjs run against the same
// deployed gallery hits the identical "no video/canvas" timeout. Run this
// script from a session that already holds an authenticated storageState
// (e.g. an operator's e2e box) for the real proof; per the operating rules
// ("don't automate what the operator can eyeball"), the alternative is
// simply handing the operator the /os/cpm22 URL.
import { chromium } from '@playwright/test';

const URL_BASE = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const TEXT = process.argv[2] ?? 'DIR';
const DELAY = Number(process.argv[3] ?? 120);

const browser = await chromium.launch({ headless: true, args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1400, height: 1000 } });
const page = await ctx.newPage();
page.on('console', (m) => {
  if (m.type() === 'error') console.log(`[console.error] ${m.text().slice(0, 300)}`);
});
page.on('pageerror', (e) => console.log(`[pageerror] ${String(e).slice(0, 300)}`));

await page.goto(`${URL_BASE}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
// cpm22 (era_year 1982) lives in the collapsed "1980s" decade group; expand
// it before looking for the card, same as every other pre-1990 station.
await page.getByText('1980s', { exact: false }).first().click();
await page.waitForTimeout(1500);
const re = /kaypro/i;
let card = page.locator('.os-card').filter({ hasText: re }).first();
if ((await card.count()) === 0) card = page.getByText(re).first();
await card.scrollIntoViewIfNeeded();
const cbox = await card.boundingBox();
if (!cbox) throw new Error('no Kaypro card in the grid');
await page.mouse.click(cbox.x + cbox.width / 2, cbox.y + cbox.height / 2);
console.log(`${Date.now()} clicked the cpm22 card`);

await page.waitForTimeout(3000);
console.log('url after click:', page.url());
// With an authenticated admin/viewer session, /os/cpm22 mounts the live
// stream directly (ExhibitView 'stream') -- no further click needed. With
// any other role it stays on the read-only ExhibitPoster notes forever, see
// the header comment.
const surface = page.locator('video, canvas').first();
await surface.waitFor({ state: 'visible', timeout: 45000 });
await page.waitForTimeout(8000);
const box = await surface.boundingBox();

// Click the middle of the surface to give the page/canvas keyboard focus —
// this station has no pointer transport, so the click is only a focus grab,
// never delivered to the guest (stream.pointer.transport === 'none').
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
await page.waitForTimeout(1000);
console.log(`${Date.now()} focused the stream surface`);

console.log(`${Date.now()} typing ${JSON.stringify(TEXT)}, delay ${DELAY} ms`);
await page.keyboard.type(TEXT, { delay: DELAY });
await page.keyboard.press('Enter');
console.log(`${Date.now()} typed + Enter`);
await page.waitForTimeout(4000);
await browser.close();
console.log('probe done');

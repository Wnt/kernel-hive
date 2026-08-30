import { chromium } from 'playwright';
const BASE = process.argv[2];
const browser = await chromium.launch({ args: ['--no-sandbox', '--ignore-certificate-errors'] });
const p = await (await browser.newContext({ ignoreHTTPSErrors: true })).newPage();
const errs = [];
p.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });
await p.goto(`${BASE}?role=walkin`, { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(3000);
const before = await p.evaluate(() => document.querySelectorAll('.os-card').length);
await p.click('.grid-scope button:nth-child(2)');   // "The whole museum"
await p.waitForTimeout(1200);
const after = await p.evaluate(() => ({
  cards: document.querySelectorAll('.os-card').length,
  placards: document.querySelectorAll('.os-card--placard').length,
  playable: document.querySelectorAll('.walkin-tag--playable').length,
  placardHref: document.querySelector('.os-card--placard')?.getAttribute('href'),
}));
// Clicking a placard must open the poster overlay, not navigate away.
await p.click('.os-card--placard');
await p.waitForTimeout(1200);
const overlay = await p.evaluate(() => ({
  poster: !!document.querySelector('[class*="exhibit-poster"]'),
  path: location.pathname,
}));
await p.screenshot({ path: `${process.env.HOME}/e2e/shots/walkin-placard-${Date.now()}.png` });
console.log('before', before, 'after', JSON.stringify(after), 'overlay', JSON.stringify(overlay));
console.log('ERRORS', JSON.stringify(errs.slice(0, 6)));
await browser.close();
const fail = [];
if (!(after.cards > before)) fail.push('scope switch did not widen the lineup');
if (after.placards === 0) fail.push('no placard cards at full scope');
if (after.playable !== 3) fail.push(`expected 3 playable, got ${after.playable}`);
if (!overlay.poster) fail.push('placard click did not open the exhibit poster');
if (!overlay.path.endsWith('/')) fail.push(`placard click navigated away to ${overlay.path}`);
console.log(fail.length ? `FAIL ${JSON.stringify(fail)}` : 'PASS');

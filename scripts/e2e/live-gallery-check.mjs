import { chromium } from 'playwright';
const BASE = process.argv[2];
const b = await chromium.launch({ args: ['--no-sandbox','--ignore-certificate-errors'] });
const p = await (await b.newContext({ ignoreHTTPSErrors: true })).newPage();
const errs = []; p.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
await p.goto(BASE, { waitUntil: 'domcontentloaded' });
await p.waitForTimeout(4000);
const r = await p.evaluate(() => ({
  cards: document.querySelectorAll('.os-card').length,
  nav: [...document.querySelectorAll('.appbar-seg a')].map(a=>a.textContent.trim()),
  stuck: document.body.innerText.includes('Loading the collection'),
  scope: !!document.querySelector('.grid-scope'),
  href: document.querySelector('.os-card')?.getAttribute('href'),
}));
await p.screenshot({ path: `${process.env.HOME}/e2e/shots/live-gallery-${Date.now()}.png` });
console.log(JSON.stringify(r)); console.log('ERRORS', JSON.stringify(errs.slice(0,6)));
await b.close();
const fail=[];
if (r.stuck) fail.push('live gallery stuck on loading');
// The grid FOLDS: only the eras open on a first visit render cards, so this is
// a "did the gallery render at all" check, not a census. live-fold-check.mjs
// expands every era and asserts the announced total instead.
if (r.cards < 10) fail.push(`only ${r.cards} cards rendered`);
if (r.scope) fail.push('invited session got a walk-in scope switch');
if (!r.nav.includes('Fleet table')) fail.push('lost the fleet nav');
if (!r.href?.startsWith('/os/')) fail.push(`bad card target ${r.href}`);
console.log(fail.length?`FAIL ${JSON.stringify(fail)}`:'PASS');

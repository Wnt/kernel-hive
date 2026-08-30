// Does the merged grid actually RENDER for each visitor class?
// The bug was a page that loaded and then showed "Loading the collection…"
// for ever, so the only proof that matters is what is on the page.
import { chromium } from 'playwright';

const BASE = process.argv[2];
const shots = `${process.env.HOME}/e2e/shots`;

async function look(page, url, label) {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForTimeout(3000);
  const out = await page.evaluate(() => ({
    cards: document.querySelectorAll('.os-card').length,
    playable: document.querySelectorAll('.walkin-tag--playable').length,
    placards: document.querySelectorAll('.os-card--placard').length,
    scopeSwitch: !!document.querySelector('.grid-scope'),
    navLinks: [...document.querySelectorAll('.appbar-seg a')].map((a) => a.textContent.trim()),
    stuck: document.body.innerText.includes('Loading the collection'),
    firstCardHref: document.querySelector('.os-card')?.getAttribute('href') ?? null,
  }));
  await page.screenshot({ path: `${shots}/${label}-${Date.now()}.png`, fullPage: false });
  console.log(label, JSON.stringify(out));
  return out;
}

const browser = await chromium.launch({ args: ['--no-sandbox', '--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newContext ? null : null;
const p = await ctx.newPage();
const errors = [];
p.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });

const invited = await look(p, `${BASE}?role=viewer`, 'invited-root');
const walkin = await look(p, `${BASE}?role=walkin`, 'walkin-root');
await p.click('.grid-scope button:nth-child(2)');
await p.waitForTimeout(600);
const wide = await look(p, `${BASE}?role=walkin`, 'walkin-root-again');

console.log('CONSOLE_ERRORS', JSON.stringify(errors.slice(0, 8)));
await browser.close();

const fail = [];
if (invited.stuck || invited.cards === 0) fail.push('invited grid empty');
if (walkin.stuck) fail.push('walk-in grid stuck on loading');
if (walkin.cards === 0) fail.push('walk-in grid has no cards');
if (!walkin.scopeSwitch) fail.push('walk-in has no scope switch');
if (walkin.playable === 0) fail.push('walk-in has no playable card');
if (invited.scopeSwitch) fail.push('invited visitor got a scope switch');
if (!invited.navLinks.includes('Fleet table')) fail.push('invited lost the fleet nav');
if (walkin.navLinks.includes('Fleet table')) fail.push('walk-in was offered the fleet table');
console.log(fail.length ? `FAIL ${JSON.stringify(fail)}` : 'PASS');

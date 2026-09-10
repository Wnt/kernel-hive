import { chromium } from 'playwright';

// landing-hero-probe — does `/` hand a stranger a machine they can drive?
//
// Four modes, because the landing page has four states that can each be broken
// on their own and none of which a unit test can reach: the SPA's vitest runs
// under plain Node with no jsdom, so every component on that page is gated by
// this script and by nothing else. Every defect it has caught so far (see the
// list below) was invisible in the source and obvious in a browser.
//
//   live    (default) one page load: does a machine claim, connect and paint,
//           and does the collection render under it? Asserts ONE claim — the
//           header slot's key regression, where GridView's two child lists
//           remounted the hero the moment the manifest landed and the page
//           took two cells out of a pool of eight.
//   switch  press the second station chip: RELEASE must precede CLAIM, the new
//           machine must paint, and pressing the chip already on screen must
//           make no calls at all.
//   nocaps  a browser with neither WebTransport+WebCodecs nor WebRTC. It must
//           claim NOTHING, show the poster, and print the honest line ON the
//           poster — `filter` on the <img> gives it a stacking context, so the
//           veil needs a position or the sentence paints behind the picture.
//   anon    `?walkin=anon` forces the fixture's 60-second budget: the countdown
//           must mirror it down to zero and the wall must arrive over the stage
//           with both ways through it.
//
// Run from ~/e2e on CT950 (see the node_modules note in this directory's
// README), against a staged slot or the live origin:
//   node landing-hero-probe.mjs https://<lab>:8443/staging/<slot>/ switch

const BASE = process.argv[2];
const MODE = process.argv[3] ?? 'live';
if (!BASE) { console.error('usage: landing-hero-probe.mjs <base-url> [live|switch|nocaps|anon]'); process.exit(2); }

const browser = await chromium.launch({ args: ['--no-sandbox', '--ignore-certificate-errors'] });
const page = await (await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 900 } })).newPage();

const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
const calls = [];
page.on('request', (r) => {
  const path = new URL(r.url()).pathname;
  if (path.startsWith('/walkin')) calls.push(`${r.method()} ${path}`);
});

if (MODE === 'nocaps') {
  await page.addInitScript(() => {
    delete window.WebTransport; delete window.VideoDecoder; delete window.RTCPeerConnection;
  });
}

const read = () => page.evaluate(() => {
  const q = (s) => document.querySelector(s);
  const video = q('.landing-stage video');
  return {
    fatal: !!q('.fatal-error'),
    strip: [...document.querySelectorAll('.landing-strip__cell')].map((e) => e.textContent),
    station: q('.landing-chip--active .landing-chip__name')?.textContent ?? null,
    picture: video ? `${video.videoWidth}x${video.videoHeight}` : null,
    streaming: !!q('.landing-stage .sv-root'),
    poster: !!q('.landing-stage__poster'),
    // elementsFromPoint, not a class check: the veil regression was a PAINT
    // ORDER bug, and only the hit-test stack can see one.
    onTop: (() => {
      const stage = q('.landing-stage');
      if (!stage) return null;
      const r = stage.getBoundingClientRect();
      const el = document.elementFromPoint(Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2));
      return el ? `${el.tagName}.${el.className}` : null;
    })(),
    veil: q('.landing-stage__veil-line')?.textContent?.slice(0, 60) ?? null,
    countdown: q('.landing-countdown__value')?.textContent ?? null,
    wall: q('.landing-gate__title')?.textContent ?? null,
    cta: [...document.querySelectorAll('.landing-hero__cta .landing-btn')]
      .map((e) => `${e.className.includes('primary') ? 'PRIMARY' : 'quiet'}:${e.textContent}`),
    cards: document.querySelectorAll('.os-card').length,
    stuck: document.body.innerText.includes('Loading the collection'),
    focused: document.activeElement?.className ?? '',
  };
});

const fail = [];
await page.goto(MODE === 'anon' ? `${BASE}?walkin=anon` : BASE, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(MODE === 'nocaps' ? 6000 : 12000);
const first = await read();
console.log('LOAD  ', JSON.stringify(first));
console.log('CALLS ', JSON.stringify(calls));

if (first.fatal) fail.push('the page failed to mount');
if (first.stuck) fail.push('the collection never loaded');
// The filter belongs to the collection, not to the hero: above the fold every
// keystroke goes to a live guest, and an autofocused search box eats them.
if (first.focused.includes('grid-filter-input')) fail.push('the grid filter stole focus from the guest');

if (MODE === 'nocaps') {
  if (calls.some((c) => c.includes('claim'))) fail.push('an unplayable browser claimed a cell');
  if (!first.poster) fail.push('no poster hero for an unplayable browser');
  if (!first.onTop?.includes('veil')) fail.push(`the poster veil is painting behind the picture (${first.onTop})`);
} else {
  const claims = calls.filter((c) => c.includes('claim')).length;
  if (claims !== 1) fail.push(`${claims} claims on one page load (expected exactly 1)`);
  if (!first.streaming) fail.push('no stream mounted');
  if (!first.picture || first.picture.startsWith('0x')) fail.push(`nothing decoded (${first.picture})`);
  if (first.strip[0] !== 'RUNNING') fail.push(`strip says ${first.strip[0]}, not RUNNING`);
}

if (MODE === 'switch') {
  calls.length = 0;
  // The station is chosen at RANDOM by the server, so `nth-child(2)` is a coin
  // flip on whether this presses the machine already on screen — which is
  // correctly a no-op and would read as a broken switch. Pick a chip that is
  // demonstrably not the active one.
  const other = page.locator('.landing-chip:not(.landing-chip--active)').first();
  await other.click();
  await page.waitForTimeout(9000);
  const after = await read();
  console.log('SWITCH', JSON.stringify(after), JSON.stringify(calls));
  const release = calls.findIndex((c) => c.includes('release'));
  const claim = calls.findIndex((c) => c.includes('claim'));
  if (release < 0 || claim < 0) fail.push(`switch did not release+claim (${calls})`);
  else if (release > claim) fail.push('the switch CLAIMED before it RELEASED — one clone per account');
  if (after.station === first.station) fail.push('the switch did not change the machine');
  if (!after.picture || after.picture.startsWith('0x')) fail.push('the switched-to machine never painted');

  calls.length = 0;
  await page.click('.landing-chip--active');
  await page.waitForTimeout(1500);
  console.log('SAME  ', JSON.stringify(calls));
  if (calls.length > 0) fail.push('pressing the machine already on screen spent a claim');
}

if (MODE === 'anon') {
  if (!first.countdown) fail.push('no countdown for an anonymous visitor');
  for (let i = 0; i < 7 && !(await read()).wall; i += 1) await page.waitForTimeout(10_000);
  const walled = await read();
  console.log('WALL  ', JSON.stringify(walled));
  if (!walled.wall) fail.push('the budget ran out and no wall appeared');
  if (walled.countdown !== '0:00') fail.push(`countdown stopped at ${walled.countdown}`);
}

const shot = `${process.env.HOME}/e2e/shots/landing-${MODE}-${Date.now()}.png`;
await page.screenshot({ path: shot });
console.log('ERRORS', JSON.stringify(errors.slice(0, 6)));
console.log('SHOT  ', shot);
await browser.close();
if (errors.length) fail.push(`${errors.length} console/page error(s)`);
console.log(fail.length ? `FAIL ${JSON.stringify(fail)}` : 'PASS');
process.exit(fail.length ? 1 : 0);

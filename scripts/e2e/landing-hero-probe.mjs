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
//   anon    `?walkin=anon` forces the fixture's 60-second budget: the wall must
//           arrive over the stage with both ways through it, and its clock must
//           read 0:00. The HERO carries no clock — a visitor gets no warning
//           that their intro time is running out, they meet the wall, and that
//           is the operator's decision (see LandingTop). The budget starts at
//           the first touch, so this mode clicks the machine once and waits.
//   engage  THE ENGAGEMENT RULE, which exists because of two bugs an operator
//           hit on the live site and neither of which any unit test can see:
//           the intro time started at the CLAIM (so it burned while they read
//           the page), and the machine handed back by the idle watchdog came
//           back as a DIFFERENT OS. So this mode drives a real browser and
//           asserts, in order: forty seconds of moving the mouse across the
//           canvas neither starts the clock nor releases the cell nor changes
//           the station; ONE CLICK starts it; and the wall then arrives a
//           minute after the CLICK rather than a minute after the load — which,
//           with no clock on the hero any more, is the observable that says
//           where the minute began. It needs a plane that implements
//           `POST /walkin/engage`; against one that does not (a box not yet
//           deployed), set HERO_STUB_ENGAGE=1 and the SPA's own fixture stands
//           in, which is the same code path a staged build has always used.
//   recover the slow sibling: wait out the whole un-engaged window and then
//           press the way back, which is the exact sequence that changed the
//           visitor's OS.
//   resume  the same proof in seconds, by backgrounding the tab — an
//           un-engaged cell goes back instantly when hidden — which is what
//           makes it cheap enough to run on every change.
//
// Run from ~/e2e on CT950 (see the node_modules note in this directory's
// README), against a staged slot or the live origin:
//   node landing-hero-probe.mjs https://<lab>:8443/staging/<slot>/ switch

const BASE = process.argv[2];
const MODE = process.argv[3] ?? 'live';
if (!BASE) { console.error('usage: landing-hero-probe.mjs <base-url> [live|switch|nocaps|anon|engage|recover|resume]'); process.exit(2); }

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
    // The wall's clock and headline. `.landing-countdown__value` and
    // `.landing-gate__title` used to be read here and have matched nothing for
    // some time — the component renders gate-* classes, checked in a browser.
    countdown: q('.gate-countdown-clock')?.textContent ?? null,
    clockLabel: q('.gate-countdown-label')?.textContent ?? null,
    wall: q('.gate-title')?.textContent ?? null,
    // The caption under the stage. With no clock on the hero this is where the
    // page says whether the visitor's intro time has started.
    caption: q('.landing-caption')?.textContent?.slice(0, 160) ?? null,
    cards: document.querySelectorAll('.os-card').length,
    stuck: document.body.innerText.includes('Loading the collection'),
    focused: document.activeElement?.className ?? '',
  };
});

const fail = [];
// A plane without `/walkin/engage` answers 404 and the SPA falls through to its
// own fixture (walkin/api.ts `notBuiltYet`) — which is exactly the state of a
// box that has not been deployed yet. Making that explicit here means the
// engage run proves the same code path whether or not the server half is live.
// `anon` is the FIXTURE preview by definition — it forces /walkin/state to the
// local stub — so its engagement has to be stubbed too, or the preview clock
// would wait on a server whose answer it is not reading anyway.
const stubEngage = MODE === 'anon'
  || (process.env.HERO_STUB_ENGAGE === '1' && ['engage', 'recover', 'resume'].includes(MODE));
if (stubEngage) {
  await page.route('**/walkin/engage', (route) => route.fulfill({
    status: 404, contentType: 'application/json', body: '{"error":"no such endpoint"}',
  }));
}
const anonMode = MODE === 'anon' || stubEngage;
await page.goto(anonMode ? `${BASE}?walkin=anon` : BASE, { waitUntil: 'domcontentloaded' });
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

if (MODE === 'engage') {
  const stationOf = (r) => r.strip[r.strip.length - 1] ?? null;
  const box = await page.locator('.landing-stage').boundingBox();
  const started = stationOf(first);
  console.log('STATION', started, 'caption', first.caption);
  if (!started) fail.push('the strip never named a station');

  // ---- 1. forty seconds of MOUSEMOVE, which must cost nothing -------------
  for (let i = 0; i < 40; i += 1) {
    await page.mouse.move(
      box.x + box.width * (0.25 + 0.5 * Math.random()),
      box.y + box.height * (0.25 + 0.5 * Math.random()),
      { steps: 4 },
    );
    await page.waitForTimeout(950);
  }
  const moved = await read();
  console.log('MOVED ', JSON.stringify(moved), JSON.stringify(calls));
  if (stationOf(moved) !== started) fail.push(`the station changed by itself: ${started} -> ${stationOf(moved)}`);
  if (!moved.streaming) fail.push('the machine was taken away while the visitor was moving the mouse over it');
  if (calls.some((c) => c.includes('release'))) fail.push('a mousemove-only visit released its cell');
  if (calls.some((c) => c.includes('engage'))) fail.push('moving the mouse reported engagement');
  if (!/does not start until you click or type/i.test(moved.caption ?? '')) {
    fail.push(`the caption does not say the clock is still stopped (${moved.caption})`);
  }
  if (moved.wall) fail.push('the wall arrived for a visitor who never touched the machine');

  // ---- 2. ONE CLICK, which must start it ---------------------------------
  calls.length = 0;
  const clickedAt = Date.now();
  await page.mouse.click(box.x + box.width * 0.5, box.y + box.height * 0.8);
  await page.waitForTimeout(6000);
  const clicked = await read();
  console.log('CLICK ', JSON.stringify(clicked), JSON.stringify(calls));
  if (!calls.some((c) => c.includes('engage'))) fail.push('the first click did not report engagement');
  if (stationOf(clicked) !== started) fail.push(`clicking the machine changed it: ${started} -> ${stationOf(clicked)}`);
  if (/does not start until you click or type/i.test(clicked.caption ?? '')) {
    fail.push('the caption still says the clock is stopped, after a click');
  }
  if (clicked.wall) fail.push('the wall arrived within seconds of the first touch');

  // ---- 3. the wall lands a minute after the CLICK, not after the load -----
  // The decisive one. With the hero clock gone, WHEN the wall arrives is the
  // only thing left that says where the minute began — and under the old rule
  // it would already have arrived, forty seconds ago, unpressed.
  for (let i = 0; i < 9 && !(await read()).wall; i += 1) await page.waitForTimeout(8000);
  const walled = await read();
  const sinceClick = Math.round((Date.now() - clickedAt) / 1000);
  console.log('WALL  ', `${sinceClick}s after the click:`, JSON.stringify(walled));
  if (!walled.wall) fail.push('the intro time never ran out, even after the visitor engaged');
  else if (sinceClick < 45) fail.push(`the wall arrived only ${sinceClick}s after the first touch`);

  // ---- 4. the recovery button brings back the SAME machine ---------------
  calls.length = 0;
  await page.evaluate(() => {
    // Take the machine away the way the page's own watchdog does, without
    // waiting out the un-engaged window: press the stage's exit affordance.
    document.querySelector('.sv-exit, .sv-back, [data-sv-exit]')?.dispatchEvent(
      new MouseEvent('click', { bubbles: true }),
    );
  });
  await page.waitForTimeout(1500);
  const veil = page.locator('.landing-stage__veil .landing-btn').first();
  if (await veil.count()) {
    console.log('PRESS ', await veil.textContent());
    await veil.click();
    await page.waitForTimeout(9000);
    const back = await read();
    console.log('BACK  ', JSON.stringify(back), JSON.stringify(calls));
    if (stationOf(back) !== started) {
      fail.push(`the recovery button re-rolled the station: ${started} -> ${stationOf(back)}`);
    }
    const claimed = calls.find((c) => c.includes('claim'));
    if (!claimed) fail.push('the recovery button claimed nothing');
  } else {
    console.log('BACK   (no stop affordance on this build — skipped)');
  }
}

if (MODE === 'recover') {
  // The other half of the same bug, and the slow one: wait out the whole
  // un-engaged window with nothing but mouse movement, then press the page's
  // own way back. It used to hand over a DIFFERENT operating system — measured
  // twice on the live site, os2warp -> win311 and win311 -> rhapsody.
  const stationOf = (r) => r.strip[r.strip.length - 1] ?? null;
  const started = stationOf(first);
  const box = await page.locator('.landing-stage').boundingBox();
  console.log('STATION', started);
  let releasedAt = null;
  for (let i = 0; i < 115 && releasedAt === null; i += 1) {
    await page.mouse.move(
      box.x + box.width * (0.25 + 0.5 * Math.random()),
      box.y + box.height * (0.25 + 0.5 * Math.random()),
      { steps: 4 },
    );
    await page.waitForTimeout(950);
    if (calls.some((c) => c.includes('release'))) releasedAt = i;
  }
  const stopped = await read();
  console.log('STOP  ', releasedAt, JSON.stringify(stopped));
  if (releasedAt === null) fail.push('an untouched cell was never handed back — the pool is not protected');
  else if (releasedAt < 60) fail.push(`the machine was taken away after only ${releasedAt}s of reading`);
  if (stationOf(stopped) !== started) fail.push('the stopped stage stopped naming the visitor\'s machine');

  calls.length = 0;
  // Pressed by COORDINATE, not by locator: `locator.click()` scrolls the
  // element into view first, and the landing bar is sticky, so its own scroll
  // can park the button underneath the header and then refuse to click it.
  // A mouse click at a point is what a visitor does anyway.
  const veil = page.locator('.landing-stage__veil .landing-btn').first();
  const vb = await veil.boundingBox();
  console.log('PRESS ', await veil.textContent(), JSON.stringify(vb));
  await page.mouse.click(vb.x + vb.width / 2, vb.y + vb.height / 2);
  await page.waitForTimeout(12_000);
  const back = await read();
  console.log('BACK  ', JSON.stringify(back), JSON.stringify(calls));
  if (stationOf(back) !== started) {
    fail.push(`the way back re-rolled the station: ${started} -> ${stationOf(back)}`);
  }
  if (!back.streaming) fail.push('the machine did not come back');
}

if (MODE === 'resume') {
  // The re-roll itself, in seconds rather than in minutes. `releaseDue` hands
  // an un-engaged cell back the INSTANT the tab is hidden — no grace at all,
  // by policy — so backgrounding the tab reaches the same stopped state the
  // slow `recover` run reaches, while the visitor's budget is barely touched.
  // What is being proved is the one thing that changed: what the way back
  // ASKS FOR. It used to ask for nothing and be answered at random.
  const stationOf = (r) => r.strip[r.strip.length - 1] ?? null;
  const started = stationOf(first);
  console.log('STATION', started);
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForTimeout(2500);
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.waitForTimeout(600);
  const stopped = await read();
  console.log('STOP  ', JSON.stringify(stopped), JSON.stringify(calls));
  if (!calls.some((c) => c.includes('release'))) fail.push('a hidden, untouched tab kept its cell');
  if (stationOf(stopped) !== started) fail.push('the stopped stage stopped naming the visitor\'s machine');

  calls.length = 0;
  const veil = page.locator('.landing-stage__veil .landing-btn').first();
  const vb = await veil.boundingBox();
  console.log('PRESS ', await veil.textContent());
  await page.mouse.click(vb.x + vb.width / 2, vb.y + vb.height / 2);
  await page.waitForTimeout(12_000);
  const back = await read();
  console.log('BACK  ', JSON.stringify(back), JSON.stringify(calls));
  if (stationOf(back) !== started) fail.push(`the way back re-rolled the station: ${started} -> ${stationOf(back)}`);
  if (!back.streaming) fail.push('the machine did not come back');
  if (!back.picture || back.picture.startsWith('0x')) fail.push(`the machine that came back never painted (${back.picture})`);
}

if (MODE === 'anon') {
  // The intro time does not start until the visitor touches the machine, so the
  // wall never arrives for a page nobody clicks. One click, then wait it out.
  const stage = await page.locator('.landing-stage').boundingBox();
  if (stage) await page.mouse.click(stage.x + stage.width * 0.5, stage.y + stage.height * 0.8);
  for (let i = 0; i < 9 && !(await read()).wall; i += 1) await page.waitForTimeout(10_000);
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

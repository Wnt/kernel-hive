// Does a walk-in visitor keep their machine across a reload?
//
// `/` claims whichever station the broker has — walkin/routes.py picks "uniformly
// at random among enabled pools" — so before 2026-09-14 every reload was a fresh
// arrival: a refresh, a restored tab or the visitor's own back button rolled a new
// station and took away the one they were driving. The landing page now publishes
// the station it actually got into the URL (spa/src/landing/stationUrl.ts) and that
// address claims the same one on the way back in.
//
// This drives the DEPLOYED bundle as a real anonymous visitor and checks all three
// halves of that promise. It CLAIMS REAL CELLS out of the walk-in pool for the
// length of the run, so do not loop it.
//
//   node walkin-url-probe.mjs [origin]        # default: the public gallery
//
// Exit 0 = every check passed.
import { chromium } from '@playwright/test';

const ORIGIN = process.argv[2] || 'https://kernelhive.madekivi.fi';
const STATION = /\/walkin\/([a-z0-9]+)$/;

const log = (...a) => console.log(...a);

/** Wait for the address bar to name a station — the page only publishes one once a
 *  machine is really on screen, so this doubles as "did the claim land". */
async function settleToStation(page, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  let last = '';
  while (Date.now() < deadline) {
    const path = new URL(page.url()).pathname;
    if (path !== last) {
      log(`    url -> ${path}`);
      last = path;
    }
    const m = path.match(STATION);
    if (m) return m[1];
    await page.waitForTimeout(500);
  }
  return null;
}

const browser = await chromium.launch({ args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();

let failures = 0;
try {
  log(`\n== 1. land on / as a stranger (${ORIGIN}) ==`);
  await page.goto(`${ORIGIN}/`, { waitUntil: 'domcontentloaded', timeout: 45000 });
  const first = await settleToStation(page);
  if (!first) {
    log('    FAIL: / never published a station into the URL');
    failures++;
  } else {
    log(`    OK: the URL names the machine -> /walkin/${first}`);
  }

  if (first) {
    log('\n== 2. reload: the SAME machine must come back ==');
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 45000 });
    const second = await settleToStation(page);
    log(`    before=${first}  after=${second}`);
    if (second === first) {
      log('    OK: refresh kept the station');
    } else {
      log(`    FAIL: refresh moved the visitor ${first} -> ${second}`);
      failures++;
    }
  }

  if (first) {
    log('\n== 3. the address is shareable: open it cold in a NEW context ==');
    const ctx2 = await browser.newContext({ ignoreHTTPSErrors: true });
    const page2 = await ctx2.newPage();
    await page2.goto(`${ORIGIN}/walkin/${first}`, { waitUntil: 'domcontentloaded', timeout: 45000 });
    const third = await settleToStation(page2);
    log(`    asked for ${first}, got ${third}`);
    if (third === first) {
      log('    OK: a cold visitor on that link gets that machine');
    } else {
      log('    FAIL: the link did not pin the station');
      failures++;
    }
    await ctx2.close();
  }
} catch (err) {
  log(`\n    ERROR: ${err.message}`);
  failures++;
} finally {
  await browser.close();
}

log(`\n${failures === 0 ? 'ALL CHECKS PASSED' : `${failures} CHECK(S) FAILED`}`);
process.exit(failures === 0 ? 0 : 1);

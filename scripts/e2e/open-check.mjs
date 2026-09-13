// open-check.mjs — does the harness actually OPEN the station? Nothing else.
//
// This is the probe you run BEFORE any probe that claims to measure a station.
// It sends no input, attaches no QMP client and touches no guest state, so it
// is safe on a live station and on a sick one alike. It answers exactly one
// question: did the real visitor path — grid, card, navigation, stream — reach
// live video for this id.
//
// Run it on a KNOWN-GOOD station first. A probe that fails on a healthy station
// is a broken probe, and every reading it produces on a sick station is noise.
//
//   GALLERY_URL=https://<lab>:8443 node open-check.mjs win311 [more ids…]
//
// **To reach LIVE VIDEO rather than the ExhibitPoster "notes" view**, this
// needs an authenticated `admin`/`viewer` session — since 5bcfc039
// (2026-09-10) `/os/:osId` shows notes to every other role, and the bare LAN
// listener (`:8443`) has no auth plane to sign into at all (see
// station-open.mjs's `signIn()` header for the full wall and why). Point
// GALLERY_URL at the public origin and pass INVITE:
//
//   INVITE=/data/vms/streamhost/serve/pki/sim-invite.code \
//     GALLERY_URL=https://kernelhive.madekivi.fi \
//     node open-check.mjs win311
//
// With no INVITE this still proves the CLICK/NAVIGATION path (card exists,
// href resolves, SPA routes) even though an anon session cannot see the
// stream — `why` says so rather than reading as a station fault.
//
// Exit 0 only if every id opened.
import { chromium } from 'playwright';
import fs from 'node:fs';
import { openStation, shotDir, galleryUrl, signIn, inviteCode } from './station-open.mjs';

const IDS = process.argv.slice(2);
if (!IDS.length) {
  console.error('usage: node open-check.mjs <station-id> [more…]');
  process.exit(64);
}
const URL = galleryUrl();
const OUT = shotDir();
const TS = Date.now();
const log = (...a) => console.error('#', ...a);

// `chromium.launch()` with no explicit --user-data-dir already gets its own
// throwaway profile (Playwright manages it) — NOT the shared :1 desktop's
// long-lived default profile a dozen other sessions' Chrome windows were
// running under when the previous verifier's crash ("Target page, context or
// browser has been closed" right after the card-click navigation) reproduced
// 3/3. (Passing --user-data-dir explicitly is refused by Playwright — it
// wants launchPersistentContext for that — so isolation here comes from
// leaving the profile unset, not from naming one.) Software GL keeps this
// launch off the GPU process other sessions' windows are also contending for.
const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: [
    '--no-sandbox',
    '--use-gl=angle',
    '--use-angle=swiftshader',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--ignore-certificate-errors',
  ],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
});

const code = inviteCode();
let storageState;
if (code) {
  const statePath = `${OUT}/open-check-session-${TS}.json`;
  storageState = await signIn(browser, code, statePath);
  log(`signed in via invite, storageState=${statePath}`);
} else {
  log('no INVITE set — probing anon (card/navigation only, no live video expected since 5bcfc039)');
}

const results = [];
for (const id of IDS) {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, storageState, viewport: { width: 1600, height: 900 } });
  const page = await ctx.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(`[console.${m.type()}] ${m.text().slice(0, 200)}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${String(e).slice(0, 200)}`));
  const t0 = Date.now();
  let r;
  try {
    r = await openStation(page, URL, id, { log, waitMs: 45000 });
  } catch (e) {
    // A closed page/context/browser must not kill the whole batch (and must
    // not masquerade as "no live video" — that is a probe fault, not a
    // station fault). Report it and move on to the next id.
    r = { ok: false, why: `probe error: ${String(e).slice(0, 200)}`, video: null, cardCount: null, url: page.url?.() ?? URL };
  }
  const shot = `${OUT}/open-check-${id}-${TS}.png`;
  await page.screenshot({ path: shot }).catch(() => {});
  const rec = {
    station: id,
    ok: r.ok,
    why: r.why,
    openMs: Date.now() - t0,
    url: r.url,
    video: r.video,
    shot,
    errors: logs.filter((l) => l.startsWith('[pageerror]') || l.includes('console.error')).slice(0, 5),
  };
  results.push(rec);
  console.error(`# ${id}: ${r.ok ? 'OPEN' : 'FAIL'} — ${r.why} (${rec.openMs}ms)`);
  await ctx.close().catch(() => {});
}

const jsonPath = `${OUT}/open-check-${TS}.json`;
fs.writeFileSync(jsonPath, JSON.stringify(results, null, 2));
for (const r of results) {
  console.log(
    `${r.ok ? 'OPEN' : 'FAIL'} ${r.station}  ${r.openMs}ms  ` +
      `${r.video ? `${r.video.w}x${r.video.h} rs=${r.video.readyState} nonblack=${r.video.nonBlackPct}%` : r.why}`,
  );
  console.log(`  shot: ${r.shot}`);
  if (r.errors.length) console.log(`  errors: ${r.errors.join(' | ')}`);
}
console.log(`json: ${jsonPath}`);
await browser.close();
process.exit(results.every((r) => r.ok) ? 0 : 1);

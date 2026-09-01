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
// Exit 0 only if every id opened.
import { chromium } from 'playwright';
import fs from 'node:fs';
import { openStation, shotDir, galleryUrl } from './station-open.mjs';

const IDS = process.argv.slice(2);
if (!IDS.length) {
  console.error('usage: node open-check.mjs <station-id> [more…]');
  process.exit(64);
}
const URL = galleryUrl();
const OUT = shotDir();
const TS = Date.now();
const log = (...a) => console.error('#', ...a);

const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
});

const results = [];
for (const id of IDS) {
  const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
  const logs = [];
  page.on('console', (m) => logs.push(`[console.${m.type()}] ${m.text().slice(0, 200)}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${String(e).slice(0, 200)}`));
  const t0 = Date.now();
  const r = await openStation(page, URL, id, { log, waitMs: 45000 });
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
  await page.close();
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

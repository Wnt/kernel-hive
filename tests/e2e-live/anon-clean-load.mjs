// Does a stranger's first load come back CLEAN, and does the telemetry fire?
//
// Two fixes on 2026-09-14 meet here: the museum's lineup and its boot index were
// published (gate.py — placard data out of a public repo, and gating it only ever
// produced a 401 in every stranger's console), and the deployed bundle got its
// Instana EUM key back after a run of keyless builds from checkouts whose
// registry/local.env carried no INSTANA_* block.
//
// So this asks the two questions a stranger's browser answers: did anything fail,
// and did the page-load beacon go out?
//
//   node anon-clean-load.mjs [origin]
import { chromium } from '@playwright/test';

const ORIGIN = process.argv[2] || 'https://kernelhive.madekivi.fi';

const browser = await chromium.launch({ args: ['--ignore-certificate-errors'] });
const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await ctx.newPage();

const failed = [];
const errors = [];
const beacons = [];
page.on('response', (r) => {
  const p = new URL(r.url()).pathname;
  if (r.status() >= 400) failed.push(`${r.status()} ${p}`);
  if (p.startsWith('/eum')) beacons.push(`${r.status()} ${p}`);
});
page.on('console', (m) => {
  if (m.type() === 'error') errors.push(m.text().slice(0, 160));
});

await page.goto(`${ORIGIN}/`, { waitUntil: 'domcontentloaded', timeout: 45000 });
await page.waitForTimeout(15000);

const lineup = await page.evaluate(async () => {
  const r = await fetch('/gallery-manifest.json', { cache: 'no-cache' });
  if (!r.ok) return `HTTP ${r.status}`;
  return `${(await r.json()).entries.length} entries`;
});
const agent = await page.evaluate(() => typeof window.ineum);

console.log(`\nlineup readable by a stranger: ${lineup}`);
console.log(`window.ineum: ${agent}`);
console.log(`\nfailed requests (${failed.length}):`);
console.log([...new Set(failed)].join('\n') || '  none');
console.log(`\nconsole errors (${errors.length}):`);
console.log([...new Set(errors)].join('\n') || '  none');
console.log(`\nEUM beacons (${beacons.length}):`);
console.log([...new Set(beacons)].join('\n') || '  none');

await browser.close();

const clean = failed.length === 0 && errors.length === 0;
const telemetry = agent === 'function' && beacons.length > 0;
console.log(
  `\n${clean ? 'CLEAN LOAD' : 'LOAD NOT CLEAN'} · ${telemetry ? 'TELEMETRY LIVE' : 'NO TELEMETRY'}`,
);
process.exit(clean && telemetry ? 0 : 1);

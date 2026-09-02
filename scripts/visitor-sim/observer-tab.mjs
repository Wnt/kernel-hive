#!/usr/bin/env node
// observer-tab.mjs — one long-lived, PASSIVE viewer on a station, watched by
// lib/bannerWatch.mjs. This is the operator's own tab, reproduced.
//
// WHY IT IS A SEPARATE TOOL. The dossier's sharpest observation is about a
// SECOND viewer: while a sim visitor typed and moved on win95, the operator's
// already-open tab on the same station reported ~95 % "loss", latched its
// frame watchdog three times and went spotty — on a 12 ms LAN. Reproducing
// that needs a tab that does NOTHING but watch, for the whole run, and
// visitor-sim's visitors are all doers with journeys and lifetimes. Bolting a
// "sit still" journey into lib/journeys.mjs would have put a non-visitor
// behaviour into the visitor mix and changed what every existing --mix means;
// this keeps the sim honest and the observer explicit.
//
// It opens the station and then touches nothing: no clicks, no keys, no
// resets. The only traffic it adds is the one extra stream session, which is
// the variable under test.
//
// USAGE
//   node observer-tab.mjs --station win95 --duration 3m \
//     --storage-state visitor-sim-runs/invite-session.json \
//     --shots-dir ~/sim-shots/run2-observer [--headed] [--browser chrome]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { startBannerWatch } from './lib/bannerWatch.mjs';
import { openStation, suppressBootVideo } from './lib/stationOpen.mjs';
import { log, nowStamp } from './lib/log.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

function parse(argv) {
  const a = new Map();
  const flags = new Set(['headed', 'help']);
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i].replace(/^--/, '');
    if (!argv[i].startsWith('--')) throw new Error(`unexpected argument: ${argv[i]}`);
    if (flags.has(name)) { a.set(name, true); continue; }
    if (argv[i + 1] === undefined) throw new Error(`--${name} needs a value`);
    a.set(name, argv[++i]);
  }
  return a;
}

function durationMs(s) {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(String(s).trim());
  if (!m) throw new Error(`bad duration: ${s}`);
  return Math.round(Number(m[1]) * { ms: 1, s: 1000, m: 60000, h: 3600000 }[m[2] || 's']);
}

async function main() {
  const a = parse(process.argv.slice(2));
  if (a.get('help')) {
    process.stdout.write('observer-tab.mjs --station <id> [--duration 3m] [--storage-state f] [--shots-dir d] [--headed] [--browser chrome] [--gallery-url u] [--out-dir d]\n');
    return;
  }
  const station = a.get('station');
  if (!station) throw new Error('--station is required');
  const ms = durationMs(a.get('duration') ?? '3m');
  const galleryUrl = (a.get('gallery-url') ?? 'https://kernelhive.madekivi.fi').replace(/\/$/, '');
  const storageState = a.get('storage-state') ?? path.join(HERE, 'visitor-sim-runs', 'invite-session.json');
  if (!fs.existsSync(storageState)) {
    throw new Error(`no session at ${storageState} — run visitor-sim once with --invite first, or pass --storage-state`);
  }
  const shotsDir = a.get('shots-dir') ?? null;
  const outDir = a.get('out-dir') ?? path.join(HERE, 'visitor-sim-runs');

  log('observer', `station ${station}, ${ms / 1000}s, session ${storageState}`);
  const browser = await chromium.launch({
    headless: !a.get('headed'),
    channel: a.get('browser') === 'chrome' ? 'chrome' : undefined,
    args: ['--ignore-certificate-errors'],
  });
  const context = await browser.newContext({ ignoreHTTPSErrors: true, storageState, viewport: { width: 1200, height: 800 } });
  await context.addInitScript(() => { window.__khClientClass = 'probe'; });
  const page = await context.newPage();
  // visitorId 0 — it is not one of the sim's visitors, and the shot names say so.
  const watch = startBannerWatch(page, { visitorId: 0, shotsDir, log: (m) => log('observer', m) });
  const startedAt = new Date().toISOString();
  let opened = { ok: false, why: 'not attempted' };
  try {
    await page.goto(`${galleryUrl}/`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await suppressBootVideo(page, station);
    opened = await openStation(page, station, { waitMs: 30000 });
    log('observer', `open ${station}: ok=${opened.ok} ${opened.why}`);
    // Sit. This is the whole behaviour.
    await page.waitForTimeout(ms);
  } catch (err) {
    log('observer', `EXCEPTION: ${String(err).split('\n')[0]}`);
  } finally {
    const timeline = await watch.stop();
    await page.evaluate(() => window.dispatchEvent(new Event('pagehide'))).catch(() => {});
    await page.waitForTimeout(500).catch(() => {});
    await context.close().catch(() => {});
    await browser.close().catch(() => {});
    fs.mkdirSync(outDir, { recursive: true });
    const file = path.join(outDir, `observer-${station}-${nowStamp()}.json`);
    fs.writeFileSync(file, JSON.stringify({
      tool: 'observer-tab', station, galleryUrl, startedAt,
      finishedAt: new Date().toISOString(), durationMs: ms,
      opened: { ok: opened.ok, why: opened.why },
      bannerTimeline: timeline,
    }, null, 2));
    log('observer', `${timeline.filter((t) => t.kind === 'transition').length} transition(s); manifest ${file}`);
  }
}

await main();

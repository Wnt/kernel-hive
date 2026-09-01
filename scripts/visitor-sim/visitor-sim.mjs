#!/usr/bin/env node
// visitor-sim.mjs — simulate visitors clicking and typing around the public
// kernel-hive gallery, with real browsers, to populate realistic Instana and
// analytics data. Run `node visitor-sim.mjs --help` or read
// docs/lab/VISITOR-SIM.md for the full picture; this file is the wiring.
//
// SAFETY. This drives real hardware behind a public edge. Every disruptive or
// account-creating action goes through lib/safety.mjs's gates, every cap in
// --help is enforced in lib/cli.mjs, and every simulated tab declares itself
// `window.__khClientClass = 'probe'` before it ever loads the bundle — belt
// (the declaration) and braces (navigator.webdriver, which Playwright sets on
// its own) so simulated traffic can never be mistaken for a human visitor in
// either kernel-hive's own analytics store or in Instana
// (spa/src/analytics/instana.ts's `kh.client.class` meta).

import { chromium } from 'playwright';
import { parseArgs } from './lib/cli.mjs';
import { JOURNEYS } from './lib/journeys.mjs';
import { Semaphore, FailureBreaker, ResetGate, WalkinSignupGate } from './lib/safety.mjs';
import { RunManifest, log } from './lib/log.mjs';
import { makeRng, weightedPick } from './lib/rng.mjs';
import { ensureInviteSession } from './lib/invite.mjs';

function printPlan(config) {
  log('plan', `gallery      ${config.galleryUrl}`);
  log('plan', `browser      ${config.browser}`);
  log('plan', `stations     ${config.stations.join(', ')}`);
  log('plan', `visitors     ${config.visitors} over ${config.durationMs / 1000}s, concurrency ${config.concurrency}`);
  log('plan', `mix          ${Object.entries(config.mix).map(([k, v]) => `${k}=${v}`).join(', ')}`);
  log('plan', `walk-in cap  ${config.walkinMax} real passkey account(s) this run`);
  log(
    'plan',
    `resets       ${config.allowResets ? `ARMED, max ${config.resetMax}, min ${config.resetMinIntervalMs / 1000}s between same-station resets` : 'disabled (--allow-resets not set)'}`,
  );
  if (config.resetsArmedButUnusable) {
    log(
      'plan',
      'resets NOTE  --allow-resets is armed but --mix has no "station" journey — resets only ever fire from ' +
        'journeyStation (lib/journeys.mjs), so nothing in this run can use that budget. Add station=<weight> to ' +
        '--mix (needs --storage-state or --invite) if you actually want resets to fire.',
    );
  }
  let credLine;
  if (config.storageState) {
    credLine = `storage-state: ${config.storageState}`;
  } else if (config.invite) {
    credLine = config.invite.willReuseCache
      ? `invite: will reuse cached session at ${config.invite.statePath}`
      : `invite: will redeem once and cache the session at ${config.invite.statePath}`;
  } else {
    credLine = 'none — walk-in-only journeys';
  }
  log('plan', `credentials  ${credLine}`);
  log('plan', `out-dir      ${config.outDir}`);
}

async function runVisitor(browser, config, safety, manifest, visitorId, rng) {
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    storageState: config.storageState ?? undefined,
    viewport: { width: 1400, height: 900 },
  });
  // BELT: declare the class before any script this tab loads ever runs, so
  // analytics/intent.ts's clientClass() sees it on the very first call —
  // window.__khClientClass, read by that module's header comment and by
  // scripts/visitor-sim's own kh.client.class Instana meta (instana.ts).
  await context.addInitScript(() => {
    window.__khClientClass = 'probe';
  });
  const page = await context.newPage();
  const journeyName = weightedPick(rng, config.mix);
  const journeyFn = JOURNEYS[journeyName];
  const entry = { visitorId, journey: journeyName, startedAt: new Date().toISOString() };
  log(`v${visitorId}`, `starting journey "${journeyName}"`);
  try {
    // BRACES: independent of the init-script declaration above, confirm the
    // heuristic intent.ts falls back to also holds for this launcher —
    // Playwright/Chromium set navigator.webdriver=true on their own.
    const webdriver = await page.evaluate(() => navigator.webdriver);
    if (webdriver !== true) {
      log(`v${visitorId}`, 'WARNING: navigator.webdriver is not true — the fallback label would not have held without the init script');
    }
    const result = await journeyFn(page, {
      galleryUrl: config.galleryUrl,
      stations: config.stations,
      rng,
      safety,
      manifest,
      visitorId,
      log: (msg) => log(`v${visitorId}`, msg),
    });
    entry.ok = result.ok;
    entry.detail = result.detail;
    if (result.station) entry.station = result.station;
    if (result.walkinHandle) entry.walkinHandle = result.walkinHandle;
    if (result.resetTriggered) entry.resetTriggered = true;
    log(`v${visitorId}`, `${result.ok ? 'done' : 'FAILED'}: ${result.detail}`);
    if (result.ok) safety.breaker.ok();
    else safety.breaker.fail(`v${visitorId} ${journeyName}: ${result.detail}`);
  } catch (err) {
    entry.ok = false;
    entry.detail = `threw: ${err && err.stack ? err.stack.split('\n')[0] : err}`;
    log(`v${visitorId}`, `EXCEPTION in "${journeyName}": ${entry.detail}`);
    manifest.error({ visitorId, journey: journeyName, message: entry.detail });
    safety.breaker.fail(entry.detail);
  } finally {
    entry.finishedAt = new Date().toISOString();
    manifest.visitor(entry);
    await context.close().catch(() => {});
  }
}

async function main() {
  let config;
  let inviteCode; // never attached to `config` — see lib/cli.mjs's comment on why.
  try {
    ({ config, inviteCode } = parseArgs(process.argv.slice(2)));
  } catch (err) {
    process.stderr.write(`visitor-sim: ${err.message}\n`);
    process.exitCode = 1;
    return;
  }

  printPlan(config);
  if (config.dryRun) {
    log('dry-run', 'plan printed, nothing was touched. Remove --dry-run to actually run it.');
    return;
  }

  const rng = makeRng(config.seed);
  const safety = {
    resetGate: new ResetGate({ allowed: config.allowResets, maxTotal: config.resetMax, minIntervalMs: config.resetMinIntervalMs }),
    walkinGate: new WalkinSignupGate({ maxTotal: config.walkinMax }),
    breaker: new FailureBreaker(5),
  };
  const manifest = new RunManifest(config);
  const sem = new Semaphore(config.concurrency);

  const browser = await chromium.launch({
    headless: !config.headed,
    channel: config.browser === 'chrome' ? 'chrome' : undefined,
    args: ['--ignore-certificate-errors'],
  });

  // Resolve --invite into a real storage-state path BEFORE any visitor
  // context is created, using this same browser instance — one throwaway
  // context, closed immediately after. `inviteCode` goes out of scope right
  // after this call and is never read again.
  if (config.invite) {
    try {
      config.storageState = await ensureInviteSession(browser, {
        galleryUrl: config.galleryUrl,
        code: inviteCode,
        statePath: config.invite.statePath,
        refresh: config.invite.refresh,
        log: (msg) => log('invite', msg),
      });
    } catch (err) {
      log('invite', `FAILED: ${err.message}`);
      await browser.close();
      process.exitCode = 1;
      return;
    } finally {
      inviteCode = undefined;
    }
  }

  // Spread `visitors` arrivals across `durationMs`, at random offsets — a
  // gallery does not receive visitors on a metronome. Each visitor's own
  // context is bounded by the semaphore, so at most `concurrency` browsers
  // are ever open together regardless of how the arrivals cluster.
  const arrivals = Array.from({ length: config.visitors }, () => rng() * config.durationMs).sort((a, b) => a - b);
  const t0 = Date.now();
  const tasks = arrivals.map((offsetMs, i) => {
    const visitorId = i + 1;
    return (async () => {
      const wait = t0 + offsetMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      if (safety.breaker.tripped) {
        log(`v${visitorId}`, 'skipped: the failure breaker has tripped (see below)');
        return;
      }
      await sem.acquire();
      try {
        await runVisitor(browser, config, safety, manifest, visitorId, rng);
      } finally {
        sem.release();
      }
    })();
  });

  await Promise.all(tasks);
  await browser.close();

  if (safety.breaker.tripped) {
    log('run', `STOPPED EARLY: ${safety.breaker.limit} consecutive failures. Last: ${safety.breaker.tripReason}`);
  }
  log(
    'run',
    `finished: ${manifest.visitors.length} visitor(s), ${manifest.walkinAccounts.length} walk-in account(s) created, ${manifest.resets.length} reset(s), ${manifest.errors.length} error(s)`,
  );
  const file = manifest.write(config.outDir);
  log('run', `manifest written to ${file}`);
  if (manifest.walkinAccounts.length > 0) {
    log('run', `walk-in handles created this run: ${manifest.walkinAccounts.map((a) => a.handle ?? '(unknown)').join(', ')}`);
    log('run', 'clean these up from /admin (People) when you are done — see docs/lab/VISITOR-SIM.md "Cleanup".');
  }
  if (safety.breaker.tripped) process.exitCode = 1;
}

await main();

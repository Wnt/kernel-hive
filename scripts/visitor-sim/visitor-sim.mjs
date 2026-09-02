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
import { GridSlots, cellBounds } from './lib/grid.mjs';

function printPlan(config) {
  log('plan', `gallery      ${config.galleryUrl}`);
  log('plan', `browser      ${config.browser}`);
  log('plan', `stations     ${config.stations.join(', ')}`);
  log('plan', `visitors     ${config.visitors} over ${config.durationMs / 1000}s, concurrency ${config.concurrency}`);
  if (config.tile) {
    log(
      'plan',
      `windows      TILED ${config.grid.cols}x${config.grid.rows} grid in ${config.screen.w}x${config.screen.h}pt` +
        `, gap ${config.tileGap}, top ${config.tileTop}${config.burst ? ', burst (all arrive at once)' : ''}`,
    );
  } else if (config.burst) {
    log('plan', 'arrivals     burst (all at once, capped by concurrency)');
  }
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

async function runVisitor(browser, config, safety, manifest, visitorId, rng, slots) {
  // When tiling, take a grid cell and let the window drive the viewport
  // (viewport:null) so the page fills whatever size the cell is; otherwise
  // keep the fixed viewport the non-tiled runs have always used. The slot is
  // released in the finally below so a later visitor reuses this same cell.
  const slot = slots ? slots.take() : null;
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    storageState: config.storageState ?? undefined,
    viewport: slots ? null : { width: 1400, height: 900 },
  });
  // BELT: declare the class before any script this tab loads ever runs, so
  // analytics/intent.ts's clientClass() sees it on the very first call —
  // window.__khClientClass, read by that module's header comment and by
  // scripts/visitor-sim's own kh.client.class Instana meta (instana.ts).
  await context.addInitScript(() => {
    window.__khClientClass = 'probe';
  });
  const page = await context.newPage();
  // Tile the window into its cell. This is the ONE part that needs a live
  // browser: the geometry is lib/grid.mjs, the move is a single CDP call.
  // Wrapped so a positioning hiccup (an odd WM, a headless run that slipped
  // past the --tile guard) degrades to an un-tiled window, never a dead
  // visitor.
  if (slots) {
    try {
      const b = cellBounds(slot, { grid: config.grid, screen: config.screen, gap: config.tileGap, top: config.tileTop });
      const cdp = await context.newCDPSession(page);
      const { windowId } = await cdp.send('Browser.getWindowForTarget');
      await cdp.send('Browser.setWindowBounds', {
        windowId,
        bounds: { left: b.left, top: b.top, width: b.width, height: b.height, windowState: 'normal' },
      });
    } catch (err) {
      log(`v${visitorId}`, `tile: could not position window (${err.message}); leaving it where it opened`);
    }
  }
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
    // spa/src/analytics/sink.ts batches probes/flows/spans and only flushes
    // on its own 20s interval or a real `pagehide`/`visibilitychange->hidden`
    // — neither of which a Playwright `context.close()` reliably delivers to
    // a still-running page before tearing it down. A short journey (exactly
    // what a --duration-bounded low-volume run produces) can finish and close
    // well inside that 20s window, silently dropping every span and counter
    // it just generated — including the one this tool exists to produce.
    // Fire the same `pagehide` the real hook listens for while the page is
    // still alive, then give the resulting keepalive fetch a moment to
    // actually leave the tab before it is torn down.
    await page.evaluate(() => window.dispatchEvent(new Event('pagehide'))).catch(() => {});
    await page.waitForTimeout(1000).catch(() => {});
    await context.close().catch(() => {});
    if (slots) slots.release(slot);
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
  const slots = config.tile ? new GridSlots(config.grid.cols * config.grid.rows) : null;
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
  // --burst puts every arrival at t0 (the semaphore still caps how many run at
  // once), so a tiled grid fills up immediately; otherwise spread arrivals over
  // the run, since a real gallery does not receive visitors on a metronome.
  const arrivals = config.burst
    ? Array.from({ length: config.visitors }, () => 0)
    : Array.from({ length: config.visitors }, () => rng() * config.durationMs).sort((a, b) => a - b);
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
        await runVisitor(browser, config, safety, manifest, visitorId, rng, slots);
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
  // `manifest.errors` is EXCEPTIONS only (the catch block in runVisitor
  // above) — a journey that returns ok:false normally (a card never found, a
  // stream that never went live) never touches it. A summary that only prints
  // that count reads clean while a sixth of the run FAILED, which is exactly
  // what misled the run that found this. `failedVisitors` is every journey
  // whose own result said ok:false, thrown or not.
  const failed = manifest.failedVisitors;
  log(
    'run',
    `finished: ${manifest.visitors.length} visitor(s), ${failed.length} failed, ${manifest.walkinAccounts.length} walk-in account(s) created, ${manifest.resets.length} reset(s), ${manifest.errors.length} exception(s)`,
  );
  if (failed.length > 0) {
    for (const v of failed) {
      log('run', `FAILED v${v.visitorId} "${v.journey}": ${v.detail}`);
    }
  }
  const file = manifest.write(config.outDir);
  log('run', `manifest written to ${file}`);
  if (manifest.walkinAccounts.length > 0) {
    log('run', `walk-in handles created this run: ${manifest.walkinAccounts.map((a) => a.handle ?? '(unknown)').join(', ')}`);
    log('run', 'clean these up from /admin (People) when you are done — see docs/lab/VISITOR-SIM.md "Cleanup".');
  }
  if (safety.breaker.tripped || failed.length > 0) process.exitCode = 1;
}

await main();

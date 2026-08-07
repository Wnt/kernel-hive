// Headless native-decoder fallback soak/recovery probe.
//
// Run from a directory with Playwright installed. An operator may interrupt the
// single platform bridge service during the announced DROP WINDOW; the browser must
// recover without a page reload. VideoDecoder is removed before app startup to
// exercise the same capability gate as Firefox Android.
//
//   GALLERY_URL=https://192.0.2.10:8443 TILE=win95 \
//     SOAK_MS=195000 node webrtc-fallback-recovery.mjs

import { chromium } from 'playwright';

const origin = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const tile = process.env.TILE || 'win95';
const soakMs = Number(process.env.SOAK_MS || 195_000);
const minSoakMs = Number(process.env.MIN_SOAK_MS || 180_000);
const requireRecovery = process.env.REQUIRE_RECOVERY !== '0';
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({
  ignoreHTTPSErrors: true,
  viewport: { width: 1280, height: 900 },
});

await page.addInitScript(() => {
  Object.defineProperty(globalThis, 'VideoDecoder', {
    configurable: true,
    value: undefined,
  });
});

const pageErrors = [];
page.on('pageerror', (error) => pageErrors.push(String(error)));
page.on('console', (message) => {
  if (message.type() === 'error') pageErrors.push(message.text());
});

await page.goto(`${origin}/os/${tile}`, { waitUntil: 'domcontentloaded', timeout: 30_000 });
const startedAt = Date.now();
let firstLive = null;
let latest = null;
let maxFrames = 0;
let sawRecoveryState = false;
let recovered = false;
let nextReportAt = 0;

while (Date.now() - startedAt < soakMs) {
  await page.waitForTimeout(1_000);
  latest = await page.evaluate(() => globalThis.__kernelHiveWebRtcDebug?.() ?? null);
  if (!latest) continue;
  maxFrames = Math.max(maxFrames, Number(latest.framesDecoded || 0));
  if (!firstLive && latest.mediaState === 'live' && latest.framesDecoded > 0) {
    firstLive = { ...latest };
    console.log(`BASELINE_LIVE ${JSON.stringify(firstLive)}`);
    console.log('DROP_WINDOW_OPEN: stop the single osgallery-webrtc-bridge service, then start it');
  }
  if (firstLive && (latest.mediaState === 'reconnecting' || latest.mediaState === 'stalled')) {
    sawRecoveryState = true;
  }
  if (firstLive && sawRecoveryState && latest.mediaState === 'live'
      && latest.reconnectCount > 0 && latest.framesDecoded > firstLive.framesDecoded) {
    recovered = true;
  }
  if (Date.now() >= nextReportAt) {
    nextReportAt = Date.now() + 15_000;
    console.log(`SAMPLE t=${Math.round((Date.now() - startedAt) / 1000)}s ${JSON.stringify(latest)}`);
  }
}

const elapsedMs = Date.now() - startedAt;
const stayedUp = elapsedMs >= minSoakMs;
const connected = latest?.connectionState === 'connected'
  && (latest?.iceConnectionState === 'connected' || latest?.iceConnectionState === 'completed');
const pass = Boolean(firstLive && stayedUp && connected
  && (!requireRecovery || recovered) && maxFrames > firstLive.framesDecoded);
console.log(`FINAL ${JSON.stringify({
  pass,
  elapsedMs,
  connected,
  recovered,
  requireRecovery,
  sawRecoveryState,
  firstFrames: firstLive?.framesDecoded ?? 0,
  maxFrames,
  latest,
  pageErrors: pageErrors.slice(0, 10),
})}`);
await browser.close();
process.exit(pass ? 0 : 1);

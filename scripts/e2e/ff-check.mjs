// ff-check.mjs — Firefox twin of fd-check.mjs: PASS/FAIL stream smoke on ONE tile.
//
// Drives the live gallery with Playwright's BUNDLED Firefox (build firefox-1532,
// validated with playwright 1.61.x; `npx playwright install firefox` puts it in
// ~/.cache/ms-playwright). Headless is fine for Firefox — no DISPLAY needed.
//
// Usage (from a dir whose node_modules has playwright, e.g. ~/e2e — see README):
//   node ff-check.mjs [TileName]        # default FreeDOS
//   GALLERY_URL=https://192.0.2.10:8443 node ff-check.mjs "Windows 95"
//
// Probe: open the SPA, click the tile card, wait, then assert the stream
// <video> (fed from an offscreen canvas via captureStream — there is NO stream
// <canvas> in the document): readyState>=2, videoWidth>0, and non-black pixels
// via drawImage sampling (>50% default; >=1% floor for text-mode DOS tiles —
// see MIN_NONBLACK). Prints PASS/FAIL + page console errors and screenshots to
// ~/e2e/shots/. Exit code 0 on PASS, 1 on FAIL.
//
// Gotchas (validated on CT950): WebCodecs/WebTransport are SecureContext-gated
// in Firefox (undefined on about:blank — probe the real https origin only), and
// H.264 decode needs system libavcodec (apt-get install ffmpeg/libavcodec60).
import { firefox } from 'playwright';
import fs from 'node:fs';

const GALLERY_URL = process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;
const TILE = process.argv[2] || 'FreeDOS';
const WAIT_MS = process.env.FF_WAIT_MS ? Number(process.env.FF_WAIT_MS) : 30000;
// Non-black gate: default >50% of sampled pixels, but text-mode DOS tiles are
// legitimately ~99% black — a KNOWN-GOOD Chrome decode of FreeDOS measures
// nonBlackPct=1 (tile-diag.mjs, 2026-07-12) — so they get a >=1% floor instead.
// Override with FF_MIN_NONBLACK=<pct>.
const MIN_NONBLACK = process.env.FF_MIN_NONBLACK
  ? Number(process.env.FF_MIN_NONBLACK)
  : (/freedos|ms-?dos/i.test(TILE) ? 1 : 50);
const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });

const consoleErrors = [];
const browser = await firefox.launch({ headless: true });
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
page.on('console', (m) => {
  if (m.type() === 'error' || m.type() === 'warning') consoleErrors.push(`[console.${m.type()}] ${m.text().slice(0, 400)}`);
});
page.on('pageerror', (e) => consoleErrors.push(`[pageerror] ${String(e).slice(0, 400)}`));

await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000); // manifest fetch + grid render

// Click the tile card. New bundles render <button class="os-card"> (aria-label
// starts with the displayName); older deployed bundles have plain card markup,
// so fall back to a text match + bounding-box click (the tile-diag approach).
const re = new RegExp(TILE, 'i');
let card = page.locator('button.os-card').filter({ hasText: re }).first();
if (await card.count() === 0) card = page.getByText(re).first();
await card.scrollIntoViewIfNeeded();
const box = await card.boundingBox();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
console.log(`[ff-check] clicked tile card matching /${TILE}/i, waiting up to ${WAIT_MS}ms for stream…`);

// Poll the stream <video> until it is live AND clears MIN_NONBLACK, or the deadline.
const probeOnce = () => page.evaluate(() => {
  // Prefer a <video> with a srcObject (the stream); fall back to any video.
  const vids = [...document.querySelectorAll('video')];
  const v = vids.find((x) => x.srcObject) || vids[0];
  if (!v) return { found: false };
  const rec = {
    found: true, readyState: v.readyState, w: v.videoWidth, h: v.videoHeight,
    paused: v.paused, nonBlackPct: 0,
  };
  if (rec.w > 0 && rec.readyState >= 2) {
    try {
      const c = document.createElement('canvas');
      c.width = rec.w; c.height = rec.h;
      const ctx = c.getContext('2d');
      ctx.drawImage(v, 0, 0);
      const d = ctx.getImageData(0, 0, rec.w, rec.h).data;
      let nb = 0, n = 0;
      for (let i = 0; i < d.length; i += 400) { n++; if (d[i] + d[i + 1] + d[i + 2] > 30) nb++; }
      rec.nonBlackPct = Math.round((100 * nb) / Math.max(1, n));
    } catch (e) { rec.err = String(e).slice(0, 120); }
  }
  return rec;
});

let probe = { found: false };
const deadline = Date.now() + WAIT_MS;
for (;;) {
  probe = await probeOnce();
  if (probe.found && probe.readyState >= 2 && probe.w > 0 && probe.nonBlackPct >= MIN_NONBLACK) break;
  if (Date.now() > deadline) break;
  await page.waitForTimeout(1000);
}

const pass = !!(probe.found && probe.readyState >= 2 && probe.w > 0 && probe.nonBlackPct >= MIN_NONBLACK);
const shot = `${OUT}/ff-check-${TILE.replace(/\W+/g, '_')}-${Date.now()}.png`;
await page.screenshot({ path: shot }).catch(() => console.log('[ff-check] screenshot failed'));

// Grab any visible banner/chip text (e.g. "No video · stream stalled" /
// "decoder failing") for the report — the discriminator when FAIL.
const chip = await page.evaluate(() => {
  const t = document.body.innerText;
  const m = t.match(/No video[^\n]*/);
  return m ? m[0] : '';
});

console.log(`[ff-check] video probe: ${JSON.stringify(probe)}`);
if (chip) console.log(`[ff-check] banner: ${chip}`);
if (consoleErrors.length) {
  console.log(`[ff-check] page console (${consoleErrors.length} errors/warnings):`);
  for (const l of consoleErrors.slice(0, 30)) console.log('  ' + l);
}
console.log(`[ff-check] screenshot: ${shot}`);
console.log(pass
  ? `PASS: ${TILE} stream live in Firefox (readyState=${probe.readyState} ${probe.w}x${probe.h} nonBlack=${probe.nonBlackPct}% >= ${MIN_NONBLACK}%)`
  : `FAIL: ${TILE} stream NOT live in Firefox (${JSON.stringify(probe)})`);
await browser.close();
process.exit(pass ? 0 : 1);

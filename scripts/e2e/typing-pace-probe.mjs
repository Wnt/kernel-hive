// Typing-pace probe: open a station, type a line at a HUMAN pace, and report
// whether the guest kept up.
//
// WHY THIS EXISTS. The conversion rigs prove input by firing a burst at the
// control socket with no browser in the loop. That misses two whole classes of
// defect, both found on the live vic20 by the operator and neither reproducible
// from a rig:
//   * the FIRST VISIT of a cold station is what starts it, so the launcher's
//     delayed standby freeze can land on a live session (see idle.rs);
//   * a human types with OVERLAPPING key edges at ~5-8 chars/s, which a clean
//     scripted press/release/press/release sequence never reproduces.
// So this drives the real SPA in the real browser: same transport, same input
// path, same pacing a visitor produces.
//
// PASS/FAIL is deliberately NOT decided here. Reading VIC-20 glyphs out of an
// H.264 frame is its own unreliable project, and this lab's rule is to route a
// check to the cheapest competent verifier — so this prints the objective
// numbers it CAN measure (stream liveness, non-black %, per-keystroke wall
// clock) and leaves the screenshot for an eye. The daemon's own counters are
// the other half: watch `[input-router] ... dropped/overflow` and
// `[vicesock] ack timeout` in `journalctl -u streamhost@<station>` while this
// runs.
//
//   node typing-pace-probe.mjs "VIC-20" 'PRINT "HELLO WORLD"' 140
//
// argv: <card text> [line to type] [ms between keystrokes]
// env:  GALLERY_URL, LAB_HOST, PROBE_WAIT_MS
import { chromium } from 'playwright';
import fs from 'node:fs';

const CARD = process.argv[2] || 'VIC-20';
const LINE = process.argv[3] || 'PRINT "HELLO WORLD"';
// 140 ms/char ~= 7 chars/s: an ordinary typing pace, not a stress test. The
// operator's report was "normal pace", and 80/80 hold/gap pacing in the
// emulator module implies a ceiling near 6 chars/s — so this sits just above it
// on purpose.
const PACE_MS = Number(process.argv[4] || 140);
const GALLERY_URL =
  process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const TS = Date.now();
const tag = CARD.replace(/[^a-z0-9]+/gi, '-').toLowerCase();

const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });

const logs = [];
page.on('console', (m) => logs.push(`[console.${m.type()}] ${m.text().slice(0, 200)}`));
page.on('pageerror', (e) => logs.push(`[pageerror] ${String(e).slice(0, 200)}`));

await page.goto(GALLERY_URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);

const card = page.getByText(new RegExp(CARD.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i')).first();
await card.scrollIntoViewIfNeeded();
const box = await card.boundingBox();
if (!box) {
  console.log(`FAIL: no card matching ${CARD}`);
  await browser.close();
  process.exit(1);
}
// The click is the moment the station is asked to wake. Time it: a cold
// station's first frame is also the idle-resume path under test.
const tClick = Date.now();
await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);

// Stream probe: the 2D StreamView feeds <video> from an OFFSCREEN canvas, so
// there is no stream <canvas> in the document — sample by drawImage().
const probe = () => {
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = { w: v.videoWidth, h: v.videoHeight, readyState: v.readyState };
    if (rec.w > 0 && v.readyState >= 2) {
      try {
        const c = document.createElement('canvas');
        c.width = rec.w;
        c.height = rec.h;
        const ctx = c.getContext('2d');
        ctx.drawImage(v, 0, 0);
        const d = ctx.getImageData(0, 0, rec.w, rec.h).data;
        let nonBlack = 0;
        let n = 0;
        for (let i = 0; i < d.length; i += 400) {
          n++;
          if (d[i] + d[i + 1] + d[i + 2] > 30) nonBlack++;
        }
        rec.nonBlackPct = Math.round((100 * nonBlack) / Math.max(1, n));
      } catch (e) {
        rec.err = String(e).slice(0, 80);
      }
    }
    return rec;
  }
  return null;
};

const waitMs = Number(process.env.PROBE_WAIT_MS || 45000);
let live = null;
for (let waited = 0; waited < waitMs; waited += 1000) {
  live = await page.evaluate(probe);
  if (live && live.w > 0 && live.readyState >= 2) break;
  await page.waitForTimeout(1000);
}
if (!live || !live.w) {
  console.log(`FAIL: no live stream video after ${waitMs} ms`);
  console.log(logs.slice(-15).join('\n'));
  await browser.close();
  process.exit(1);
}
console.log(`stream up ${live.w}x${live.h} nonBlack=${live.nonBlackPct}% after ${Date.now() - tClick} ms`);

// Focus the video, then let the scene settle so the pre-typing screenshot is
// the station's real resting state.
const vbox = await page.locator('video').first().boundingBox();
if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
await page.waitForTimeout(2000);
await page.screenshot({ path: `${OUT}/${tag}-${TS}-before.png` });

// Type at a human pace. Playwright's own delay option would serialise inside
// one call; pressing per character with an explicit wait is closer to a
// visitor, and lets each keystroke be timed.
const perKey = [];
for (const ch of LINE) {
  const t0 = Date.now();
  await page.keyboard.press(ch === ' ' ? 'Space' : ch);
  perKey.push(Date.now() - t0);
  await page.waitForTimeout(PACE_MS);
}
await page.keyboard.press('Enter');
await page.waitForTimeout(2500);

const after = await page.evaluate(probe);
await page.screenshot({ path: `${OUT}/${tag}-${TS}-after.png` });

const slow = perKey.filter((m) => m > 250).length;
console.log(`typed ${LINE.length} chars at ${PACE_MS} ms spacing`);
console.log(`keystroke dispatch ms: max=${Math.max(...perKey)} over250ms=${slow}`);
console.log(`after: ${after ? `${after.w}x${after.h} nonBlack=${after.nonBlackPct}%` : 'no video'}`);
console.log(`shots: ${OUT}/${tag}-${TS}-before.png ${OUT}/${tag}-${TS}-after.png`);
if (logs.length) console.log(logs.slice(-10).join('\n'));
await browser.close();

// Paused-sink resume probe: reproduce the field black screen IN A REAL BROWSER
// and prove the picture comes back.
//
// THE BUG. Switching away from the installed PWA and back left a permanent
// black screen. The <video> was PAUSED on a VISIBLE page, readyState 4, right
// dimensions, no error — Chrome-Android pauses a media element when the app is
// backgrounded and nothing un-paused it on return. See videoResume.ts and
// docs/lab/STREAM-DEBUGGING.md.
//
// WHY THIS PROBE AND NOT A HEALTH CHECK. `videoWidth`, `readyState` and a
// non-black percentage ALL PASS on a paused element showing a stale frame — the
// exact trap idle-wake-browser-probe.mjs was written for. MOTION is the only
// proof: hash the decoded frame once a second and count DISTINCT ones. A sink
// that is not pulling yields exactly one, however healthy it looks.
//
// Run it against helenos: its taskbar clock ticks, so per-second change is
// guaranteed and distinct==1 means the sink stopped, not that the desktop is
// idle. Against a still desktop this probe cannot distinguish the two and will
// say so rather than pass.
//
// THE REPRODUCTION is CDP Page.setWebLifecycleState('frozen') — the same
// lifecycle transition Chrome-Android applies to a backgrounded PWA — followed
// by 'active'. Where that alone does not pause the element (desktop Chrome is
// not obliged to), the probe pauses it explicitly and dispatches the
// visibility transition, which reproduces the field state exactly: a paused
// element on a visible page.
//
//   node paused-sink-resume-probe.mjs <station> [clock-rect]
//   BASE=/staging/resume-black-fix/ node paused-sink-resume-probe.mjs helenos 982,747,29,10
//
// env: GALLERY_URL, LAB_HOST, BASE (default '/' = the LIVE bundle),
//      SAMPLE_SECS (default 6), BG_SECS (default 5), OUT_DIR
// exit: 0 probe ran (read the numbers) · 1 the stream never came up
import { chromium } from 'playwright';
import fs from 'node:fs';

const STATION = process.argv[2] || 'helenos';
const RECT = (process.argv[3] || '').split(',').map(Number);
const SAMPLE_SECS = Number(process.env.SAMPLE_SECS || 6);
const BG_SECS = Number(process.env.BG_SECS || 5);
const BASE = process.env.BASE || '/';
// Placeholder per the repo's address rule: the real host comes from LAB_HOST.
const GALLERY_URL =
  process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = process.env.OUT_DIR || `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const tag = `sink-${STATION}-${BASE.replace(/[^a-z0-9]+/gi, '') || 'live'}-${Date.now()}`;
const say = (...a) => console.log(...a);

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

const url = `${GALLERY_URL}${BASE}os/${STATION}`.replace(/([^:])\/\//g, '$1/');
say(`open ${url}`);
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });

// One in-page sampler: the element's own state PLUS a frame signature, so the
// two halves of the claim (is it paused / is it moving) are read together.
const sample = (rect) => {
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = {
      w: v.videoWidth, h: v.videoHeight, readyState: v.readyState,
      paused: v.paused, currentTime: Number(v.currentTime.toFixed(2)),
      err: v.error ? v.error.code : null, vis: document.visibilityState,
    };
    if (!(rec.w > 0 && v.readyState >= 2)) return rec;
    try {
      const c = document.createElement('canvas');
      c.width = rec.w; c.height = rec.h;
      const ctx = c.getContext('2d');
      ctx.drawImage(v, 0, 0);
      const full = ctx.getImageData(0, 0, rec.w, rec.h).data;
      let nonBlack = 0, n = 0, h = 0x811c9dc5;
      for (let i = 0; i < full.length; i += 400) {
        n++;
        if (full[i] + full[i + 1] + full[i + 2] > 30) nonBlack++;
        h ^= full[i] + full[i + 1] * 3 + full[i + 2] * 7;
        h = Math.imul(h, 0x01000193) >>> 0;
      }
      rec.nonBlackPct = Math.round((100 * nonBlack) / Math.max(1, n));
      rec.sig = h.toString(16);
      if (rect && rect.length === 4 && rect[2] > 0 && rect[3] > 0) {
        const r = ctx.getImageData(rect[0], rect[1], rect[2], rect[3]).data;
        let rh = 0x811c9dc5;
        for (let i = 0; i < r.length; i += 4) {
          rh ^= r[i] + r[i + 1] * 3 + r[i + 2] * 7;
          rh = Math.imul(rh, 0x01000193) >>> 0;
        }
        rec.rectSig = rh.toString(16);
      }
    } catch (e) { rec.err = String(e).slice(0, 80); }
    return rec;
  }
  return null;
};

const waitMs = Number(process.env.PROBE_WAIT_MS || 60000);
let live = null;
for (let waited = 0; waited < waitMs; waited += 500) {
  live = await page.evaluate(sample, RECT);
  if (live && live.w > 0 && live.readyState >= 2) break;
  await page.waitForTimeout(500);
}
if (!live || !live.w) {
  say(`FAIL: no live stream video after ${waitMs} ms`);
  say(logs.slice(-15).join('\n'));
  await browser.close();
  process.exit(1);
}
say(`stream up ${live.w}x${live.h} paused=${live.paused} rs=${live.readyState} nonBlack=${live.nonBlackPct}%`);

const motion = async (label, secs) => {
  const sigs = [], rects = [], states = [];
  for (let i = 0; i < secs; i++) {
    const s = await page.evaluate(sample, RECT);
    if (s && s.sig) sigs.push(s.sig);
    if (s && s.rectSig) rects.push(s.rectSig);
    if (s) states.push(s);
    await page.waitForTimeout(1000);
  }
  const d = new Set(sigs).size, dr = new Set(rects).size;
  const last = states[states.length - 1] || {};
  say(
    `motion[${label}]: ${sigs.length} samples/${secs}s -> ${d} distinct frame(s)` +
    (rects.length ? `, ${dr} distinct clock value(s)` : '') +
    `  paused=${last.paused} ct=${last.currentTime} vis=${last.vis}` +
    `  ${d > 1 ? 'PICTURE IS MOVING' : 'FROZEN (one distinct frame)'}`,
  );
  return { distinct: d, distinctRect: dr, last };
};

const before = await motion('baseline', SAMPLE_SECS);
await page.screenshot({ path: `${OUT}/${tag}-1-baseline.png` });

// ---- REPRODUCE: background the PWA, then bring it back ----------------------
const cdp = await page.context().newCDPSession(page);
say(`backgrounding for ${BG_SECS}s via Page.setWebLifecycleState('frozen')`);
try {
  // 'frozen' and 'active' are the ONLY states this CDP method accepts; asking
  // for 'hidden' throws "Unidentified lifecycle" and skips the freeze entirely.
  await cdp.send('Page.setWebLifecycleState', { state: 'frozen' });
} catch (e) { say(`  (lifecycle: ${String(e).slice(0, 90)})`); }
await page.waitForTimeout(BG_SECS * 1000);
try { await cdp.send('Page.setWebLifecycleState', { state: 'active' }); } catch { /* noop */ }
await page.waitForTimeout(1000);

let s = await page.evaluate(sample, RECT);
say(`after thaw: paused=${s?.paused} vis=${s?.vis} rs=${s?.readyState} ct=${s?.currentTime}`);

// Desktop Chrome is not obliged to pause on freeze the way Chrome-Android does.
// Where it did not, reproduce the field state EXACTLY — pause the element and
// hand the page a foreground transition — so the probe tests the same thing on
// either host. The bug is "paused while visible", not "how it got paused".
if (!s?.paused) {
  // Reproduce the FIELD SEQUENCE, not just the end state. Chrome-Android pauses
  // the element while the app is in the BACKGROUND, so the pause happens with
  // the page hidden — where a pause is CORRECT and must not be undone. Only the
  // return to the foreground may resume it. Pausing while visible would let a
  // fix that only listens for the element's own `pause` event pass without ever
  // exercising the foreground path, which is the one Android actually needs.
  say('forcing the FIELD SEQUENCE: hide, pause while hidden, then foreground');
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'hidden' });
    document.dispatchEvent(new Event('visibilitychange'));
    const v = [...document.querySelectorAll('video')].find((x) => x.srcObject);
    if (v) v.pause();
  });
  await page.waitForTimeout(800);
  s = await page.evaluate(sample, RECT);
  say(`  paused while hidden: paused=${s?.paused} vis=${s?.vis} ct=${s?.currentTime}` +
      `  ${s?.paused ? '(correct — a hidden page stays paused)' : '(WRONG: woke a backgrounded exhibit)'}`);
  // Back to the foreground. From here on the page is visible and paused: the
  // exact state the operator's tab was in.
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
  });
}

// The black phase, measured. This is what the operator saw.
const paused = await motion('paused-sink', SAMPLE_SECS);
await page.screenshot({ path: `${OUT}/${tag}-2-paused.png` });

// ---- THE RESUME SIGNAL -----------------------------------------------------
// Exactly what an app switch delivers, and nothing more: no play() from the
// probe. If the picture comes back, the BUNDLE resumed it.
say("dispatching the foreground signal (visibilitychange + pageshow + focus)");
await page.evaluate(() => {
  document.dispatchEvent(new Event('visibilitychange'));
  window.dispatchEvent(new PageTransitionEvent('pageshow', { persisted: true }));
  window.dispatchEvent(new Event('focus'));
});
await page.waitForTimeout(1500);
const resumed = await motion('after-foreground', SAMPLE_SECS);
await page.screenshot({ path: `${OUT}/${tag}-3-after-foreground.png` });

say('');
say(`VERDICT [${BASE}]`);
say(`  baseline          distinct=${before.distinct} rect=${before.distinctRect}`);
say(`  paused sink       distinct=${paused.distinct} rect=${paused.distinctRect} paused=${paused.last.paused}`);
say(`  after foreground  distinct=${resumed.distinct} rect=${resumed.distinctRect} paused=${resumed.last.paused}`);
say(`  ${resumed.distinct > 1 && !resumed.last.paused
    ? 'RESUMED — the sink is pulling and the picture is MOVING'
    : 'STILL BLACK — the sink never resumed'}`);
if (before.distinct <= 1) {
  say('  WARNING: the baseline itself showed no motion — this station cannot');
  say('           prove the claim. Use one with a ticking clock (helenos).');
}
const sink = logs.filter((l) => /sink-resumed|sink-blocked|sink-stalled|connect-retry/.test(l));
if (sink.length) say(`  client rows: ${sink.slice(-6).join(' | ')}`);
say(`shots: ${OUT}/${tag}-1-baseline.png ${OUT}/${tag}-2-paused.png ${OUT}/${tag}-3-after-foreground.png`);

await page.close();
await browser.close();

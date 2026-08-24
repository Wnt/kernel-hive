// Idle-wake browser probe: prove, FROM THE BROWSER, that opening a station in
// the real SPA wakes an idle-auto-paused guest, that typed input reaches it,
// and that the guest re-pauses after the session closes.
//
// WHY A NEW PROBE. typing-pace-probe.mjs proves a stream decodes and that keys
// dispatch. Neither fact distinguishes a RUNNING guest from a PAUSED one: a
// paused guest still streams — the encoder keeps emitting frames of a frozen
// screen, so `videoWidth > 0`, `readyState >= 2` and a healthy `nonBlack%` are
// all exactly what a frozen station produces too. Every one of those signals
// passes on a guest whose vCPUs are stopped.
//
// The only browser-side signal that separates them is MOTION: frame-to-frame
// change in the decoded video. A paused guest cannot produce it; a live one
// cannot avoid it. So this samples the <video> repeatedly, hashes each frame,
// and reports how many DISTINCT frames it saw. distinct == 1 over a multi-second
// window is a frozen guest, however healthy the stream looks.
//
// Some stations hand this a free clock: helenos renders a ticking taskbar clock
// (station.env names the exact rect), so a second, narrower sampler watches a
// caller-supplied rect where per-second change is guaranteed. Full-frame
// distinct-count is the robust signal; the rect is the corroborating one.
//
// PASS/FAIL is not decided here — this lab's rule is to print measurable
// numbers and leave the picture to an eye. Screenshots are the artifact.
//
//   node idle-wake-browser-probe.mjs <station> [line-to-type] [clock-rect]
//   node idle-wake-browser-probe.mjs helenos 'echo hello' 982,747,29,10
//
// env: GALLERY_URL (default https://$LAB_HOST:8443), LAB_HOST, PROBE_WAIT_MS,
//      SAMPLE_SECS (default 8), PACE_MS (default 140), OUT_DIR
import { chromium } from 'playwright';
import fs from 'node:fs';

const STATION = process.argv[2] || 'helenos';
const LINE = process.argv[3] ?? '';
const RECT = (process.argv[4] || '').split(',').map(Number);
const SAMPLE_SECS = Number(process.env.SAMPLE_SECS || 8);
const PACE_MS = Number(process.env.PACE_MS || 140);
// Placeholder per the repo's address rule: the real host comes from LAB_HOST.
const GALLERY_URL =
  process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;

const OUT = process.env.OUT_DIR || `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const TS = Date.now();
const tag = `${STATION}-${TS}`;
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

// The deep link IS the wake trigger: navigating to /os/<station> is what a
// visitor does, and the session it opens is what idle.rs must resume on.
const tOpen = Date.now();
say(`open ${GALLERY_URL}/os/${STATION}`);
await page.goto(`${GALLERY_URL}/os/${STATION}`, { waitUntil: 'domcontentloaded', timeout: 30000 });

// One in-page sampler used for every measurement below. Returns a frame
// signature (cheap FNV-1a over subsampled pixels) plus the same liveness
// fields typing-pace-probe reports, so the two are comparable.
const sample = (rect) => {
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = { w: v.videoWidth, h: v.videoHeight, readyState: v.readyState };
    if (!(rec.w > 0 && v.readyState >= 2)) return rec;
    try {
      const c = document.createElement('canvas');
      c.width = rec.w;
      c.height = rec.h;
      const ctx = c.getContext('2d');
      ctx.drawImage(v, 0, 0);
      const full = ctx.getImageData(0, 0, rec.w, rec.h).data;
      let nonBlack = 0;
      let n = 0;
      let h = 0x811c9dc5;
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
    } catch (e) {
      rec.err = String(e).slice(0, 80);
    }
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
const tFirstFrame = Date.now() - tOpen;
say(`stream up ${live.w}x${live.h} nonBlack=${live.nonBlackPct}% after ${tFirstFrame} ms`);

// --- THE CLAIM: is the guest actually RUNNING? -------------------------------
// Sample once a second and count distinct frame signatures. A paused guest
// yields exactly one; a live desktop with a ticking clock yields roughly one
// per second.
const motion = async (label, secs) => {
  const sigs = [];
  const rects = [];
  for (let i = 0; i < secs; i++) {
    const s = await page.evaluate(sample, RECT);
    if (s && s.sig) sigs.push(s.sig);
    if (s && s.rectSig) rects.push(s.rectSig);
    await page.waitForTimeout(1000);
  }
  const d = new Set(sigs).size;
  const dr = new Set(rects).size;
  say(
    `motion[${label}]: ${sigs.length} samples over ${secs}s -> ${d} distinct frame(s)` +
      (rects.length ? `, ${dr} distinct clock-rect value(s)` : '') +
      `  ${d > 1 ? 'GUEST IS RUNNING' : 'FROZEN (only one distinct frame)'}`,
  );
  return { samples: sigs.length, distinct: d, distinctRect: dr };
};

const mOpen = await motion('after-open', SAMPLE_SECS);
await page.screenshot({ path: `${OUT}/${tag}-1-awake.png` });
say(`shot: ${OUT}/${tag}-1-awake.png`);

// --- Input reaches the guest -------------------------------------------------
let typed = null;
if (LINE) {
  const vbox = await page.locator('video').first().boundingBox();
  if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${OUT}/${tag}-2-before-typing.png` });
  const perKey = [];
  for (const ch of LINE) {
    const t0 = Date.now();
    await page.keyboard.press(ch === ' ' ? 'Space' : ch);
    perKey.push(Date.now() - t0);
    await page.waitForTimeout(PACE_MS);
  }
  await page.waitForTimeout(2000);
  await page.screenshot({ path: `${OUT}/${tag}-3-typed.png` });
  typed = { chars: LINE.length, maxMs: Math.max(...perKey), over250: perKey.filter((m) => m > 250).length };
  say(`typed ${typed.chars} chars at ${PACE_MS} ms spacing; dispatch max=${typed.maxMs} ms over250=${typed.over250}`);
  say(`shots: ${OUT}/${tag}-2-before-typing.png ${OUT}/${tag}-3-typed.png`);
}

const mEnd = await motion('before-close', Math.min(4, SAMPLE_SECS));
await page.screenshot({ path: `${OUT}/${tag}-4-final.png` });
say(`shot: ${OUT}/${tag}-4-final.png`);

// Closing the page ends the WebTransport session, which is what starts the
// idle grace clock again. The caller checks re-pause out of band.
await page.close();
await browser.close();
say(`session closed at ${new Date().toISOString()}`);
say(
  JSON.stringify({
    station: STATION,
    firstFrameMs: tFirstFrame,
    afterOpen: mOpen,
    typed,
    beforeClose: mEnd,
  }),
);
if (logs.length) say(logs.slice(-10).join('\n'));

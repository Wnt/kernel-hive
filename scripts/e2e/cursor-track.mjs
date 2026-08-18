// cursor-track.mjs — validate a relative-pointer station's open-loop cursor via
// the REAL SPA: drive the browser pointer to known guest targets and measure
// where the guest cursor actually landed (QMP screendump + nudge-diff locate on
// labhost). Tests tracking accuracy, the reload anchor, and drag-release.
//
//   GALLERY_URL=https://<lab>:8443 node cursor-track.mjs <station> "<Card Name>" [guestW guestH]
//
// Runs headed on CT950's VNC desktop (DISPLAY=:1), like the other e2e probes;
// resolve `playwright` from ~/e2e/node_modules (copy this file there or symlink).
// The guest-cursor locator is scripts/dev/measure-golden-cursor.py, invoked over
// `ssh lab` (staged to /tmp/mgc.py by the caller). See
// docs/lab/research/rel-pointer-rehome-and-rate-cap.md.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';

const STATION = process.argv[2];
const CARD = process.argv[3] || STATION;
const URL = process.env.GALLERY_URL || 'https://192.0.2.10:8443';
const OUT = `${process.env.HOME}/e2e/shots`;
fs.mkdirSync(OUT, { recursive: true });
const TS = Date.now();
const log = (...a) => console.error('#', ...a);

// Locate the guest cursor NOW (guest px) via the labhost QMP nudge-diff locator.
function locate() {
  try {
    const out = execFileSync('ssh', ['lab', `python3 /tmp/mgc.py ${STATION} --no-reset 2>/dev/null`],
      { encoding: 'utf8', timeout: 60000 });
    const m = out.match(/HOME_TO=(\d+),(\d+)/);
    return m ? { x: +m[1], y: +m[2] } : null;
  } catch (e) { log('locate err', String(e).slice(0, 120)); return null; }
}

const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
page.on('pageerror', e => log('pageerror', String(e).slice(0, 200)));

await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.waitForTimeout(3000);
const card = page.getByText(new RegExp(CARD.replace(/[.]/g, '\\.'), 'i')).first();
await card.scrollIntoViewIfNeeded();
const cbox = await card.boundingBox();
if (!cbox) { console.log('FAIL: no card'); await browser.close(); process.exit(1); }
await page.mouse.click(cbox.x + cbox.width / 2, cbox.y + cbox.height / 2);

const probe = () => {
  for (const v of document.querySelectorAll('video')) {
    if (v.srcObject && v.videoWidth > 0 && v.readyState >= 2) return { w: v.videoWidth, h: v.videoHeight };
  }
  return null;
};
let vinfo = null;
for (let i = 0; i < 30 && !vinfo; i++) { await page.waitForTimeout(1000); vinfo = await page.evaluate(probe); }
if (!vinfo) { console.log('FAIL: no live video'); await browser.close(); process.exit(1); }
const GW = +(process.argv[4] || vinfo.w), GH = +(process.argv[5] || vinfo.h);
log('video', JSON.stringify(vinfo), 'guest', GW, 'x', GH);

const video = page.locator('video').last();
const vbox = await video.boundingBox();
// focus / acquire control
await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
await page.waitForTimeout(1500);

// guest px -> screen coord. The <video> is object-fit:contain, so the guest
// content is letterboxed inside the element box; map to the CONTENT area (this
// mirrors the SPA's clientToGuest) or an off-centre target lands scaled.
const _scale = Math.min(vbox.width / GW, vbox.height / GH);
const _cW = GW * _scale, _cH = GH * _scale;
const _ox = vbox.x + (vbox.width - _cW) / 2, _oy = vbox.y + (vbox.height - _cH) / 2;
const toScreen = (gx, gy) => ({ x: _ox + gx * _scale, y: _oy + gy * _scale });
async function moveTo(gx, gy, steps = 12) {
  const s = toScreen(gx, gy);
  await page.mouse.move(s.x, s.y, { steps });
  await page.waitForTimeout(700);
}

const results = { station: STATION, guest: [GW, GH], points: [], reload: null, drag: null };
// Grid of guest targets (avoid the extreme edges where cursors clamp at W-2)
const pts = [[GW * 0.5, GH * 0.5], [GW * 0.25, GH * 0.3], [GW * 0.75, GH * 0.35],
             [GW * 0.3, GH * 0.7], [GW * 0.7, GH * 0.7]].map(p => [Math.round(p[0]), Math.round(p[1])]);
log('=== tracking accuracy ===');
for (const [gx, gy] of pts) {
  await moveTo(gx, gy);
  const m = locate();
  const err = m ? Math.round(Math.hypot(m.x - gx, m.y - gy)) : null;
  results.points.push({ target: [gx, gy], measured: m && [m.x, m.y], errPx: err });
  log(`target (${gx},${gy}) -> measured ${m ? `(${m.x},${m.y})` : 'none'}  err=${err}px`);
}

// Reload anchor: reload, re-acquire video, move to a fresh target, expect small err
log('=== reload anchor ===');
await page.reload({ waitUntil: 'domcontentloaded' });
let v2 = null; for (let i = 0; i < 30 && !v2; i++) { await page.waitForTimeout(1000); v2 = await page.evaluate(probe); }
if (v2) {
  const nv = await page.locator('video').last().boundingBox();
  vbox.x = nv.x; vbox.y = nv.y; vbox.width = nv.width; vbox.height = nv.height;
  await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
  await page.waitForTimeout(1500);
  const [gx, gy] = [Math.round(GW * 0.4), Math.round(GH * 0.6)];
  await moveTo(gx, gy);
  const m = locate();
  const err = m ? Math.round(Math.hypot(m.x - gx, m.y - gy)) : null;
  results.reload = { target: [gx, gy], measured: m && [m.x, m.y], errPx: err };
  log(`after reload: target (${gx},${gy}) -> ${m ? `(${m.x},${m.y})` : 'none'}  err=${err}px`);
} else log('reload: no video');

// Drag-release: press at A, drag to B, release, cursor should end at B
log('=== drag release ===');
const A = [Math.round(GW * 0.4), Math.round(GH * 0.4)], B = [Math.round(GW * 0.6), Math.round(GH * 0.65)];
await moveTo(...A);
const sB = toScreen(...B);
await page.mouse.down();
await page.mouse.move(sB.x, sB.y, { steps: 3 }); // fast drag
await page.mouse.up();
await page.waitForTimeout(800);
const md = locate();
const derr = md ? Math.round(Math.hypot(md.x - B[0], md.y - B[1])) : null;
results.drag = { from: A, to: B, measured: md && [md.x, md.y], errPx: derr };
log(`drag ${A}->${B} released at ${md ? `(${md.x},${md.y})` : 'none'}  err=${derr}px`);

await page.screenshot({ path: `${OUT}/cursor-track-${STATION}-${TS}.png` });
fs.writeFileSync(`${OUT}/cursor-track-${STATION}-${TS}.json`, JSON.stringify(results, null, 2));
const errs = results.points.map(p => p.errPx).filter(e => e != null);
const maxErr = errs.length ? Math.max(...errs) : 999;
const ok = maxErr <= 12 && (results.reload?.errPx ?? 999) <= 15 && (results.drag?.errPx ?? 999) <= 20;
console.log(`RESULT ${STATION}: track_max=${maxErr}px reload=${results.reload?.errPx}px drag=${results.drag?.errPx}px -> ${ok ? 'PASS' : 'REVIEW'}`);
console.log(`shots: ${OUT}/cursor-track-${STATION}-${TS}.{png,json}`);
await browser.close();
process.exit(ok ? 0 : 2);

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
import { openStation, probeVideo, shotDir, galleryUrl } from './station-open.mjs';

const STATION = process.argv[2];
// argv[3] used to be a CARD NAME matched with getByText — it selected prose as
// happily as it selected the tile, and a miss looked exactly like a dead
// stream. Cards are resolved by href now (station-open.mjs); the argument is
// accepted and ignored so old invocations do not silently change meaning.
const URL = galleryUrl();
const OUT = shotDir();
const TS = Date.now();
const log = (...a) => console.error('#', ...a);

// Locate the guest cursor NOW (guest px) via the labhost QMP nudge-diff locator.
//
// TWO TRANSPORTS, because CT950 — where this probe runs — has NO ssh route to
// labhost. The original `ssh lab` call therefore always threw, was swallowed by
// the catch, and reported `measured: none`. That reads as "the guest cursor did
// not move", which is a claim about the STATION that a transport failure has no
// standing to make. So a locator failure is now LOUD and distinguishable.
//   KH_LOCATE_RELAY=<dir>  → file-drop RPC answered by scripts/e2e/locate-relay.sh
//   otherwise              → direct `ssh lab` (works from a workstation session)
const RELAY = process.env.KH_LOCATE_RELAY || '';
// Two very different failures, kept apart on purpose:
//   locateErrors  — the locator could not be REACHED or crashed. The run is
//                   worthless; nothing was measured.
//   locateNoMatch — the locator ran and honestly said "the screen was too busy
//                   here to tell". That is one lost sample, not a broken run,
//                   and a live desktop with a redrawing window produces them.
// Collapsing the two made a healthy control print UNTRUSTWORTHY over a single
// busy frame, which would have trained the reader to ignore the word.
let locateErrors = 0;
let locateNoMatch = 0;
// The locator reports the framebuffer size on EVERY answer, including NO_MATCH —
// it read the screendump either way. Keeping it here means a busy first frame
// costs us one sample instead of the whole run's coordinate space.
let lastFb = null;

function locateViaRelay() {
  const id = `${TS}-${Math.random().toString(36).slice(2, 8)}`;
  fs.writeFileSync(`${RELAY}/req/${id}`, STATION);
  const deadline = Date.now() + 120000;
  while (Date.now() < deadline) {
    const respPath = `${RELAY}/resp/${id}`;
    if (fs.existsSync(respPath)) {
      const out = fs.readFileSync(respPath, 'utf8');
      fs.unlinkSync(respPath);
      return out;
    }
    // Busy-wait is fine: this probe has nothing else to do while the guest
    // settles, and the relay answers in ~2s.
    execFileSync('sleep', ['0.2']);
  }
  throw new Error('relay timeout');
}

function locate() {
  try {
    const out = RELAY
      ? locateViaRelay()
      : execFileSync('ssh', ['lab', `python3 /tmp/mgc.py ${STATION} --no-reset`], {
          encoding: 'utf8',
          timeout: 120000,
        });
    // AT= is locate-live-cursor.py (animation-masked, live-safe); HOME_TO= is
    // the older golden tool. NO_MATCH is a real, honest answer and must NOT be
    // read as a coordinate.
    const fbAny = out.match(/\bFB=(\d+)x(\d+)/);
    if (fbAny) lastFb = [+fbAny[1], +fbAny[2]];
    const m = out.match(/\b(?:AT|HOME_TO)=(\d+),(\d+)/);
    if (!m) {
      if (/NO_MATCH/.test(out)) locateNoMatch++;
      else locateErrors++;
      log('LOCATE-NO-MATCH:', out.replace(/\s+/g, ' ').slice(0, 200));
      return null;
    }
    const fb = out.match(/\bFB=(\d+)x(\d+)/);
    return { x: +m[1], y: +m[2], fb: fb ? [+fb[1], +fb[2]] : null };
  } catch (e) {
    locateErrors++;
    log('LOCATE-ERROR:', String(e).replace(/\s+/g, ' ').slice(0, 200));
    return null;
  }
}

const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
page.on('pageerror', e => log('pageerror', String(e).slice(0, 200)));

const opened = await openStation(page, URL, STATION, { log, waitMs: 45000 });
if (!opened.ok) {
  // Say WHICH leg failed. "no live video" after a click that never navigated is
  // a broken probe, not a station finding, and the two must never read alike.
  await page.screenshot({ path: `${OUT}/cursor-track-${STATION}-${TS}-openfail.png` }).catch(() => {});
  console.log(`FAIL(probe): ${opened.why}  url=${opened.url}`);
  await browser.close();
  process.exit(1);
}
const probe = probeVideo;
const vinfo = opened.video;

// THE GUEST COORDINATE SPACE IS THE FRAMEBUFFER, NOT `videoWidth`.
//
// This probe used to take the guest resolution from the <video> element. That
// is wrong whenever ABR is downscaling: on a loaded box the same win311 tile
// reported 1024x768 on one run and 768x576 on the next, and the second run's
// errors came out at 78-216px — all of them exactly the 1024/768 ratio. The
// station was fine. The probe had simply aimed in a coordinate space nobody
// else was using: the SPA maps a pointer to a FRACTION of the content box and
// the guest lands it in TRUE framebuffer pixels, so a shrunken decode changes
// nothing about where the cursor should go.
//
// A run that silently rescales its own targets manufactures a station fault out
// of an encoder decision, which is the single most expensive kind of false
// finding this harness can produce. So the framebuffer size comes from the
// locator's own screendump — the same image the measurement is read from, so
// target and measurement cannot drift into different spaces.
function sniffFramebuffer(tries = 3) {
  for (let i = 0; i < tries; i++) {
    const probeRes = locate();
    if (probeRes && probeRes.fb) return probeRes.fb;
    if (lastFb) return lastFb; // NO_MATCH still told us the framebuffer size
  }
  return null;
}
let GW = +(process.argv[4] || 0), GH = +(process.argv[5] || 0);
if (!(GW > 0 && GH > 0)) {
  const fb = sniffFramebuffer();
  if (!fb) {
    console.log('FAIL(probe): could not read the framebuffer size from the locator — refusing to guess a coordinate space.');
    await browser.close();
    process.exit(1);
  }
  [GW, GH] = fb;
  // The calibration call is not a measurement; do not let it colour the verdict.
  locateNoMatch = 0;
  locateErrors = 0;
}
log('video', JSON.stringify(vinfo), 'guest(framebuffer)', GW, 'x', GH,
    vinfo && vinfo.w !== GW ? `(NOTE: decode is ${vinfo.w}x${vinfo.h} — ABR is downscaling)` : '');

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
results.locateErrors = locateErrors;
results.locateNoMatch = locateNoMatch;
const measured = errs.length;
const ok = measured >= 3 && maxErr <= 12 && (results.reload?.errPx ?? 999) <= 15 && (results.drag?.errPx ?? 999) <= 20;
// A run whose LOCATOR could not be reached measures nothing. Saying REVIEW there
// invites the reader to treat a broken transport as a station fault, so it gets
// its own word. Same if too few points survived to say anything.
const untrustworthy = locateErrors > 0 || measured < 3;
if (locateErrors) {
  console.log(`LOCATOR-BROKEN ${STATION}: ${locateErrors} locate call(s) could not run — this run measures NOTHING about the station.`);
}
if (locateNoMatch) {
  console.log(`NOTE ${STATION}: ${locateNoMatch} point(s) unmeasurable (screen too busy at that moment) — lost samples, not a fault.`);
}
console.log(`RESULT ${STATION}: points=${measured}/${results.points.length} track_max=${maxErr}px reload=${results.reload?.errPx}px drag=${results.drag?.errPx}px errors=${locateErrors} nomatch=${locateNoMatch} -> ${untrustworthy ? 'UNTRUSTWORTHY' : ok ? 'PASS' : 'REVIEW'}`);
console.log(`shots: ${OUT}/cursor-track-${STATION}-${TS}.{png,json}`);
await browser.close();
process.exit(ok ? 0 : 2);

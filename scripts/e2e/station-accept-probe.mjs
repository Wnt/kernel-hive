// station-accept-probe.mjs — the browser leg of station acceptance (rule 9 as code).
//
// THE BOUNDARY IS THE POINT, AND IT IS NOT NEGOTIABLE.
//   browser client -> SPA/signaling -> streamhost daemon -> input sink -> device
//   -> guest -> framebuffer
// This probe drives a real browser at the real origin, exactly as a visitor
// does. It never speaks to the chardev, the ctl socket or the device. On
// 2026-08-30 five independent, rigorous agents each drew the proof boundary one
// component short of what ships -- their harnesses spoke the control protocol
// to QEMU directly with streamhost NOT RUNNING -- and the only untested
// component was the only one that broke. No repetition count could have reached
// it. That is a boundary gap, not a sampling gap, so the boundary is fixed here
// in code rather than left to each author's judgement.
//
// WHAT COUNTS AS EVIDENCE: INTER-FRAME MOTION, IN THE EXPECTED PLACE.
// `videoWidth`, `readyState` and non-black percentage ALL PASS ON A STOPPED
// STREAM -- a paused element showing a stale frame satisfies every one of them.
// They are preconditions here, never evidence. The evidence is that successive
// frames of the SAME rectangle differ after a commanded interaction.
//
// SESSION CHURN IS MANDATORY, INCLUDING ONE ABANDONED SESSION.
// The rhapsody cutover failed with a perfect pointer mechanism: the guest's own
// coordinate read back exactly the commanded target, and every session after
// the first timed out negotiating (40 SESSION_ACCEPTED, zero completed). Every
// sandbox proof in that wave used ONE session, so the method certified the exact
// defect by construction. A single-session acceptance run is not an acceptance
// run.
//
// The cause was daemon-wide QMP contention from the OBSERVATION HARNESS, not a
// per-session leak (corrected 2026-08-31 from a four-run control matrix; there
// is no per-session sink state to leak). So sequential churn is confirmed — a
// daemon-wide stall is invisible to one session — while this probe must be
// careful not to become the same defect: it holds no exclusive resource, and
// its sampling interval is bounded per station for exactly that reason.
//
// The abandoned session is SIGKILLed, not closed. A `page.close()` still runs
// an orderly teardown, which is the path that already works; the untested path
// is a visitor's laptop lid closing, with QUIC dying and no close frame. So
// that session gets its own browser process and we kill it.
//
// STATUS: PRECAUTION, NOT AN EVIDENCED REQUIREMENT. Its original warrant was a
// per-session leak at teardown, and that cause was disproved (see the verdict
// module). It has caught nothing so far. It stays because an ungraceful
// disconnect is real visitor behaviour rather than a hypothesis, and it is
// cheap. If you find the refuted rationale later, that is not a reason to drop
// this: it was never justified by that rationale, so disproving it takes
// nothing away.
//
// usage:
//   node station-accept-probe.mjs --station <id> [options]
// options:
//   --sessions N        sequential sessions to run (default 3, minimum 2)
//   --abandon-at K      1-based index of the session to SIGKILL (default 2)
//   --rect x,y,w,h      guest-pixel rectangle watched for motion (required)
//   --sample-ms N       ms between framebuffer samples (default 1000)
//   --samples N         samples per motion window (default 6)
//   --guest WxH         guest framebuffer size, for pointer mapping
//   --point x,y         guest-pixel point to move the pointer to and click
//   --rate-hz N         pointer-stream rate for the burst leg (0 = off)
//   --rate-ms N         how long to sustain that rate
//   --wait-ms N         how long to wait for a live stream (default 60000)
//   --base URL          origin (default https://$LAB_HOST:8443)
//   --path PREFIX       bundle prefix, e.g. /staging/<slot>/ (default /)
//   --out DIR           screenshots (default $HOME/e2e/shots)
// output: human lines on STDERR, exactly one JSON object on STDOUT.
// exit:   0 the probe RAN (read the JSON) · 1 it could not run at all.
//         The pass/fail judgement belongs to station-accept.sh, not here.

import { chromium } from 'playwright';
import fs from 'node:fs';

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
};
const num = (name, dflt) => Number(arg(name, String(dflt)));

const STATION = arg('station', '');
const SESSIONS = Math.max(2, num('sessions', 3));
const ABANDON_AT = num('abandon-at', 2);
const RECT = (arg('rect', '') || '').split(',').map(Number);
const SAMPLE_MS = num('sample-ms', 1000);
const SAMPLES = num('samples', 6);
const WAIT_MS = num('wait-ms', 60000);
const OUT = arg('out', `${process.env.HOME}/e2e/shots`);
const BASE = arg('base', `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`);
const PATH_PREFIX = arg('path', '/');
const GUEST = (arg('guest', '') || '').split('x').map(Number);
const POINT = (arg('point', '') || '').split(',').map(Number);
const RATE_HZ = num('rate-hz', 0);
const RATE_MS = num('rate-ms', 3000);

const log = (m) => process.stderr.write(`${m}\n`);
const die = (m) => {
  log(`station-accept-probe: ${m}`);
  process.exit(1);
};

if (!STATION) die('--station is required');
if (RECT.length !== 4 || RECT.some((n) => !Number.isFinite(n))) {
  die('--rect x,y,w,h is required — acceptance needs a place to watch, not a whole frame');
}
if (ABANDON_AT < 1 || ABANDON_AT > SESSIONS) die('--abandon-at must name one of the sessions');
fs.mkdirSync(OUT, { recursive: true });

// In-page sampler. Returns null when no stream-backed <video> exists yet.
// `rectSig` hashes EVERY pixel of the watched rectangle; `sig` subsamples the
// whole frame. The rect hash is the evidence, the frame hash is context.
const sample = (rect) => {
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = {
      w: v.videoWidth,
      h: v.videoHeight,
      readyState: v.readyState,
      paused: v.paused,
      currentTime: Number(v.currentTime.toFixed(2)),
      err: v.error ? v.error.code : null,
      vis: document.visibilityState,
    };
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
      const x = Math.max(0, Math.min(rect[0], rec.w - 1));
      const y = Math.max(0, Math.min(rect[1], rec.h - 1));
      const w = Math.max(1, Math.min(rect[2], rec.w - x));
      const hh = Math.max(1, Math.min(rect[3], rec.h - y));
      const r = ctx.getImageData(x, y, w, hh).data;
      let rh = 0x811c9dc5;
      for (let i = 0; i < r.length; i += 4) {
        rh ^= r[i] + r[i + 1] * 3 + r[i + 2] * 7;
        rh = Math.imul(rh, 0x01000193) >>> 0;
      }
      rec.rectSig = rh.toString(16);
      rec.rectApplied = [x, y, w, hh];
    } catch (e) {
      rec.err = String(e).slice(0, 80);
    }
    return rec;
  }
  return null;
};

const launch = () =>
  chromium.launch({
    headless: false,
    channel: 'chrome',
    args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
    env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
  });

const url = `${BASE}${PATH_PREFIX}os/${STATION}`.replace(/([^:])\/\//g, '$1/');

async function openLive(browser, logs) {
  const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
  page.on('console', (m) => logs.push(`[console.${m.type()}] ${m.text().slice(0, 200)}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${String(e).slice(0, 200)}`));
  const t0 = Date.now();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  let live = null;
  for (let waited = 0; waited < WAIT_MS; waited += 250) {
    live = await page.evaluate(sample, RECT);
    if (live && live.w > 0 && live.readyState >= 2 && live.rectSig) break;
    await page.waitForTimeout(250);
  }
  const negotiated = !!(live && live.rectSig);
  return { page, live, negotiated, firstFrameMs: negotiated ? Date.now() - t0 : null };
}

// Motion in the WATCHED RECTANGLE. Distinct rect signatures > 1 is the only
// thing this probe will call evidence.
async function motion(page, label) {
  const rects = [];
  const frames = [];
  let last = null;
  for (let i = 0; i < SAMPLES; i++) {
    const s = await page.evaluate(sample, RECT);
    if (s && s.rectSig) rects.push(s.rectSig);
    if (s && s.sig) frames.push(s.sig);
    if (s) last = s;
    if (i < SAMPLES - 1) await page.waitForTimeout(SAMPLE_MS);
  }
  const distinctRect = new Set(rects).size;
  log(
    `  motion[${label}]: ${rects.length} samples / ${SAMPLE_MS}ms -> ${distinctRect} distinct rect value(s), ` +
      `${new Set(frames).size} distinct frame(s)` +
      (last ? ` paused=${last.paused} ct=${last.currentTime}` : ''),
  );
  return { samples: rects.length, distinctRect, distinctFrame: new Set(frames).size, last };
}

// object-fit: contain — the <video> letterboxes, so a guest pixel maps into the
// CONTENT box, not the element box. Mirrors the SPA's own clientToGuest.
async function pointerTo(page, gx, gy) {
  const box = await page.locator('video').last().boundingBox();
  if (!box || GUEST.length !== 2) return null;
  const scale = Math.min(box.width / GUEST[0], box.height / GUEST[1]);
  const cw = GUEST[0] * scale;
  const ch = GUEST[1] * scale;
  const x = box.x + (box.width - cw) / 2 + gx * scale;
  const y = box.y + (box.height - ch) / 2 + gy * scale;
  await page.mouse.move(x, y, { steps: 12 });
  return { screen: [Math.round(x), Math.round(y)], guest: [gx, gy] };
}

// RATE IS A DEFECT CLASS OF ITS OWN, and it is the one a station author will
// naturally not test — a settled point-to-point command makes a cleaner proof,
// which is exactly why the gate rather than the author must own this.
//
// The kh-ramabs runaway is the evidence, from the fix's own source: issuing a
// second target before the first is consumed leaves BOTH deltas to land on top
// of the last write, the read-back disagrees and issues more, and it runs away.
// The patch says what that costs: "invisible to a rig that sends one target and
// waits: it first appeared as `gave up publishing 560,330 after 6 tries (guest
// holds 560,302)` the first time this was driven by a real browser session
// instead of one target at a time."
//
// So this drives a genuine pointer STREAM across the safe rectangle — a drag,
// not a sequence of settled clicks — and the orchestrator then reads the
// station's log for give-ups across the same window. `mouse.move` with `steps`
// emits intermediate moves at the browser's own cadence, which is the same
// shape a visitor's trackpad produces.
async function rateBurst(page, box, guest, rect) {
  if (!(RATE_HZ > 0) || guest.length !== 2 || !box) return null;
  const scale = Math.min(box.width / guest[0], box.height / guest[1]);
  const cw = guest[0] * scale;
  const ch = guest[1] * scale;
  const toScreen = (gx, gy) => [
    box.x + (box.width - cw) / 2 + gx * scale,
    box.y + (box.height - ch) / 2 + gy * scale,
  ];
  // Stay inside the watched rectangle: the burst must be able to produce the
  // motion the gate is already watching for, not wander off it.
  const [x0, y0, w, h] = rect;
  const legs = 6;
  const perLeg = Math.max(2, Math.round((RATE_HZ * (RATE_MS / 1000)) / legs));
  const t0 = Date.now();
  let commands = 0;
  for (let i = 0; i < legs && Date.now() - t0 < RATE_MS; i++) {
    const gx = x0 + (i % 2 === 0 ? w * 0.85 : w * 0.15);
    const gy = y0 + (h * (0.2 + 0.6 * (i / legs)));
    const [sx, sy] = toScreen(gx, gy);
    await page.mouse.move(sx, sy, { steps: perLeg });
    commands += perLeg;
  }
  const ms = Date.now() - t0;
  const hz = Math.round((1000 * commands) / Math.max(1, ms));
  log(`  rate burst: ${commands} pointer command(s) in ${ms}ms (~${hz}/s, target ${RATE_HZ}/s)`);
  return { commands, ms, hz, targetHz: RATE_HZ };
}

async function runSession(index, abandon) {
  const logs = [];
  const browser = await launch();
  const tag = `${STATION}-s${index}-${Date.now()}`;
  if (abandon) {
    // Abandoned mid-stream: get far enough to be negotiating, then kill the
    // BROWSER PROCESS so the QUIC connection dies with no close frame. An
    // orderly close is the path that already worked.
    const page = await browser.newPage({ ignoreHTTPSErrors: true });
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(Math.max(1500, SAMPLE_MS));
    const proc = browser.process();
    if (proc) proc.kill('SIGKILL');
    await browser.close().catch(() => {});
    log(`  session ${index}: ABANDONED mid-stream (SIGKILL, no teardown)`);
    return { index, abandoned: true, negotiated: null };
  }
  const { page, live, negotiated, firstFrameMs } = await openLive(browser, logs);
  if (!negotiated) {
    log(`  session ${index}: DID NOT NEGOTIATE within ${WAIT_MS}ms`);
    await page.screenshot({ path: `${OUT}/${tag}-no-negotiate.png` }).catch(() => {});
    await browser.close().catch(() => {});
    return { index, abandoned: false, negotiated: false, logs: logs.slice(-12) };
  }
  log(`  session ${index}: negotiated in ${firstFrameMs}ms, ${live.w}x${live.h}`);
  const idle = await motion(page, `s${index}-idle`);
  let pointer = null;
  let repaint = null;
  let rate = null;
  if (RATE_HZ > 0 && GUEST.length === 2) {
    const box = await page.locator('video').last().boundingBox();
    rate = await rateBurst(page, box, GUEST, RECT);
    await page.waitForTimeout(SAMPLE_MS);
  }
  if (POINT.length === 2 && GUEST.length === 2) {
    pointer = await pointerTo(page, POINT[0], POINT[1]);
    await page.waitForTimeout(SAMPLE_MS);
    const before = await page.evaluate(sample, RECT);
    await page.mouse.down();
    await page.mouse.up();
    const t0 = Date.now();
    let changed = false;
    for (let i = 0; i < SAMPLES; i++) {
      await page.waitForTimeout(SAMPLE_MS);
      const after = await page.evaluate(sample, RECT);
      if (after && before && after.rectSig !== before.rectSig) {
        changed = true;
        break;
      }
    }
    repaint = { changed, ms: Date.now() - t0 };
    log(`  session ${index}: click repaint ${changed ? 'SEEN' : 'NOT SEEN'} after ${repaint.ms}ms`);
  }
  await page.screenshot({ path: `${OUT}/${tag}-final.png` }).catch(() => {});
  await page.close().catch(() => {});
  await browser.close().catch(() => {});
  return {
    index,
    abandoned: false,
    negotiated: true,
    firstFrameMs,
    idle,
    pointer,
    repaint,
    rate,
    logs: logs.slice(-8),
  };
}

(async () => {
  log(`station-accept-probe: ${STATION} — ${SESSIONS} sequential session(s), abandoning #${ABANDON_AT}`);
  log(`  ${url}  rect=${RECT.join(',')}  sample=${SAMPLE_MS}ms x${SAMPLES}`);
  const sessions = [];
  for (let i = 1; i <= SESSIONS; i++) {
    sessions.push(await runSession(i, i === ABANDON_AT));
  }
  const after = sessions.filter((s) => !s.abandoned && s.index > ABANDON_AT);
  process.stdout.write(
    `${JSON.stringify({
      station: STATION,
      url,
      rect: RECT,
      sampleMs: SAMPLE_MS,
      rateHz: RATE_HZ,
      samples: SAMPLES,
      abandonedAt: ABANDON_AT,
      sessions,
      // The churn verdict: did a session AFTER the abandoned one negotiate and
      // show motion in the watched place? That is the rhapsody defect's shape.
      afterAbandon: {
        count: after.length,
        negotiated: after.filter((s) => s.negotiated).length,
        withMotion: after.filter((s) => s.idle && s.idle.distinctRect > 1).length,
      },
    })}\n`,
  );
  process.exit(0);
})().catch((e) => die(String(e)));

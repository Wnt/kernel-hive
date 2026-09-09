// readme-demo-capture.mjs — record the README's demo clip: a real visitor
// opening a real station on the PUBLIC gallery and driving it.
//
// WHY IT LIVES HERE. docs/media/demo.gif is the first thing anyone sees on
// GitHub, and the only claim it makes that matters is "this is live and you
// can touch it". That claim has to be re-provable: when the SPA is restyled or
// a station is retired, the GIF has to be re-recordable without anybody
// reconstructing how it was made. So the capture is a checked-in script, not a
// session's shell history.
//
// WHAT IT PRODUCES. One WebM of the PAGE VIEWPORT only (Playwright's
// recordVideo — no browser chrome, no address bar, so no internal host or IP
// can reach a frame; docs/lab/OPERATING-RULES.md rule 1). Trimming that clip
// to the GIF is a separate, deliberate step — see docs/media/README.md.
//
// THE PUBLIC URL IS THE POINT. It records against
// https://kernelhive.madekivi.fi, the one committable domain, over the same
// three gates a stranger meets (docs/PUBLIC-GALLERY.md). The invite code is a
// bearer secret: pass a PATH to it (the box's mode-600 sim-invite.code), never
// the literal code, so it stays out of argv, `ps` and this file's own log.
//
// RUN IT (from CT950, where `playwright` and a headed :1 desktop live):
//   cp scripts/e2e/readme-demo-capture.mjs ~/e2e/ && cd ~/e2e &&
//   INVITE=/data/vms/streamhost/serve/pki/sim-invite.code \
//   node readme-demo-capture.mjs win311
//
// env: GALLERY_URL (default the public gallery), INVITE (path or code),
//      OUT (default ~/e2e/demo), WARM=0 to skip the pre-wake pass,
//      SHOTS=1 to also drop a PNG at every beat (for tuning coordinates).
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from 'playwright';
import { openStation, probeVideo } from './station-open.mjs';

const STATION = process.argv[2] || 'win311';
const GALLERY = (process.env.GALLERY_URL || 'https://kernelhive.madekivi.fi').replace(/\/$/, '');
const OUT = process.env.OUT || `${process.env.HOME}/e2e/demo`;
const SHOTS = process.env.SHOTS === '1';
// The capture is an exact 2x of the finished GIF, so the downscale is a clean
// box filter rather than a resampling blur. It also has to stay SMALL enough
// that Chrome (software GL on CT950, plus the recorder) is not itself starved:
// the SPA's "Device under load" banner is CLIENT-measured
// (spa/src/ui/grid/StreamView/useDevicePressure.ts), so an oversized capture
// window makes the recording produce the very warning it then records.
const VIEW = {
  width: Number(process.env.VIEW_W || 1440),
  height: Number(process.env.VIEW_H || 810),
};

const log = (m) => console.log(`[demo] ${m}`);
fs.mkdirSync(OUT, { recursive: true });

function inviteCode() {
  const v = process.env.INVITE;
  if (!v) return null;
  // A path is the documented form; anything else is treated as the literal
  // code (an operator pasting from /admin). Never printed either way.
  try {
    if (fs.statSync(v).isFile()) return fs.readFileSync(v, 'utf8').trim();
  } catch {
    /* not a path — fall through to the literal */
  }
  return v.trim();
}

/** Redeem the invite into a Playwright storageState. Same route as
 *  scripts/visitor-sim/lib/invite.mjs: one same-origin POST, no passkey. */
async function signIn(browser, code, statePath) {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const origin = new URL(GALLERY).origin;
  try {
    const resp = await ctx.request.post(`${origin}/auth/invite/enter`, {
      data: { code },
      headers: { 'content-type': 'application/json', origin },
    });
    if (!resp.ok()) throw new Error(`invite redemption failed: HTTP ${resp.status()}`);
    await ctx.storageState({ path: statePath });
  } finally {
    await ctx.close();
  }
  return statePath;
}

/** Mark the station's boot video already-played BEFORE the /os/<id> route
 *  mounts. The overlay is a RECORDED clip with its own scrubber: a demo shot
 *  through it would be a video of a video, and every pointer move in this
 *  script would land on a replay rather than on the guest. Same key as
 *  scripts/visitor-sim/lib/stationOpen.mjs (App.tsx's BOOT_VIDEO_SESSION_PREFIX). */
async function suppressBootVideo(page, station) {
  const key = `kernelHive.bootVideoPlayed:${station}`;
  await page.addInitScript(([k]) => {
    try {
      window.sessionStorage.setItem(k, '1');
    } catch {
      /* storage blocked — the overlay just plays */
    }
  }, [key]);
  await page.evaluate((k) => {
    try {
      window.sessionStorage.setItem(k, '1');
    } catch {
      /* no-op */
    }
  }, key).catch(() => {});
}

// The beats. Pointer targets are in GUEST pixels — the coordinate system the
// guest itself draws in — and the runner maps them through the letterboxed
// picture, so a scene does not care how the stream is scaled into the page.
const SCENES = {
  // VIC-20 — the only scene here that touches nothing of the guest's own
  // chrome. Everything clicked is the SPA's: the ☰ stage menu, and the
  // "Type in a demo program" row that the museum's own type-in feature owns
  // (spa/src/ui/grid/StreamView/useDemoProgram.ts, listing from the registry).
  // That makes it the safest scene in the file — the museum types the listing
  // itself, at the pace the registry declares, so the capture never fires
  // keystrokes at a guest whose state it cannot see, and the visitor presses
  // RETURN to run it.
  //
  // NOT YET PROVEN END TO END. On 2026-09-09 the station was already running a
  // previous visitor's listing, so the type-in had nothing to land in and the
  // 'guest takes the listing' settle waited out its timeout against a screen
  // that never stops moving. Finish it on a VIC-20 sitting at READY (or add a
  // beat that gets it there) before trusting this scene for a recording.
  vic20: {
    // The grid opens with only one decade expanded, so a 1981 machine has no
    // card in the document at all until the collection is filtered. Typing the
    // filter is how a visitor finds one machine among 87, so the capture does
    // that rather than reaching past the UI to a deep link.
    filter: 'vic',
    beats: [
      { kind: 'settle', quietMs: 700, requireChange: false, note: 'let the READY screen rest' },
      { kind: 'ui', selector: 'button[aria-label="Controls"]', ms: 900, note: 'open the exhibit menu' },
      { kind: 'settle', quietMs: 400, requireChange: false, note: 'the panel opens' },
      { kind: 'ui', selector: 'button[aria-label="Type in a demo program"]', ms: 700, note: 'ask for the listing' },
      // The SPA now types the listing into the guest at the pace the registry
      // declares. Waiting for the picture to go quiet is waiting for the last
      // character to land — there is no other honest signal.
      { kind: 'settle', quietMs: 2000, timeoutMs: 60000, shot: 'typed', note: 'the guest takes the listing' },
      { kind: 'focus' },
      { kind: 'key', key: 'Enter' },
      { kind: 'settle', quietMs: 1500, timeoutMs: 30000, shot: 'running', note: 'RUN' },
    ],
  },
  // Windows 3.11, guest 1024x768. Program Manager's File menu is the clearest
  // "this is not a screenshot" beat the museum has: a dropdown unfolds, the
  // highlight follows the pointer, and File > Run... gives a text field to type
  // into. Nothing is launched — the dialog is cancelled — so the station is
  // left exactly as found (docs/lab/OPERATING-RULES.md rule 4: a visitor may
  // click, a capture may not leave state behind).
  win311: {
    focus: { gx: 512, gy: 742 },
    beats: [
      // NOTHING here waits on a guessed number of milliseconds. Every pause is
      // a 'settle': wait for the decoded frame to move, then for it to stop
      // moving. That is what makes the sequence safe on a live station — the
      // next click is only ever sent to a picture that has finished arriving.
      { kind: 'settle', quietMs: 700, requireChange: false, note: 'let the desktop rest' },
      { kind: 'move', gx: 54, gy: 58, ms: 900, note: 'to the File menu' },
      { kind: 'click' },
      { kind: 'settle', quietMs: 900, shot: 'file-menu', note: 'the menu unfolds' },
      { kind: 'move', gx: 90, gy: 182, ms: 900, note: 'down to Run...' },
      { kind: 'settle', quietMs: 500, requireChange: false, note: 'the highlight follows' },
      { kind: 'click' },
      { kind: 'settle', quietMs: 900, timeoutMs: 45000, shot: 'run-dialog', note: 'the Run dialog paints' },
      // WARM-UP that DID NOT WORK, kept because its failure is the evidence.
      // This station drops the opening of a keystroke burst (two to seven
      // characters, run to run); a burst of keys that type nothing should have
      // been eaten INSTEAD of the line, and was not. So the loss is not "the
      // first N events are discarded" and not a focus race either — it survived
      // a 45 s wait for the dialog to paint. See docs/lab/INPUT-DEBUGGING.md.
      { kind: 'warm', key: 'ArrowRight', presses: 6, paceMs: 150 },
      // Consequently the shipped GIF ends before this line: the field reads
      // "nel hive" and a README does not want a word with its head bitten off.
      // The beat stays so the next run can re-test the drop.
      { kind: 'type', text: 'the kernel hive', paceMs: 200 },
      { kind: 'settle', quietMs: 1200, shot: 'typed', note: 'the guest echoes it back' },
      // Cancel. Nothing is launched and nothing is saved, so the station is
      // left exactly as it was found.
      { kind: 'key', key: 'Escape' },
      { kind: 'settle', quietMs: 900, requireChange: false, note: 'back to the desktop' },
    ],
  },
};

/** Wait for the GUEST to react, and then stop reacting — never for a guessed
 *  number of milliseconds (AGENTS.md rule 14). This is not a nicety: on a busy
 *  box the guest ran EIGHT SECONDS behind the host, so a fixed dwell sent the
 *  next click into a menu that was still open, and Program Manager's File menu
 *  answered a click meant for "Run..." with "delete the group Gallery Games?".
 *  The dialog was cancelled and nothing was lost, but a capture that can do
 *  that to a live station is a capture that must not use sleeps.
 *
 *  The loop runs INSIDE the page — one round trip, not fifty — and fingerprints
 *  the decoded frame at 96x72. Returns how long it waited and whether the
 *  picture ever moved. */
async function settle(page, { quietMs = 900, timeoutMs = 20000, requireChange = true } = {}) {
  return page.evaluate(
    async ({ quietMs: quiet, timeoutMs: timeout, requireChange: needChange }) => {
      const v = [...document.querySelectorAll('video')].find((el) => el.srcObject && el.videoWidth > 0);
      if (!v) return { ok: false, why: 'no video' };
      const c = document.createElement('canvas');
      c.width = 96;
      c.height = 72;
      const ctx = c.getContext('2d', { willReadFrequently: true });
      const grab = () => {
        ctx.drawImage(v, 0, 0, c.width, c.height);
        return ctx.getImageData(0, 0, c.width, c.height).data;
      };
      // Count only pixels that moved a LOT. A mean-absolute difference never
      // reaches zero on a live H.264 stream — the codec dithers a static
      // desktop forever — so a mean-based test declares "still busy" for as
      // long as you are willing to wait, and every settle times out.
      const busy = (a, b) => {
        let n = 0;
        for (let i = 0; i < a.length; i += 4) if (Math.abs(a[i] - b[i]) > 30) n++;
        return n / (a.length / 4);
      };
      const t0 = Date.now();
      let prev = grab();
      let lastChange = needChange ? -1 : t0;
      let moved = !needChange;
      while (Date.now() - t0 < timeout) {
        await new Promise((r) => setTimeout(r, 120));
        const now = grab();
        if (busy(prev, now) > 0.002) {
          lastChange = Date.now();
          moved = true;
        }
        prev = now;
        if (moved && Date.now() - lastChange > quiet) {
          return { ok: true, moved, waitedMs: Date.now() - t0 };
        }
      }
      return { ok: false, why: 'timeout', moved, waitedMs: Date.now() - t0 };
    },
    { quietMs, timeoutMs, requireChange },
  );
}

/** Move the host pointer along a short arc so the guest sees a HUMAN path.
 *  A single jump teleports the cursor, which reads as a script in a GIF and
 *  tells a visitor nothing about whether the input plane is live. */
async function glide(page, from, to, ms) {
  // 60 ms per step, not 25: under a loaded box each CDP mouse.move costs far
  // more than its requested wait, so a fine-grained glide stretches a 900 ms
  // move into five seconds of footage.
  const steps = Math.max(5, Math.round(ms / 60));
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    // ease-in-out, so the pointer accelerates and settles like a hand does
    const e = t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t);
    await page.mouse.move(from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e);
    await page.waitForTimeout(ms / steps);
  }
}

async function main() {
  const code = inviteCode();
  const browser = await chromium.launch({
    headless: false,
    channel: 'chrome',
    args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
    env: { ...process.env, DISPLAY: ':1' },
  });

  let storageState;
  if (code) {
    storageState = await signIn(browser, code, path.join(OUT, 'session.json'));
    log('signed in with the invite (no passkey)');
  }

  // WARM PASS. The first visit to a stopped station is what wakes it, and a
  // cold wake is tens of seconds of black — true, but not what the README is
  // claiming. So a throwaway visit wakes it first and the recorded pass shows
  // what the SECOND visitor sees, which is the honest common case.
  if (process.env.WARM !== '0') {
    const warm = await browser.newContext({ ignoreHTTPSErrors: true, storageState, viewport: VIEW });
    const wp = await warm.newPage();
    await suppressBootVideo(wp, STATION);
    const r = await openStation(wp, GALLERY, STATION, { direct: true, waitMs: 120000, log });
    log(`warm pass: ${r.why}${r.video ? ` ${r.video.w}x${r.video.h}` : ''}`);
    await warm.close();
  }

  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
    storageState,
    viewport: VIEW,
    recordVideo: { dir: OUT, size: VIEW },
  });
  const page = await context.newPage();

  // Beat 1 is the collection itself — the GIF has to establish that this is a
  // gallery of many machines before it opens one.
  await page.goto(GALLERY, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await suppressBootVideo(page, STATION);
  await page.waitForSelector('a.os-card', { timeout: 30000 });
  await page.waitForTimeout(Number(process.env.GRID_DWELL_MS || 2000));

  if (SHOTS) await page.screenshot({ path: path.join(OUT, 'beat-grid.png') });

  const preScene = SCENES[STATION];
  let opened;
  if (preScene?.filter) {
    // Filter, then click the card that appears — and do NOT hand off to
    // openStation() afterwards: it re-navigates to the grid, which throws the
    // filter away and leaves the card unfindable again. The click and the
    // wait are the same two steps openStation does, minus that goto.
    const box = page.locator('input[placeholder^="Filter"]').first();
    await box.waitFor({ state: 'visible', timeout: 15000 });
    const bb = await box.boundingBox();
    const target = { x: bb.x + 60, y: bb.y + bb.height / 2 };
    await glide(page, { x: bb.x + bb.width * 0.8, y: bb.y - 60 }, target, 700);
    await page.mouse.click(target.x, target.y);
    for (const ch of preScene.filter) {
      await page.keyboard.press(ch);
      await page.waitForTimeout(220);
    }
    const card = page.locator(`a.os-card[href$="/os/${STATION}"]`).first();
    await card.waitFor({ state: 'visible', timeout: 15000 });
    await page.waitForTimeout(900);
    const cb = await card.boundingBox();
    await glide(page, target, { x: cb.x + cb.width / 2, y: cb.y + cb.height / 2 }, 900);
    await page.mouse.click(cb.x + cb.width / 2, cb.y + cb.height / 2);
    await page.waitForURL((u) => u.pathname.endsWith(`/os/${STATION}`), { timeout: 20000 });
    let video = null;
    for (let waited = 0; waited < 90000; waited += 1000) {
      await page.waitForTimeout(1000);
      video = await page.evaluate(probeVideo);
      if (video && video.readyState >= 2 && video.w > 0 && (video.nonBlackPct ?? 0) >= 5) break;
      video = null;
    }
    opened = { ok: Boolean(video), why: video ? 'live' : 'no live video within wait window', video };
  } else {
    opened = await openStation(page, GALLERY, STATION, { waitMs: 90000, minNonBlackPct: 5, log });
  }
  if (!opened.ok) throw new Error(`could not open ${STATION}: ${opened.why}`);
  log(`stream live ${opened.video.w}x${opened.video.h} nonBlack=${opened.video.nonBlackPct}%`);

  const vbox = await page.locator('video').first().boundingBox();
  if (!vbox) throw new Error('stream video has no bounding box');
  const gw = opened.video.w;
  const gh = opened.video.h;
  // The <video> element fills the whole viewport and the guest is LETTERBOXED
  // inside it (object-fit: contain), so the element's own box is NOT the
  // picture. Mapping guest pixels through vbox directly puts every click a
  // couple of hundred pixels off — compute the contained rect first.
  const fitScale = Math.min(vbox.width / gw, vbox.height / gh);
  const fit = {
    w: gw * fitScale,
    h: gh * fitScale,
    x: vbox.x + (vbox.width - gw * fitScale) / 2,
    y: vbox.y + (vbox.height - gh * fitScale) / 2,
  };
  log(`picture: ${Math.round(fit.w)}x${Math.round(fit.h)} at ${Math.round(fit.x)},${Math.round(fit.y)} in a ${Math.round(vbox.width)}x${Math.round(vbox.height)} element`);
  const toHost = (gx, gy) => ({ x: fit.x + gx * fitScale, y: fit.y + gy * fitScale });

  if (process.env.RECON === '1') {
    // Coordinate-tuning pass: land on the live desktop, photograph it, leave.
    await page.screenshot({ path: path.join(OUT, `recon-${STATION}.png`) });
    log(`recon shot: ${path.join(OUT, `recon-${STATION}.png`)} guest ${gw}x${gh} box ${Math.round(vbox.width)}x${Math.round(vbox.height)}`);
    await context.close();
    await browser.close();
    return;
  }
  const scene = SCENES[STATION];
  if (!scene) throw new Error(`no scene defined for ${STATION}`);
  // Click once into the stream first: that is what gives the station keyboard
  // focus, and it is also what a visitor does. The scene picks WHERE, because
  // the middle of a desktop is usually a window and a click there rearranges
  // the guest; every scene aims this at bare wallpaper.
  let cursor = scene.focus
    ? toHost(scene.focus.gx, scene.focus.gy)
    : { x: vbox.x + vbox.width / 2, y: vbox.y + vbox.height / 2 };
  await page.mouse.click(cursor.x, cursor.y);
  await page.waitForTimeout(700);

  const marks = [];
  const t0 = Date.now();
  for (const beat of scene.beats) {
    marks.push(`${((Date.now() - t0) / 1000).toFixed(1)}s ${beat.kind}${beat.note ? ` (${beat.note})` : ''}`);
    if (beat.kind === 'dwell') await page.waitForTimeout(beat.ms);
    else if (beat.kind === 'settle') {
      const r = await settle(page, {
        quietMs: beat.quietMs,
        timeoutMs: beat.timeoutMs,
        requireChange: beat.requireChange !== false,
      });
      log(`  settle${beat.note ? ` (${beat.note})` : ''}: ${r.ok ? 'quiet' : r.why} after ${r.waitedMs} ms`);
    }
    else if (beat.kind === 'move') {
      const to = toHost(beat.gx, beat.gy);
      await glide(page, cursor, to, beat.ms);
      cursor = to;
    } else if (beat.kind === 'click') await page.mouse.click(cursor.x, cursor.y);
    else if (beat.kind === 'ui') {
      // A control of the SPA's, not of the guest's: resolve it by its own
      // aria-label so the beat survives a restyle, glide to it, click it.
      const el = page.locator(beat.selector).first();
      await el.waitFor({ state: 'visible', timeout: 15000 });
      const b = await el.boundingBox();
      if (!b) throw new Error(`no box for ${beat.selector}`);
      const to = { x: b.x + b.width / 2, y: b.y + b.height / 2 };
      await glide(page, cursor, to, beat.ms ?? 700);
      cursor = to;
      await page.mouse.click(to.x, to.y);
    } else if (beat.kind === 'focus') {
      // Give the guest the keyboard back after a menu round trip. On a machine
      // with no pointer this click is inert in the guest, which is why the
      // scene that uses it is the one with no pointer.
      await page.mouse.click(fit.x + fit.w / 2, fit.y + fit.h / 2);
    } else if (beat.kind === 'warm') {
      for (let i = 0; i < beat.presses; i++) {
        await page.keyboard.press(beat.key);
        await page.waitForTimeout(beat.paceMs);
      }
    } else if (beat.kind === 'key') await page.keyboard.press(beat.key);
    else if (beat.kind === 'type') {
      for (const ch of beat.text) {
        await page.keyboard.press(ch === ' ' ? 'Space' : ch);
        await page.waitForTimeout(beat.paceMs);
      }
    }
    if (SHOTS && beat.shot) await page.screenshot({ path: path.join(OUT, `beat-${beat.shot}.png`) });
  }

  const video = page.video();
  await context.close(); // flushes the WebM
  const out = await video.path();
  await browser.close();
  log(`beats: ${marks.join(' | ')}`);
  log(`video: ${out}`);
}

await main();

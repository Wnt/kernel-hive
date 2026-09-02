// lib/journeys.mjs — the behaviours a simulated visitor can run. Each export
// takes (page, ctx) and returns { ok, detail, ...extras }. None of these throw
// on an ordinary failure (a station that never streams, a click that misses):
// they report `ok:false` with a reason, and the caller (visitor-sim.mjs) is
// what decides whether repeated failures should stop the run.
//
// WHY THESE FOUR AND WHY THEY DWELL. A real visitor reads, wanders, and types
// in bursts — a tight loop of identical actions is exactly the kind of data
// that would teach this lab the wrong things about its own telemetry (the
// brief's own words). So every journey below is built from human-paced
// dwells (lib/rng.mjs's humanDelay) around a small number of deliberate acts,
// never a fixed-interval hammer.

import { humanDelay } from './rng.mjs';
import { openStation, waitForVideo, typeHumanPace, traceFigureEight } from './stationOpen.mjs';
import { openEditor, keyboardSelect, randomClicks, pickFunnyLine } from './editorDemo.mjs';
import { armVirtualAuthenticator } from './webauthn.mjs';

const WALKIN_OS_IDS = ['win311', 'os2warp', 'rhapsody'];
const TYPING_LINES = [
  'hello from the gallery',
  'dir',
  'testing 1 2 3',
  'what a machine',
  'ping',
];

async function readALittle(page, rng, { minMs = 1500, maxMs = 6000 } = {}) {
  await humanDelay(rng, minMs, maxMs);
  // A scroll or two — most reading involves at least one.
  if (rng() < 0.7) {
    await page.mouse.wheel(0, 200 + rng() * 400);
    await humanDelay(rng, 400, 1500);
  }
  if (rng() < 0.25) {
    // A reversal — checking something above, exactly the kind of thing
    // docs/ANALYTICS.md §5.2 says a poster-read episode should see sometimes.
    await page.mouse.wheel(0, -(150 + rng() * 300));
    await humanDelay(rng, 300, 1200);
  }
}

/** /walkin/exhibits — no login needed. Browse cards, sometimes open one.
 *  `.walkin-exhibit` carries no per-card id/href in the rendered markup
 *  (WalkinExhibits.tsx keys it internally), so — like a real visitor
 *  wandering a wall of placards — this opens a random VISIBLE one rather
 *  than pretending it can target the operator's --stations pool by name; the
 *  `poster` journey below is the one that opens a specific pool station. */
export async function journeyExhibits(page, ctx) {
  const { galleryUrl, rng } = ctx;
  await page.goto(`${galleryUrl}/walkin/exhibits`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  try {
    await page.waitForSelector('.walkin-exhibit', { timeout: 20000 });
  } catch {
    return { ok: false, detail: 'exhibits grid never rendered a card' };
  }
  await humanDelay(rng, 1500, 4000);
  await page.mouse.wheel(0, 300 + rng() * 600);
  await humanDelay(rng, 800, 2200);

  const openers = page.locator('.walkin-placard-open');
  const count = await openers.count();
  let opened = false;
  if (count > 0 && rng() < 0.6) {
    await openers.nth(Math.floor(rng() * count)).click();
    opened = true;
  }
  if (opened) {
    try {
      await page.waitForSelector('.exhibit-poster', { timeout: 8000 });
      await readALittle(page, rng, { minMs: 2000, maxMs: 7000 });
      await page.locator('.exhibit-poster-close').click({ timeout: 5000 }).catch(() => {});
    } catch {
      /* the click may have landed on a card with no poster data yet — not
       * a tool fault, just a quieter visit. */
    }
  }
  await humanDelay(rng, 500, 2000);
  return { ok: true, detail: opened ? 'browsed exhibits, read a placard' : 'browsed exhibits' };
}

/** One station's poster, read at a plausible pace. Uses /walkin/exhibits as
 *  the door since it needs no login and covers the whole registry, not only
 *  the pool's walk-in-eligible ids. */
export async function journeyPoster(page, ctx) {
  const { galleryUrl, stations, rng } = ctx;
  const station = stations[Math.floor(rng() * stations.length)];
  await page.goto(`${galleryUrl}/walkin/exhibits`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  try {
    await page.waitForSelector('.walkin-exhibit', { timeout: 20000 });
  } catch {
    return { ok: false, detail: 'exhibits grid never rendered a card', station };
  }
  // The card carries no id/href — resolve id -> displayName from the same
  // public manifest the page itself renders from, then match on the name
  // text, so this journey actually reads a placard from --stations rather
  // than a random one.
  let displayName = null;
  try {
    displayName = await page.evaluate(async (id) => {
      const r = await fetch('/walkin/manifest.json', { credentials: 'same-origin' });
      if (!r.ok) return null;
      const rows = await r.json();
      // Wire shape per manifest.ts's parseWalkinManifest: either a bare array
      // or { entries: [...] } — never `exhibits`.
      const entry = (Array.isArray(rows) ? rows : (rows.entries ?? [])).find((e) => e.id === id);
      return entry ? entry.displayName : null;
    }, station);
  } catch {
    /* fall through — a card-count fallback below still reads something */
  }
  let target = displayName
    ? page.locator('.walkin-exhibit', { has: page.locator('.walkin-exhibit-name', { hasText: displayName }) })
    : null;
  if (!target || (await target.count()) === 0) target = null;
  const openers = (target ?? page.locator('.walkin-exhibit')).locator('.walkin-placard-open');
  const count = await openers.count();
  if (count === 0) return { ok: false, detail: `no placard found for ${station} (or the grid at all)`, station };
  await openers.nth(target ? 0 : Math.floor(rng() * count)).click();
  try {
    await page.waitForSelector('.exhibit-poster', { timeout: 8000 });
  } catch {
    return { ok: false, detail: 'placard click opened no poster', station };
  }
  await readALittle(page, rng, { minMs: 3000, maxMs: 12000 });
  await page.locator('.exhibit-poster-close').click({ timeout: 5000 }).catch(() => {});
  return { ok: true, detail: 'read a poster', station };
}

/** Sign up for a real walk-in passkey account (capped by ctx.safety), play a
 *  clone from the pool's walk-in-eligible ids, type at a human pace, leave —
 *  which releases the clone (WalkinPlay.tsx's unmount effect). */
export async function journeyWalkin(page, ctx) {
  const { galleryUrl, stations, rng, safety, manifest, visitorId, log } = ctx;
  const eligible = stations.filter((id) => WALKIN_OS_IDS.includes(id));
  if (eligible.length === 0) {
    return { ok: false, detail: `none of the pool (${stations.join(',')}) is walk-in-eligible (${WALKIN_OS_IDS.join(',')})` };
  }
  const os = eligible[Math.floor(rng() * eligible.length)];

  await armVirtualAuthenticator(page);
  await page.goto(`${galleryUrl}/walkin`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await humanDelay(rng, 1200, 3000);

  const willSignUp = safety.walkinGate.eligible();
  if (!willSignUp) {
    // Budget exhausted for this run — still a legitimate visit: read the
    // landing page and leave, rather than skip the journey silently.
    await readALittle(page, rng, { minMs: 1500, maxMs: 4000 });
    return { ok: true, detail: 'walk-in signup budget exhausted this run; read the landing page only' };
  }

  // The card grid has no per-card href in this markup; select by position via
  // the known WALKIN_OS_IDS order (fixture.ts declares the order the cards
  // render in), which is stable because the component maps WALKIN_OS_IDS
  // directly.
  const idx = WALKIN_OS_IDS.indexOf(os);
  const playButtons = page.locator('.walkin-card .walkin-btn');
  const btnCount = await playButtons.count();
  if (idx < 0 || idx >= btnCount) {
    return { ok: false, detail: `could not locate the "${os}" card (found ${btnCount} cards)` };
  }
  await playButtons.nth(idx).click();
  safety.walkinGate.record();

  let landed = false;
  try {
    await page.waitForURL((u) => u.pathname.startsWith(`/walkin/play/${os}`), { timeout: 20000 });
    landed = true;
  } catch {
    /* fall through — report what we know */
  }
  if (!landed) {
    return { ok: false, detail: `signup/play did not reach /walkin/play/${os} (still ${page.url()})`, station: os };
  }

  // Recover the handle the server minted, via the SAME call
  // passkey.ts's currentAccount() makes (GET /auth/state) — WalkinLanding.tsx's
  // own way of asking "who am I signed in as".
  let handle = null;
  try {
    handle = await page.evaluate(async () => {
      const r = await fetch('/auth/state', { credentials: 'same-origin', cache: 'no-store' });
      if (!r.ok) return null;
      const d = await r.json();
      return d && d.authenticated && d.user && d.user.name ? d.user.name : null;
    });
  } catch {
    /* best-effort — the account still exists even if this read failed */
  }
  if (handle) manifest?.walkinAccount({ handle, station: os, visitorId });
  log?.(`walk-in account ${handle ?? '(handle unknown)'} playing ${os}`);

  const videoResult = await waitForVideo(page, 25000);
  if (videoResult.ok) {
    await humanDelay(rng, 800, 2000);
    // Trace a figure-8 across the live stream: a continuous glide of real
    // pointer events into the station, which is both the thing worth watching
    // and a dense run of input.dispatch spans on the trace plane — far more
    // signal than the odd random poke. A couple of unhurried loops, then a
    // short type so the keyboard plane sees traffic too.
    await traceFigureEight(page, { loops: 2 + Math.floor(rng() * 2), periodMs: 3500 });
    await humanDelay(rng, 400, 1000);
    const line = TYPING_LINES[Math.floor(rng() * TYPING_LINES.length)];
    await typeHumanPace(page, line, { baseMs: 150, jitter: 70 });
    await page.keyboard.press('Enter').catch(() => {});
    await traceFigureEight(page, { loops: 1 + Math.floor(rng() * 2), periodMs: 3000 });
    await humanDelay(rng, 800, 2000);
  }

  // Leave via the UI control, which triggers releaseWalkin() on unmount —
  // a real visitor's "done" gesture, not just closing the tab.
  await page.getByRole('button', { name: 'Leave' }).click({ timeout: 5000 }).catch(() => {});
  await humanDelay(rng, 300, 900);

  return {
    ok: videoResult.ok,
    detail: videoResult.ok ? `played walk-in clone of ${os}` : `clone opened but ${videoResult.why}`,
    station: os,
    walkinHandle: handle,
  };
}

/** Restore a station to its golden snapshot through the REAL UI control, gated
 *  by ctx.safety.resetGate (--allow-resets / --reset-max / --reset-min-interval).
 *  Returns true iff a reset actually fired. Shared by journeyStation and
 *  journeyEditor so both produce the SAME station.restore telemetry.
 *
 *  DRIVEN THROUGH THE UI, NOT A BARE fetch(). The client-side station.restore /
 *  station.restore.toRestoredMs telemetry (the click-to-picture-back latency the
 *  operator wants to measure — useRestoreFlow.ts) fires ONLY from
 *  restoreToGolden(), wired to StageMenu.tsx's "Restore to golden snapshot"
 *  button. A raw POST /restore/<id> still resets the host but never runs that
 *  hook, so no span is produced. Open the ☰ menu, click the real button. */
async function restoreToGolden(page, station, { safety, manifest, log }) {
  if (!safety.resetGate.eligible(station)) return false;
  try {
    await page.getByRole('button', { name: 'Controls' }).click({ timeout: 5000 });
    const restoreBtn = page.getByRole('button', { name: /Restore to golden snapshot/ });
    await restoreBtn.waitFor({ state: 'visible', timeout: 5000 });
    const clickedAt = Date.now();
    await restoreBtn.click({ timeout: 5000 });
    safety.resetGate.record(station);
    manifest?.reset(station);
    log?.(`reset ${station}: clicked "Restore to golden snapshot"`);
    // The click starts a reconnect (connecting -> live); wait for the picture
    // to actually come back, which is what a real visitor watches for.
    const back = await waitForVideo(page, 45000);
    log?.(`reset ${station}: video back after restore = ${back.ok}`);
    // The DOM's video going live is NOT the moment useRestoreFlow.ts settles
    // (settle('ok'), which closes and buffers the span). Measured live, the
    // flow can still be mid-recover ~17s after the click, well after readyState
    // reported live pixels. Floor the dwell from the CLICK, not from
    // video-back, so the tab is not reused before the span finishes buffering.
    const minSettleMs = 20000;
    const elapsed = Date.now() - clickedAt;
    if (elapsed < minSettleMs) await page.waitForTimeout(minSettleMs - elapsed);
    return true;
  } catch (e) {
    log?.(`reset ${station} failed: ${e}`);
    return false;
  }
}

/** Open a live pool station from the full grid and interact — requires an
 *  invited (viewer/admin) session via --storage-state; the walk-in role
 *  cannot reach "/". Optionally fires a golden reset, gated by ctx.safety. */
export async function journeyStation(page, ctx) {
  const { galleryUrl, stations, rng, safety, manifest, log } = ctx;
  const station = stations[Math.floor(rng() * stations.length)];
  await page.goto(galleryUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await humanDelay(rng, 1000, 3000);
  const result = await openStation(page, station, { waitMs: 30000 });
  if (!result.ok) return { ok: false, detail: result.why, station };
  log?.(`opened ${station} live`);

  await humanDelay(rng, 1000, 2500);
  await traceFigureEight(page, { loops: 2 + Math.floor(rng() * 2), periodMs: 3500 });
  await humanDelay(rng, 400, 1000);
  if (rng() < 0.6) {
    const line = TYPING_LINES[Math.floor(rng() * TYPING_LINES.length)];
    await typeHumanPace(page, line, { baseMs: 140, jitter: 60 });
  }
  await humanDelay(rng, 1500, 5000);

  // Resets are gated by exactly three caps — --allow-resets, --reset-max and
  // --reset-min-interval — all enforced inside restoreToGolden via
  // safety.resetGate.eligible(). No extra coin-flip here: a 4th undocumented
  // `rng() < 0.15` used to make a reset "armed" but silently never fire, which
  // is indistinguishable from broken and defeats the operator's ask for
  // station.restore telemetry.
  const resetTriggered = await restoreToGolden(page, station, ctx);

  await humanDelay(rng, 500, 2000);
  return { ok: true, detail: `interacted with ${station}${resetTriggered ? ' (reset)' : ''}`, station, resetTriggered };
}

/** Credentialed editor demo (requires --storage-state or --invite, like
 *  journeyStation). Each visitor gets a DISTINCT station by visitorId, so a
 *  6-visitor run drives 6 different machines. Per station: reset to golden,
 *  open a text editor with the keyboard, type a funny line, select it with the
 *  keyboard, click a few random spots, and finish with a figure-8. Keys and
 *  clicks are what light up the input.dispatch.* trace plane (bare motion does
 *  not), so this is the journey that exercises the keyboard and click planes. */
export async function journeyEditor(page, ctx) {
  const { galleryUrl, stations, rng, visitorId, log } = ctx;
  // Distinct station per visitor (round-robins if visitors > stations).
  const station = stations[(visitorId - 1) % stations.length];
  await page.goto(galleryUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await humanDelay(rng, 800, 2000);
  const opened = await openStation(page, station, { waitMs: 30000 });
  if (!opened.ok) return { ok: false, detail: opened.why, station };
  log?.(`opened ${station} live`);

  // Start from a clean desktop, as asked — reset to golden first, then let the
  // picture settle before driving the Start menu.
  const resetTriggered = await restoreToGolden(page, station, ctx);
  await humanDelay(rng, 1000, 2000);

  // Open a text editor with the keyboard and type a funny line into it.
  const ed = await openEditor(page, station, { log: (m) => log?.(m) });
  if (!ed.ok) return { ok: false, detail: ed.why, station, resetTriggered };
  const line = pickFunnyLine(rng);
  await typeHumanPace(page, line, { baseMs: 150, jitter: 70 });
  await humanDelay(rng, 600, 1400);

  // Select the line with the keyboard, click a few random spots, then a figure-8.
  await keyboardSelect(page, rng);
  await humanDelay(rng, 400, 900);
  await randomClicks(page, rng, { n: 3 + Math.floor(rng() * 3) });
  await humanDelay(rng, 400, 900);
  await traceFigureEight(page, { loops: 2 + Math.floor(rng() * 2), periodMs: 3500 });
  await humanDelay(rng, 600, 1500);

  return {
    ok: true,
    detail: `editor demo on ${station}${resetTriggered ? ' (reset first)' : ''}: typed "${line}"`,
    station,
    resetTriggered,
  };
}

export const JOURNEYS = {
  exhibits: journeyExhibits,
  poster: journeyPoster,
  walkin: journeyWalkin,
  station: journeyStation,
  editor: journeyEditor,
};

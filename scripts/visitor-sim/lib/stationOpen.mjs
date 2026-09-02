// lib/stationOpen.mjs — open a station or a walk-in clone and wait for real
// stream pixels. Trimmed and adapted from scripts/e2e/station-open.mjs (the
// lab's one correct way for a Playwright probe to reach a station) for a tool
// that runs off-box, on the operator's Mac, against the PUBLIC origin rather
// than the LAN one — the resolution rules and the stream-probe shape are
// unchanged, only the transport target moves.
//
// WHY BY HREF, NOT TEXT. `page.getByText(/Windows 95/i)` matches a poster
// blurb or a nav item before it matches the card, so the click lands
// somewhere harmless and a healthy station gets filed as broken 30s later
// with no session ever opened on the daemon side. `OsCard` renders
// `<a class="os-card" href=".../os/<id>">`, which is the card's identity and
// cannot match prose.

/** Poll the stream <video>. The 2D StreamView feeds a <video> element from an
 *  OFFSCREEN canvas.captureStream() — there is no stream <canvas> in the
 *  document, so a canvas query finds nothing. */
export const probeVideo = () => {
  for (const v of document.querySelectorAll('video')) {
    if (!v.srcObject) continue;
    const rec = { w: v.videoWidth, h: v.videoHeight, readyState: v.readyState, paused: v.paused };
    if (rec.w > 0 && rec.h > 0 && v.readyState >= 2) {
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
      return rec;
    }
  }
  return null;
};

/**
 * Open an invited-role station from the grid by clicking its card.
 * @returns {Promise<{ok:boolean, why:string, video:object|null}>}
 */
export async function openStation(page, id, { waitMs = 30000 } = {}) {
  const target = `/os/${id}`;
  try {
    await page.waitForSelector('a.os-card', { timeout: 20000 });
  } catch {
    return { ok: false, why: 'grid never rendered a card', video: null };
  }
  let cards = page.locator(`a.os-card[href$="${target}"]`);
  let count = await cards.count();
  // GridView.tsx folds era sections shut by default (DEFAULT_OPEN_ERAS =
  // 1990s/2000s only) and does not render a folded section's cards into the
  // DOM at all (`{open && g.items.map(...)}`) — so a station from any other
  // decade (amiga 1987, zxspectrum 1982, both 1980s) is invisible to a plain
  // href query until its era is expanded. A real visitor would either type a
  // filter query (which GridView overrides the fold for) or click the era
  // header open; this does the equivalent of the click, since the filter's
  // match rules (stationSearch.ts) are not guaranteed to match a bare id.
  if (count === 0) {
    const closedEras = page.locator('button.era-toggle[aria-expanded="false"]');
    const closedCount = await closedEras.count();
    for (let i = 0; i < closedCount; i++) {
      // Always index 0: each click removes an `aria-expanded="false"` match.
      await closedEras.first().click({ timeout: 5000 }).catch(() => {});
    }
    if (closedCount > 0) {
      cards = page.locator(`a.os-card[href$="${target}"]`);
      count = await cards.count();
    }
  }
  if (count !== 1) {
    const why =
      count === 0
        ? `expected exactly 1 card for ${target}, found 0 even after expanding every era section — ` +
          `not a fold/virtualisation issue, the grid genuinely has no card for this id`
        : `expected exactly 1 card for ${target}, found ${count}`;
    return { ok: false, why, video: null };
  }
  const card = cards.first();
  await card.scrollIntoViewIfNeeded();
  const box = await card.boundingBox();
  if (!box) return { ok: false, why: 'card has no bounding box', video: null };
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  try {
    await page.waitForURL((u) => u.pathname.endsWith(target), { timeout: 15000 });
  } catch {
    return { ok: false, why: `click did not navigate to ${target} (still ${page.url()})`, video: null };
  }
  return waitForVideo(page, waitMs);
}

/** Wait for the stream to go live wherever the page already is (a walk-in
 *  clone's /walkin/play/<os> included — it is the same StreamView). */
export async function waitForVideo(page, waitMs = 30000) {
  let video = null;
  for (let waited = 0; waited < waitMs; waited += 1000) {
    await page.waitForTimeout(1000);
    video = await page.evaluate(probeVideo).catch(() => null);
    if (video && video.readyState >= 2 && video.w > 0) break;
    video = null;
  }
  if (!video) return { ok: false, why: 'no live video within wait window', video: null };
  return { ok: true, why: 'live', video };
}

/** Type one line at a human-ish pace, with per-character jitter — mirrors
 *  scripts/e2e/typing-pace-probe.mjs's reasoning: a human types with
 *  overlapping key edges at roughly 5-8 chars/s, not a clean scripted burst. */
export async function typeHumanPace(page, text, { baseMs = 140, jitter = 60 } = {}) {
  for (const ch of text) {
    await page.keyboard.type(ch, { delay: 0 });
    await page.waitForTimeout(Math.max(20, baseMs + Math.round((Math.random() - 0.5) * 2 * jitter)));
  }
}


/** The points of a figure-8 (a Gerono lemniscate) centred in a box.
 *  x = cx + ax·cos(t), y = cy + ay·sin(t)·cos(t), t over `loops` full turns —
 *  a horizontal ∞ that crosses its own centre once per loop. Pure and
 *  deterministic (given `phase`) so the geometry is unit-tested without a
 *  browser; the mouse driving is traceFigureEight below. `samples` is points
 *  PER loop — more is a smoother glide and a denser stream of pointer events,
 *  which is the signal this motion exists to produce. */
export function figureEightPoints({ cx, cy, ax, ay, loops = 2, samples = 96, phase = 0 }) {
  const pts = [];
  const total = Math.max(1, Math.round(loops * samples));
  for (let i = 0; i <= total; i++) {
    const t = phase + (i / samples) * 2 * Math.PI;
    pts.push({ x: cx + ax * Math.cos(t), y: cy + ay * Math.sin(t) * Math.cos(t) });
  }
  return pts;
}

/** Trace a figure-8 with the real pointer across a station's video, so the
 *  daemon sees a continuous stream of genuine mouse-move events (and the trace
 *  plane, a run of input.dispatch spans) rather than the odd random poke.
 *  Amplitude is a fraction of the video box so it stays well inside the frame;
 *  `periodMs` is the time for one full loop, split evenly across its samples. */
export async function traceFigureEight(page, { loops = 2, periodMs = 3500, samples = 96, amp = 0.38 } = {}) {
  const video = page.locator('video').first();
  const box = await video.boundingBox().catch(() => null);
  if (!box) return { ok: false, why: 'no video box to trace over' };
  const pts = figureEightPoints({
    cx: box.x + box.width / 2,
    cy: box.y + box.height / 2,
    ax: box.width * amp,
    ay: box.height * amp,
    loops,
    samples,
  });
  const stepMs = periodMs / samples;
  // Prime the pointer at the first point, then glide — one move per sample, no
  // Playwright-interpolated sub-steps, because the samples ARE the smoothness
  // and each move is one pointer event we want the station to receive.
  await page.mouse.move(pts[0].x, pts[0].y);
  for (let i = 1; i < pts.length; i++) {
    await page.mouse.move(pts[i].x, pts[i].y);
    await page.waitForTimeout(stepMs);
  }
  return { ok: true, why: 'traced', points: pts.length };
}

// The sessionStorage key the SPA uses to remember it already played a station's
// boot-video overlay (App.tsx's BOOT_VIDEO_SESSION_PREFIX + osId). Kept in
// lockstep with that constant — bootVideoPlayedFor() returns true when this key
// is '1', so pre-seeding it before the station mounts suppresses the overlay.
export function bootVideoPlayedKey(osId) {
  return `kernelHive.bootVideoPlayed:${osId}`;
}

/** Skip the boot-video overlay for `station`: mark it already-played in
 *  sessionStorage BEFORE the /os/<id> route mounts, so App.tsx passes
 *  playBootVideo={false} and BootVideoOverlay never mounts — the demo lands
 *  straight on the live desktop instead of interacting behind a boot clip. The
 *  gallery is a client-routed SPA (clicking a card does not reload the
 *  document), so setting this on the grid page persists into the station route;
 *  an addInitScript also re-applies it across any hard reload. Call AFTER
 *  page.goto(gallery) and BEFORE openStation(). Best-effort: a station with no
 *  bootVideo is unaffected, and storage being blocked is harmless. */
export async function suppressBootVideo(page, station) {
  const key = bootVideoPlayedKey(station);
  await page.addInitScript(
    ([k]) => {
      try {
        window.sessionStorage.setItem(k, '1');
      } catch {
        /* storage blocked — the live grid still works, boot just plays */
      }
    },
    [key],
  );
  await page.evaluate((k) => {
    try {
      window.sessionStorage.setItem(k, '1');
    } catch {
      /* no-op */
    }
  }, key).catch(() => {});
}

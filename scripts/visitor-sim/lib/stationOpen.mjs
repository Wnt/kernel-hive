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

/** A few plausible clicks/moves inside a station's video area — a visitor
 *  poking at a desktop, not a bot hammering one pixel. */
export async function wanderPointer(page, times = 3) {
  const video = page.locator('video').first();
  const box = await video.boundingBox().catch(() => null);
  if (!box) return;
  for (let i = 0; i < times; i++) {
    const x = box.x + box.width * (0.2 + 0.6 * Math.random());
    const y = box.y + box.height * (0.2 + 0.6 * Math.random());
    await page.mouse.move(x, y, { steps: 8 + Math.floor(Math.random() * 8) });
    await page.waitForTimeout(200 + Math.random() * 500);
    if (Math.random() < 0.5) await page.mouse.click(x, y);
    await page.waitForTimeout(300 + Math.random() * 900);
  }
}

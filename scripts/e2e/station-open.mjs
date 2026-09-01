// station-open.mjs — the ONE correct way for an e2e probe to reach a station.
//
// WHY THIS FILE EXISTS. Probes used to find their tile with
// `page.getByText(/Windows 95/i).first()`. That is a text search over the whole
// document, and on the live grid it matches a poster blurb, a release-note
// line or a nav item long before it matches the card — so the click lands
// somewhere harmless, the probe waits 30s and prints "no live video", and the
// reader files that as a STATION fault. It is not: the daemon journal shows no
// session was ever created. A probe that can fail without opening the station
// cannot produce evidence about the station.
//
// So resolution is by HREF, which is the card's identity: `OsCard` renders an
// `<a class="os-card">` whose target is `cardTarget(id, walkin)` = `/os/<id>`
// for an invited visitor. `href$="/os/<id>"` is exact, survives a staged
// bundle's BASE_URL prefix, and cannot match prose. We then ASSERT the SPA
// actually navigated, so a swallowed click fails here instead of masquerading
// as a stream fault 30 seconds later.
//
// Two ways in, and both are legitimate:
//   openStation(page, base, id)                — the visitor path: grid, click.
//   openStation(page, base, id, {direct:true}) — deep link straight to /os/<id>,
//                                                which is what station-accept-probe
//                                                does. Use when the grid is not
//                                                what is under test.
import fs from 'node:fs';

/** Poll the stream <video>. There is NO stream <canvas> in the document — the
 *  2D StreamView feeds a <video> from an OFFSCREEN canvas.captureStream(), so
 *  `document.querySelectorAll('canvas')` finds nothing. Pixel checks must
 *  drawImage() the video onto a temp canvas first. */
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

/** Where screenshots go. Timestamped names only — a fixed name left a
 *  root-owned file behind that crashed the next run with EACCES. */
export function shotDir() {
  const out = `${process.env.HOME}/e2e/shots`;
  fs.mkdirSync(out, { recursive: true });
  return out;
}

export function galleryUrl() {
  // The INTERNAL address. The public gallery host does not answer on 8443 from
  // inside CT950. Never hardcode the real value (rule 1) — the caller exports
  // GALLERY_URL from the gitignored registry/local.env.
  return (process.env.GALLERY_URL || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`).replace(/\/$/, '');
}

/**
 * Open a station and wait for its stream to be live.
 * @returns {Promise<{ok:boolean, why:string, video:object|null, cardCount:number, url:string}>}
 */
export async function openStation(page, base, id, opts = {}) {
  const { direct = false, waitMs = 45000, minNonBlackPct = 0, log = () => {} } = opts;
  const target = `/os/${id}`;

  if (direct) {
    await page.goto(`${base}${target}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  } else {
    await page.goto(base, { waitUntil: 'domcontentloaded', timeout: 30000 });
    // The grid renders asynchronously; "Loading the collection…" is a real
    // stuck state, so wait for a card rather than a fixed sleep.
    try {
      await page.waitForSelector('a.os-card', { timeout: 30000 });
    } catch {
      return { ok: false, why: 'grid never rendered a card', video: null, cardCount: 0, url: page.url() };
    }
    const cards = page.locator(`a.os-card[href$="${target}"]`);
    const cardCount = await cards.count();
    if (cardCount !== 1) {
      return {
        ok: false,
        why: `expected exactly 1 card for ${target}, found ${cardCount}`,
        video: null,
        cardCount,
        url: page.url(),
      };
    }
    const card = cards.first();
    await card.scrollIntoViewIfNeeded();
    // Click through the bounding box: the inner <span>s intercept a
    // locator.click() on some cards.
    const box = await card.boundingBox();
    if (!box) {
      return { ok: false, why: 'card has no bounding box', video: null, cardCount, url: page.url() };
    }
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    // ASSERT the navigation. Without this a swallowed click is indistinguishable
    // from a dead stream 30 seconds later.
    try {
      await page.waitForURL((u) => u.pathname.endsWith(target), { timeout: 15000 });
    } catch {
      return {
        ok: false,
        why: `click did not navigate to ${target} (still ${page.url()})`,
        video: null,
        cardCount,
        url: page.url(),
      };
    }
    log(`opened ${target} via card click`);
  }

  let video = null;
  for (let waited = 0; waited < waitMs; waited += 1000) {
    await page.waitForTimeout(1000);
    video = await page.evaluate(probeVideo);
    if (video && video.readyState >= 2 && video.w > 0 && (video.nonBlackPct ?? 0) >= minNonBlackPct) break;
    video = null;
  }
  if (!video) {
    return { ok: false, why: 'no live video within wait window', video: null, cardCount: 1, url: page.url() };
  }
  return { ok: true, why: 'live', video, cardCount: 1, url: page.url() };
}

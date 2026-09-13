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
 * Redeem an invite into a Playwright storageState, so a probe can carry an
 * `admin`/`viewer` session instead of `anon`. Same route as
 * scripts/visitor-sim/lib/invite.mjs and readme-demo-capture.mjs's signIn().
 *
 * WHY THIS EXISTS (landed 2026-09-13, docs/lab/OPERATING-RULES.md rule 11 —
 * fix a broken lab tool in the same session that found it broken). Since
 * `os route: an exhibit nobody (or not this role) can drive shows its notes`
 * (5bcfc039, 2026-09-10), `grid/exhibitAccess.ts`'s `exhibitViewFor` renders
 * `/os/:osId` as the ExhibitPoster ("notes") for ANY role that is not
 * `admin`/`viewer` — and every station has a poster (measured 0/96 missing),
 * so an unauthenticated browser gets notes, never the stream, full stop. A
 * probe launched with no session therefore cannot reach live video no matter
 * how healthy the station is: `open-check.mjs` used to read this as "no live
 * video within wait window" after the full 45s poll, which is what the
 * previous verifier's crash report actually was — the timeout raced a
 * separate, session-independent problem (Chrome dying on the shared `:1`
 * desktop) that made the SAME missing-auth failure look like two different
 * bugs across runs.
 *
 * THE ARCHITECTURAL WALL. `scripts/serve/static_files.py`'s own comment says
 * it plainly: "on the ungated LAN listener auth_routes.dispatch never runs,
 * so /auth/state and every /walkin/* path fall through to the SPA fallback".
 * `GALLERY_URL=https://<lab>:8443` (docs/PUBLIC-GALLERY.md: `127.0.0.1:8443`,
 * "the LAN listener (unchanged, open)") therefore has NO auth plane to sign
 * into at all — `/auth/invite/enter` 404s there. The gated listener
 * (`127.0.0.1:8081` on labhost) is loopback-only and unreachable from CT950.
 * The one gated origin CT950 CAN reach is the public gallery
 * (`https://kernelhive.madekivi.fi`, the one committable domain — rule 1),
 * which is exactly the origin readme-demo-capture.mjs already signs into.
 *
 * So: a probe that must SEE the stream (not just prove the click navigates)
 * needs BOTH an INVITE code (path to one, e.g. the box's mode-600
 * `pki/sim-invite.code`, or read from `SIM_INVITE_PATH` — see
 * `docs/PUBLIC-GALLERY.md`) AND `GALLERY_URL` pointed at the public origin,
 * not the bare LAN one. `open-check.mjs INVITE=<path> node open-check.mjs …`
 * does this automatically when GALLERY_URL is left at its public default.
 */
export async function signIn(browser, code, statePath) {
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const origin = new URL(galleryUrl()).origin;
  try {
    // Every state-changing auth route requires `Origin: <gallery origin>`
    // (scripts/serve/auth/routes.py's own header: "that SameSite alone is
    // not the whole answer") — omit it and redemption 403s as "not valid",
    // which reads exactly like a bad/expired code and is not one.
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

/** Resolve an INVITE env var (a path to the code, or the literal code) the
 *  same way readme-demo-capture.mjs does — never printed either way. */
export function inviteCode() {
  const v = process.env.INVITE;
  if (!v) return null;
  try {
    if (fs.statSync(v).isFile()) return fs.readFileSync(v, 'utf8').trim();
  } catch {
    /* not a path — fall through to the literal */
  }
  return v.trim();
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
    let cards = page.locator(`a.os-card[href$="${target}"]`);
    let cardCount = await cards.count();
    // GRID FOLDING. GridView.tsx: "Era sections FOLD. Only the two decades
    // the collection is thickest in open [by default]" — a card in a
    // collapsed decade is not in the DOM at all, so a station outside the
    // default-open eras reads as "0 cards" and that is not a station fault
    // (macsys1, reported as "0 cards" against a stale registry read, is
    // really this: its era is folded shut on a fresh load). "A filter run
    // OVERRIDES the fold entirely while it is active" — so typing the id
    // into `.grid-filter-input` forces every matching era open, same as a
    // visitor would by searching for the machine they want.
    if (cardCount === 0) {
      const filterBox = page.locator('.grid-filter-input');
      if (await filterBox.count()) {
        await filterBox.fill(id);
        await page.waitForTimeout(300); // filter re-render, no fixed-length wait on anything else
        cards = page.locator(`a.os-card[href$="${target}"]`);
        cardCount = await cards.count();
        log(`0 cards before filtering; ${cardCount} after typing "${id}" into the filter (era was likely folded)`);
      }
    }
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

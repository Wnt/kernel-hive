// ============================================================================
//  firefoxSmoke.spec.ts — per-tile Firefox decode smoke (config: firefoxSmoke.config.ts)
//  ---------------------------------------------------------------------------
//  For each tile: open the DEPLOYED SPA, click the tile card, and assert the
//  LIVE stream surface is painting real non-black pixels. The live surface
//  differs per engine (StreamView.tsx `directCanvas`, since 2026-07-13):
//    * Firefox  — streamhost tiles render via a DIRECT-PAINT <canvas
//      class="sv-video"> (decoded VideoFrames drawn straight to glass; there is
//      NO live <video> element at all). The probe samples that canvas.
//    * Chromium — the live element is the srcObject-fed <video> (captureStream).
//  Boot-video tiles (win95, solaris, …) additionally mount the recorded boot
//  CLIP as a second <video> with a plain `src` URL — it decodes fine even when
//  the live plane is dead, so the probe must NEVER fall back to "any video":
//  it accepts ONLY the direct-paint canvas or a srcObject-fed video.
//  Also assert the explicit decoder-failure chip ("decoder failing",
//  bannerState from the avc-path client) is ABSENT. Page console errors are
//  attached always; a screenshot is attached on failure (config).
//
//  Non-black gate per tile: >50% default, but text-mode DOS screens are
//  legitimately ~99% black — a known-good Chrome decode of FreeDOS measures
//  nonBlackPct=1 (tile-diag.mjs, 2026-07-12) — so FreeDOS gates at >=1%.
// ============================================================================
import { test, expect, type Page } from '@playwright/test';

interface TileSpec {
  /** Display-name match — card text (aria-label starts with displayName). */
  name: string;
  /** Minimum % of sampled pixels that must be non-black once live. */
  minNonBlackPct: number;
}

const TILES: TileSpec[] = [
  { name: 'FreeDOS', minNonBlackPct: 1 }, // text-mode: mostly black is correct
  { name: 'Windows 95', minNonBlackPct: 50 },
  { name: 'Solaris', minNonBlackPct: 50 }, // card displayName "Solaris CDE"
];

interface SurfaceProbe {
  found: boolean;
  kind?: 'canvas' | 'video';
  readyState?: number; // <video> only
  w?: number;
  h?: number;
  paused?: boolean;    // <video> only
  nonBlackPct?: number;
  live?: boolean;      // surface is decodable + painting (pre-non-black gate)
  err?: string;
}

/** One-shot probe of the LIVE stream surface: the Firefox direct-paint
 *  <canvas class="sv-video">, else the srcObject-fed <video>. Deliberately NO
 *  "any video" fallback — the boot-video clip <video> (plain src URL) would
 *  false-pass while the live plane is dead. */
function probeLiveSurface(page: Page): Promise<SurfaceProbe> {
  return page.evaluate(() => {
    const sample = (rec: any, src: CanvasImageSource, w: number, h: number) => {
      try {
        const c = document.createElement('canvas');
        c.width = w; c.height = h;
        const ctx = c.getContext('2d')!;
        ctx.drawImage(src, 0, 0);
        const d = ctx.getImageData(0, 0, w, h).data;
        let nb = 0, n = 0;
        for (let i = 0; i < d.length; i += 400) { n++; if (d[i] + d[i + 1] + d[i + 2] > 30) nb++; }
        rec.nonBlackPct = Math.round((100 * nb) / Math.max(1, n));
      } catch (e) { rec.err = String(e).slice(0, 120); }
    };
    // Firefox streamhost: direct-paint canvas (resized to the guest dims on the
    // first decoded frame; painting real pixels is the liveness signal).
    const canvas = document.querySelector('canvas.sv-video') as HTMLCanvasElement | null;
    if (canvas) {
      const rec: any = {
        found: true, kind: 'canvas', w: canvas.width, h: canvas.height,
        nonBlackPct: 0, live: canvas.width > 0 && canvas.height > 0,
      };
      if (rec.live) sample(rec, canvas, canvas.width, canvas.height);
      return rec;
    }
    // Chromium (and neko/RDP): the srcObject-fed live <video> ONLY.
    const vids = [...document.querySelectorAll('video')] as HTMLVideoElement[];
    const v = vids.find((x) => x.srcObject);
    if (!v) return { found: false } as const;
    const rec: any = {
      found: true, kind: 'video', readyState: v.readyState, w: v.videoWidth,
      h: v.videoHeight, paused: v.paused, nonBlackPct: 0,
      live: v.videoWidth > 0 && v.readyState >= 2,
    };
    if (rec.live) sample(rec, v, rec.w, rec.h);
    return rec;
  });
}

/** Click the tile card: current bundles render <a class="os-card"> (react-
 *  router Link; older ones used <button class="os-card">) — select by class
 *  only; fall back to a text match + bounding-box click (the proven tile-diag
 *  approach) for bundles without the class. */
async function openTile(page: Page, name: string): Promise<void> {
  await page.goto('/', { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.waitForTimeout(3000); // manifest fetch + grid render
  const re = new RegExp(name, 'i');
  let card = page.locator('.os-card').filter({ hasText: re }).first();
  if ((await card.count()) === 0) card = page.getByText(re).first();
  await card.scrollIntoViewIfNeeded();
  const box = await card.boundingBox();
  expect(box, `card for "${name}" should be visible on the grid`).toBeTruthy();
  await page.mouse.click(box!.x + box!.width / 2, box!.y + box!.height / 2);
}

for (const tile of TILES) {
  test(`FF smoke · ${tile.name} — live surface painting, no decoder-failing chip`, async ({ page }, testInfo) => {
    const consoleLines: string[] = [];
    page.on('console', (m) => {
      if (m.type() === 'error' || m.type() === 'warning') {
        consoleLines.push(`[console.${m.type()}] ${m.text().slice(0, 400)}`);
      }
    });
    page.on('pageerror', (e) => consoleLines.push(`[pageerror] ${String(e).slice(0, 400)}`));

    let probe: SurfaceProbe = { found: false };
    try {
      await openTile(page, tile.name);

      // Poll until the live surface paints + enough non-black pixels
      // (connect + first keyframe). Firefox: the direct-paint canvas;
      // Chromium: the srcObject <video>.
      await expect
        .poll(async () => {
          probe = await probeLiveSurface(page);
          return !!(probe.found && probe.live
            && (probe.nonBlackPct ?? 0) >= tile.minNonBlackPct);
        }, {
          message: `live stream surface should paint for ${tile.name} `
            + `(direct-paint canvas OR srcObject video; nonBlack>=${tile.minNonBlackPct}%) — `
            + `see the "probe" attachment for the last measured state`,
          timeout: 60_000,
          intervals: [1000],
        })
        .toBe(true);

      // The explicit decoder-failure chip must NOT be shown (new bannerState
      // 'decoder-failed' renders "No video · decoder failing: <msg>").
      await expect(page.getByText(/decoder failing/i)).toHaveCount(0);

      testInfo.annotations.push({
        type: 'decode',
        description: `${probe.kind} ${probe.w}x${probe.h}`
          + `${probe.kind === 'video' ? ` readyState=${probe.readyState}` : ''}`
          + ` nonBlack=${probe.nonBlackPct}%`,
      });
    } finally {
      // Always attach the evidence: banner chip (the stall/decoder discriminator)
      // + page console. Screenshot-on-failure comes from the config.
      const banner = await page.evaluate(() => {
        const m = document.body.innerText.match(/No video[^\n]*/);
        return m ? m[0] : '(no banner)';
      }).catch(() => '(page gone)');
      await testInfo.attach('probe', {
        body: JSON.stringify({ tile: tile.name, banner, probe }, null, 2),
        contentType: 'application/json',
      });
      if (consoleLines.length) {
        await testInfo.attach('page-console', {
          body: consoleLines.join('\n'), contentType: 'text/plain',
        });
      }
    }
  });
}

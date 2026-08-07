// ============================================================================
//  bootVideo.spec.ts — boot-video replay smoke (config: bootVideo.config.ts)
//  ---------------------------------------------------------------------------
//  Covers the boot-video replay feature (StreamView BootVideoOverlay, live since
//  2026-07-13: record the power-on once, replay it scrubbable while the live
//  golden connects behind it, then hand off seamlessly). For ONE bootVideo tile
//  (win95 — the "true seamless" reference clip) against the DEPLOYED SPA:
//
//    1. OVERLAY  — clicking the card mounts the boot overlay: the clip <video>
//                  (plain `src` URL under /boot/) + the scrub slider
//                  (aria-label "Scrub boot video") + the Skip control.
//    2. PLAYS    — the clip's currentTime actually advances (autoplay; unmuted
//                  by default with a muted fallback, either is a pass here).
//    3. ALIGNS   — boot clip + live surface occupy the exact same stage box, and
//                  no OS-name / Ready placard competes in the overlay layout.
//    4. SCRUBS   — a real mouse press on the scrub slider seeks the clip to the
//                  clicked fraction (transport controls opt back into pointer
//                  events through the overlay's pointerEvents:none root).
//    5. HANDOFF  — "Skip ⏭" ends the clip; the overlay pins the last frame,
//                  waits for real live content (or its 4 s fallback), fades, and
//                  UNMOUNTS — after which the LIVE surface must be painting:
//                  Chromium: the srcObject-fed <video>; Firefox: the direct-
//                  paint <canvas class="sv-video"> (no live <video> exists).
//                  The clip <video> (src URL) must be GONE from the DOM.
//
//  Runs anywhere with a route to the box (no QMP, no reset — browser-side only).
// ============================================================================
import { test, expect, type Page } from '@playwright/test';

const TILE = { osId: 'win95', displayName: 'Windows 95', minNonBlackPct: 50 };

// Same decode-side shim the streamhostInput harness uses: StreamClient configures
// WebCodecs with hardwareAcceleration:'prefer-hardware' (right for real users);
// on a GPU-less runner that closes the decoder. Coerce that ONE field so the
// unmodified deployed bundle decodes headless. No-op where hardware decode works.
function decoderShim(): void {
  const proto = (globalThis as unknown as { VideoDecoder?: { prototype: { configure: (c: unknown) => unknown } } }).VideoDecoder;
  if (!proto) return;
  const orig = proto.prototype.configure;
  proto.prototype.configure = function (c: unknown) {
    let cfg = c as Record<string, unknown> | null;
    if (cfg && cfg.hardwareAcceleration === 'prefer-hardware') {
      cfg = { ...cfg, hardwareAcceleration: 'no-preference' };
    }
    return orig.call(this, cfg);
  };
}

const CLIP = 'video[src*="/boot/"]';
const SCRUB = 'input[aria-label="Scrub boot video"]';

/** Live-surface probe (mirrors firefoxSmoke): Firefox direct-paint canvas OR the
 *  srcObject-fed <video>; never the boot clip (plain src URL). */
function probeLive(page: Page) {
  return page.evaluate(() => {
    const sample = (src: CanvasImageSource, w: number, h: number): number => {
      try {
        const c = document.createElement('canvas');
        c.width = w; c.height = h;
        const ctx = c.getContext('2d')!;
        ctx.drawImage(src, 0, 0);
        const d = ctx.getImageData(0, 0, w, h).data;
        let nb = 0, n = 0;
        for (let i = 0; i < d.length; i += 400) { n++; if (d[i] + d[i + 1] + d[i + 2] > 30) nb++; }
        return Math.round((100 * nb) / Math.max(1, n));
      } catch { return -1; }
    };
    const canvas = document.querySelector('canvas.sv-video') as HTMLCanvasElement | null;
    if (canvas && canvas.width > 0) {
      return { kind: 'canvas', w: canvas.width, h: canvas.height, nonBlackPct: sample(canvas, canvas.width, canvas.height) };
    }
    const v = ([...document.querySelectorAll('video')] as HTMLVideoElement[]).find((x) => x.srcObject);
    if (v && v.videoWidth > 0 && v.readyState >= 2) {
      return { kind: 'video', w: v.videoWidth, h: v.videoHeight, nonBlackPct: sample(v, v.videoWidth, v.videoHeight) };
    }
    return { kind: 'none', w: 0, h: 0, nonBlackPct: 0 };
  });
}

/** Rendered boxes for the overlapping boot + live surfaces. Equal boxes are the
 *  layout half of the seam invariant; the capture pipeline owns equal pixels. */
function probeSeamGeometry(page: Page) {
  return page.evaluate(() => {
    const clip = document.querySelector('video[src*="/boot/"]') as HTMLVideoElement | null;
    const canvas = document.querySelector('canvas.sv-video') as HTMLCanvasElement | null;
    const liveVideo = ([...document.querySelectorAll('video')] as HTMLVideoElement[]).find((v) => v.srcObject);
    const live = canvas ?? liveVideo ?? null;
    const box = (el: Element | null) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.x, y: r.y, width: r.width, height: r.height };
    };
    return { clip: box(clip), live: box(live) };
  });
}

test(`BOOT-VIDEO · ${TILE.displayName} — overlay plays, scrubs, hands off to live`, async ({ page, context }, testInfo) => {
  await context.addInitScript(decoderShim);

  // 1. Genuine user path: land on the grid, click the tile's card. (The card is
  //    a react-router <a class="os-card"> in current bundles, a <button> in older
  //    ones — select by class only.)
  await page.goto(`/?streamhost=${TILE.osId}`, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.waitForSelector('.os-card', { timeout: 30_000 });
  const card = page.locator(`.os-card[aria-label^="${TILE.displayName},"]`);
  await expect(card, `a grid card for "${TILE.displayName}" must exist`).toHaveCount(1);
  await card.scrollIntoViewIfNeeded();
  await card.click();

  // 2. OVERLAY: boot clip video (src URL) + scrub slider mount.
  const clip = page.locator(CLIP);
  await expect(clip, 'boot clip <video src="/boot/…"> should mount').toHaveCount(1, { timeout: 15_000 });
  const scrub = page.locator(SCRUB);
  await expect(scrub, 'scrub slider should be shown').toBeVisible({ timeout: 10_000 });
  await expect(page.getByTitle('Skip to the live machine')).toBeVisible();

  // 3. CLIP PLAYS: currentTime advances between two samples.
  const t0 = await clip.evaluate((v: HTMLVideoElement) => v.currentTime);
  await expect
    .poll(() => clip.evaluate((v: HTMLVideoElement) => v.currentTime), {
      message: 'clip currentTime should advance (autoplay)',
      timeout: 15_000,
    })
    .toBeGreaterThan(t0 + 0.5);
  const dur = await clip.evaluate((v: HTMLVideoElement) => v.duration);
  expect(dur, 'clip duration should be known once playing').toBeGreaterThan(1);
  testInfo.annotations.push({ type: 'clip', description: `duration=${dur.toFixed(1)}s started at t=${t0.toFixed(2)}s` });

  // 4. ALIGNMENT: once the background live layer exists, it and the boot clip
  //    must occupy the exact same rendered box. The removed readiness placard
  //    must not return and silently consume flex width again.
  let geometry = { clip: null, live: null } as Awaited<ReturnType<typeof probeSeamGeometry>>;
  await expect.poll(async () => {
    geometry = await probeSeamGeometry(page);
    return geometry.clip !== null && geometry.live !== null;
  }, { message: 'both boot and live surfaces should coexist before handoff', timeout: 60_000 }).toBe(true);
  expect(geometry.clip!.x).toBeCloseTo(geometry.live!.x, 0);
  expect(geometry.clip!.y).toBeCloseTo(geometry.live!.y, 0);
  expect(geometry.clip!.width).toBeCloseTo(geometry.live!.width, 0);
  expect(geometry.clip!.height).toBeCloseTo(geometry.live!.height, 0);
  await expect(page.getByText('Ready', { exact: true })).toHaveCount(0);
  testInfo.annotations.push({ type: 'seam', description: JSON.stringify(geometry) });

  // 5. SCRUB: press the slider at ~60% — the clip must seek there. (A real mouse
  //    press: pointerdown pauses + grabs, the input event seeks, pointerup resumes.)
  const box = await scrub.boundingBox();
  expect(box, 'scrub slider must have a bounding box').toBeTruthy();
  const frac = 0.6;
  await page.mouse.click(box!.x + box!.width * frac, box!.y + box!.height / 2);
  const seeked = await clip.evaluate((v: HTMLVideoElement) => v.currentTime);
  expect(
    Math.abs(seeked - dur * frac),
    `scrub click at ${frac} should seek near ${(dur * frac).toFixed(1)}s (got ${seeked.toFixed(1)}s)`,
  ).toBeLessThan(Math.max(3, dur * 0.1));
  testInfo.annotations.push({ type: 'scrub', description: `clicked ${frac} → t=${seeked.toFixed(2)}s of ${dur.toFixed(1)}s` });

  // 6. HANDOFF: Skip ends the clip; overlay reveals over live (or its 4 s
  //    stranding fallback) and unmounts — clip video + scrubber leave the DOM.
  await page.getByTitle('Skip to the live machine').click();
  await expect(scrub, 'overlay should unmount after skip (reveal → gone)').toHaveCount(0, { timeout: 30_000 });
  await expect(clip, 'boot clip <video> should be removed on handoff').toHaveCount(0);

  // 7. LIVE: the live surface is painting real content (canvas on Firefox,
  //    srcObject video on Chromium) — the swap actually landed on a live tile.
  let live = { kind: 'none', w: 0, h: 0, nonBlackPct: 0 };
  await expect
    .poll(async () => {
      live = await probeLive(page);
      return live.kind !== 'none' && live.nonBlackPct >= TILE.minNonBlackPct;
    }, {
      message: `live surface should paint post-handoff (nonBlack>=${TILE.minNonBlackPct}%) — last probe is attached`,
      timeout: 60_000,
      intervals: [1000],
    })
    .toBe(true);
  testInfo.annotations.push({ type: 'live', description: `${live.kind} ${live.w}x${live.h} nonBlack=${live.nonBlackPct}%` });
  await testInfo.attach('live-probe', { body: JSON.stringify(live, null, 2), contentType: 'application/json' });
});

test(`BOOT-VIDEO · ${TILE.displayName} — refresh skips a boot clip already started in this history entry`, async ({ page }) => {
  // A fresh deep link is still a genuine first entry and must show the boot clip.
  await page.goto(`/os/${TILE.osId}?streamhost=${TILE.osId}`, {
    waitUntil: 'domcontentloaded',
    timeout: 30_000,
  });
  await expect(page.locator(CLIP), 'a fresh deep link should play its first boot clip').toHaveCount(1, {
    timeout: 15_000,
  });

  // OsStreamRoute marks the current browser-history entry after taking its
  // first-entry snapshot. Waiting on the marker makes the reload deterministic.
  await expect.poll(() => page.evaluate((osId) => {
    const state = window.history.state as Record<string, unknown> | null;
    return state?.['osgallery.bootVideoPlayedFor'] === osId;
  }, TILE.osId)).toBe(true);

  await page.reload({ waitUntil: 'domcontentloaded', timeout: 30_000 });

  // Reloading the SAME history entry reconnects to the live surface directly;
  // neither the clip nor any of its transport UI may remount.
  await expect(page.locator(CLIP), 'refresh must not restart the boot clip').toHaveCount(0);
  await expect(page.locator(SCRUB), 'refresh must not restore boot-video controls').toHaveCount(0);
  await expect(page.locator('.sv-video'), 'the live tile surface remains mounted').toBeVisible({ timeout: 15_000 });
});

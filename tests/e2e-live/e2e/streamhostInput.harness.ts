// ============================================================================
//  streamhostInput.harness.ts — per-tile input regression runner (streamhost).
//  ---------------------------------------------------------------------------
//  Drives the GENUINE deployed SPA (grid → card click → StreamView) against a
//  live streamhost tile over WebTransport+WebCodecs, exactly as a user does, and
//  verifies the guest's reaction on its AUTHORITATIVE framebuffer via QMP
//  screendump (streamhostInput.qmp.ts) — no admin API, no shim on the input path.
//
//  For EACH tile it asserts, and records per channel PASS/FAIL/SKIP:
//    decode   — StreamView's <video> decodes a live frame (first VideoFrame).
//    control  — the control data channel opens (status pill shows "— CONTROL").
//    mouse    — real page.mouse over the <video> (StreamView's own pointer
//               handlers → sendMouse*/sendTouch over WebTransport) changes the
//               guest framebuffer beyond idle (drag-sweep held + right-click menu
//               + double-click + corner). For PS/2 (relative-pointer) tiles the
//               cursor motion itself is the proof; for tablet tiles a menu/marquee
//               is. touch tiles get a held swipe.
//    keyboard — real page.keyboard (StreamView's global capture → sendKeyEvent):
//               a literal string + ArrowDown/Up + Enter + a single Esc (forwarded
//               to the guest — double-Esc would exit), diffed vs idle.
//
//  The ONLY test-environment shim is on the DECODE side: this GPU-less host has no
//  hardware H.264 decoder, and StreamClient hard-configures the WebCodecs
//  VideoDecoder with hardwareAcceleration:'prefer-hardware' (correct for real user
//  GPUs). We coerce that ONE field to 'no-preference' via addInitScript so the
//  UNMODIFIED deployed bundle can decode in headless; the wire, control plane and
//  all input remain byte-for-byte the shipped code.
// ============================================================================

import { test, expect, type Page, type BrowserContext } from '@playwright/test';
import { appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { shot, diffPpm, fmtDiff, type DiffResult, type Ppm } from './streamhostInput.qmp';
import type { InputTileSpec } from './streamhostInput.group';

const SPA_BASE = (process.env.SPA_BASE_URL ?? 'https://127.0.0.1:8443').replace(/\/$/, '');
const CONNECT_MS = process.env.STREAMHOST_CONNECT_MS ? Number(process.env.STREAMHOST_CONNECT_MS) : 70000;

// RESET-TO-GOLDEN (default on). The suite restores each tile to its curated golden
// fixture BEFORE driving it, via the SAME host-side authority the SPA "Restore to
// golden" button uses: reset-tile.sh reads golden-manifest.json and does either a
// live QMP `loadvm golden` (most tiles) or a cold-boot restart (serenityos, toaruos).
// One reset code path for the test AND the button => what the suite proves green is
// exactly what the button restores. Opt out with STREAMHOST_NO_RESET=1.
const RESET_SCRIPT = process.env.STREAMHOST_RESET_SCRIPT ?? '/data/vms/streamhost/serve/reset-tile.sh';
const LOADVM_SETTLE_MS = process.env.STREAMHOST_LOADVM_SETTLE_MS ? Number(process.env.STREAMHOST_LOADVM_SETTLE_MS) : 2500;
const RESTART_BOOT_MS = process.env.STREAMHOST_RESTART_BOOT_MS ? Number(process.env.STREAMHOST_RESTART_BOOT_MS) : 45000;

// Reliability gates (calibrated on-host): a channel "reacted" when the framebuffer
// changed clearly above the tile's own idle noise. Absolute floor + relative-to-idle.
// A rendered pointer sprite on a ~800x600 guest is a few-hundred-pixel change
// (~2-6e-4 of the frame): that IS the reliable "the cursor moved and painted"
// signal the PS/2 abs→rel fix produces, so gate there. Below ~2e-4 means no cursor
// painted into the captured framebuffer (uncaptured HW overlay) — a SKIP case. The
// idle-relative factor rejects ambient animation regardless of the absolute floor.
const MOUSE_PASS_CF = 2e-4;
const KEY_PASS_CF = 2e-4;
const IDLE_FACTOR = 3;

/** The decode-side shim (see header). Coerces prefer-hardware → no-preference. */
export function decoderShim(): void {
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

function reacted(d: DiffResult | null, idle: DiffResult, floor: number): boolean {
  if (!d) return false;
  return d.changedFrac >= floor && d.changedFrac >= idle.changedFrac * IDLE_FACTOR + 3e-5;
}

// BOOT-VIDEO tiles (win95/win98se/win2000/winxp/solaris/haiku/os2warp/amiga) mount
// a SECOND <video> — the recorded boot clip (src URL, plays to completion since
// spa 0a35afc) — over the live stream. The LIVE element is the srcObject-fed one
// (StreamView feeds it from captureStream); the clip has a plain src and no
// srcObject. Every probe below selects on srcObject so the clip can neither
// satisfy the decode gate nor swallow the 45s budget / the pointer targets.

/** Pixel targets over the letterboxed <video> (object-fit:contain aware). */
async function videoTargets(page: Page) {
  return page.evaluate(() => {
    const v = [...document.querySelectorAll('#root video')].find(
      (x) => (x as HTMLVideoElement).srcObject,
    ) as HTMLVideoElement;
    const r = v.getBoundingClientRect();
    const vw = v.videoWidth, vh = v.videoHeight;
    const srcA = vw / vh, boxA = r.width / r.height;
    let cw: number, ch: number, ox: number, oy: number;
    if (srcA > boxA) { cw = r.width; ch = cw / srcA; ox = 0; oy = (r.height - ch) / 2; }
    else { ch = r.height; cw = ch * srcA; ox = (r.width - cw) / 2; oy = 0; }
    const at = (fx: number, fy: number) => ({ x: r.x + ox + fx * cw, y: r.y + oy + fy * ch });
    return { at00: at(0, 0), cw, ch, ox: r.x + ox, oy: r.y + oy };
  });
}
const px = (t: { ox: number; oy: number; cw: number; ch: number }, fx: number, fy: number) =>
  ({ x: t.ox + fx * t.cw, y: t.oy + fy * t.ch });

/** Count pointer events that actually reach StreamView's <video> (wiring proof). */
async function instrumentPointer(page: Page) {
  await page.evaluate(() => {
    const v = ([...document.querySelectorAll('#root video')].find(
      (x) => (x as HTMLVideoElement).srcObject,
    ) ?? null) as HTMLVideoElement | null;
    (window as unknown as { __ptr: number }).__ptr = 0;
    if (v && !(v as unknown as { __b?: boolean }).__b) {
      (v as unknown as { __b: boolean }).__b = true;
      for (const t of ['pointerdown', 'pointerup', 'pointermove', 'pointerrawupdate'])
        v.addEventListener(t, () => { (window as unknown as { __ptr: number }).__ptr++; }, true);
    }
  });
}

export interface DriveResult { mouse: DiffResult | null; ptrReached: number; }

/** Drive real mouse over the video and return the MAX framebuffer diff vs baseline.
 *  NON-DESTRUCTIVE by design (these are live exhibit guests): the two reliable
 *  signals are (1) CURSOR MOTION — a rendered pointer sprite moving across the
 *  screen, which is completely state-independent and is exactly what the PS/2
 *  abs→rel fix produces — and (2) a right-click that OPENS a context menu, which we
 *  immediately close with Esc. We deliberately do NOT double-click or activate icons
 *  (that launches installers) and never confirm a menu item (that once drove OS/2
 *  into Shutdown). */
async function driveMouse(page: Page, spec: InputTileSpec, baseline: Ppm): Promise<DriveResult> {
  await page.bringToFront();
  await instrumentPointer(page);
  const t = await videoTargets(page);
  let best: DiffResult | null = null;
  const consider = (d: DiffResult) => { if (!best || d.changedFrac > best.changedFrac) best = d; };

  // (1) held drag-sweep across the desktop — a continuous stream of pointer samples
  //     that RENDER THE CURSOR at successive positions (+ a selection marquee where
  //     the guest draws one). Captured DURING the drag. Non-destructive.
  const p0 = px(t, 0.32, 0.4);
  await page.mouse.move(p0.x, p0.y, { steps: 3 });
  await page.mouse.down();
  for (let i = 1; i <= 14; i++) {
    const q = px(t, 0.32 + 0.34 * (i / 14), 0.4 + 0.18 * (i / 14));
    await page.mouse.move(q.x, q.y, { steps: 2 });
    await page.waitForTimeout(15);
  }
  consider(diffPpm(baseline, await shot(spec.stationDir, 'drag')));
  await page.mouse.up();
  await page.waitForTimeout(120);

  // (2) right-click on an empty desktop point — OPENS a context menu on most WIMP
  //     guests (a tap on touch tiles). We only OPEN it (never confirm an item), then
  //     immediately Esc it closed so the exhibit is left as we found it.
  const c = px(t, 0.5, 0.55);
  await page.mouse.click(c.x, c.y, { button: 'right' });
  await page.waitForTimeout(700);
  consider(diffPpm(baseline, await shot(spec.stationDir, 'rclick')));
  await page.keyboard.press('Escape'); // dismiss the context menu (leave no trace)
  await page.waitForTimeout(200);

  const ptrReached = await page.evaluate(() => (window as unknown as { __ptr: number }).__ptr);
  return { mouse: best, ptrReached };
}

/** Drive real keyboard through StreamView's global capture; return the MAX diff vs
 *  baseline across the requested keys. Guest keyboard ECHO is state-dependent over a
 *  shared framebuffer (a shell listing can collide with what is already on screen; a
 *  focused empty window echoes nothing), so we probe THREE state-independent ways and
 *  take the strongest — all built from the requested key set (a character, ArrowDown,
 *  ArrowUp, Esc, Enter) plus Ctrl+Esc:
 *    (a) the literal string + arrows            — shell/field echo + selection move.
 *    (b) Ctrl+Esc                               — pops the Start menu on every Windows
 *        -family guest regardless of window state, then Esc closes it (non-destructive).
 *    (c) Enter                                  — a newline scrolls a bottom-of-screen
 *        console (near-full-frame change) / activates a default.
 *  The two Esc presses (Ctrl+Esc's, and the close/​requested Esc) are >500ms apart so
 *  StreamView's double-Esc-exits-to-grid never triggers. */
async function driveKeyboard(page: Page, spec: InputTileSpec, baseline: Ppm): Promise<DiffResult> {
  await page.bringToFront();
  let best: DiffResult | null = null;
  const consider = (d: DiffResult) => { if (!best || d.changedFrac > best.changedFrac) best = d; };

  // (a) literal string + Arrow selection movement. keyType carries its OWN newline
  //     for shell tiles ("ls\n") so the command echoes+runs (harmless); GUI tiles use
  //     a bare character so nothing is activated.
  if (spec.keyType) await page.keyboard.type(spec.keyType, { delay: 60 });
  await page.waitForTimeout(120);
  await page.keyboard.press('ArrowDown'); await page.waitForTimeout(120);
  await page.keyboard.press('ArrowUp'); await page.waitForTimeout(120);
  consider(diffPpm(baseline, await shot(spec.stationDir, 'key_a')));

  // (b) Ctrl+Esc → the Start menu POPS UP on every Windows-family guest (state-
  //     independent — the baseline was normalized to a CLOSED menu first, so this is
  //     always a closed→open transition, never an accidental open→close toggle); a
  //     no-op elsewhere. We immediately Esc it closed — non-destructive.
  await page.keyboard.down('Control');
  await page.keyboard.press('Escape');
  await page.keyboard.up('Control');
  await page.waitForTimeout(800);
  consider(diffPpm(baseline, await shot(spec.stationDir, 'key_start')));

  // The requested single Esc — also closes the Start menu (>500ms after the last Esc
  // so StreamView's double-Esc-exits-to-grid never fires). No Enter/activation: we do
  // NOT launch icons or confirm menu items on these live exhibit guests.
  await page.keyboard.press('Escape');
  await page.waitForTimeout(400);

  return best!;
}

export function runInputTest(spec: InputTileSpec): void {
  test(`INPUT · ${spec.displayName} [${spec.osId}] (${spec.pointer}${spec.touch ? '/touch' : ''})`, async ({ page, context }: { page: Page; context: BrowserContext }, testInfo) => {
    // Decode-side shim only (see header). MUST be installed before the SPA loads.
    await context.addInitScript(decoderShim);

    // RESET TO GOLDEN — DEFAULT. Restore THIS tile to its curated golden fixture
    // before driving, so every run starts from the SAME focused desktop/terminal:
    // the exact state the gated per-input assertions were VISUALLY CERTIFIED against
    // (no accumulated menus/dialogs/launched apps, no risk of driving a guest into
    // Shutdown, deterministic reactions). Delegates to reset-tile.sh (the single
    // authority the restore BUTTON also uses): `loadvm <snapshot>` live for most
    // tiles, or a cold-boot `restart` for tiles whose store holds no vmstate.
    // A failed reset is FATAL (unless NO_GATE): the fixture the gated assertions
    // assume would not be guaranteed. Opt out entirely with STREAMHOST_NO_RESET=1.
    if (!process.env.STREAMHOST_NO_RESET) {
      let ok = false; let detail = '';
      try {
        detail = execFileSync(RESET_SCRIPT, [spec.osId], { encoding: 'utf8', timeout: 150000 }).trim();
        ok = /:\s*OK\b/.test(detail);
      } catch (e) { detail = String((e as { message?: string }).message ?? e); }
      testInfo.annotations.push({ type: 'reset', description: ok ? `${spec.resetMode}: ${detail}` : `RESET FAILED (${detail})` });
      if (!ok && !process.env.STREAMHOST_NO_GATE) {
        expect(ok, `reset-to-golden must succeed for ${spec.osId} before its run (${spec.resetMode}): ${detail}`).toBe(true);
      }
      // Settle: loadvm resumes instantly; a restart cold-boots to the fixture.
      await page.waitForTimeout(spec.resetMode === 'restart' ? RESTART_BOOT_MS : LOADVM_SETTLE_MS);
    }

    // 1. Genuine user path: land on the grid, click THIS tile's card. (The card
    //    is a react-router <a class="os-card"> in current bundles, a <button> in
    //    older ones — select by class only.)
    await page.goto(`${SPA_BASE}/?streamhost=${spec.osId}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForSelector('.os-card', { timeout: 30000 });
    const card = page.locator(`.os-card[aria-label^="${spec.displayName},"]`);
    await expect(card, `a grid card for "${spec.displayName}" must exist`).toHaveCount(1);
    await card.scrollIntoViewIfNeeded();
    await card.click();

    // 2. DECODE — StreamView's LIVE <video> (srcObject-fed) paints a live frame.
    //    On boot-video tiles the clip <video> (src URL) also plays in this slot —
    //    it must NOT satisfy this gate (it decodes fine even when the live stream
    //    is dead, and since spa 0a35afc it runs to completion), so select on
    //    srcObject: only the captureStream-fed live element qualifies.
    let decodeOk = false; let dim = { w: 0, h: 0 };
    try {
      await page.waitForFunction(() => {
        const v = ([...document.querySelectorAll('#root video')].find(
          (x) => (x as HTMLVideoElement).srcObject,
        ) ?? null) as HTMLVideoElement | null;
        return !!v && v.videoWidth > 0 && v.videoHeight > 0 && !v.paused && v.readyState >= 2;
      }, undefined, { timeout: CONNECT_MS });
      dim = await page.evaluate(() => {
        const v = [...document.querySelectorAll('#root video')].find(
          (x) => (x as HTMLVideoElement).srcObject,
        ) as HTMLVideoElement;
        return { w: v.videoWidth, h: v.videoHeight };
      });
      decodeOk = true;
    } catch { /* decodeOk stays false */ }
    testInfo.annotations.push({ type: 'decode', description: decodeOk ? `PASS ${dim.w}x${dim.h}` : 'FAIL — no live frame' });

    // 3. CONTROL channel — the status pill flips to "— CONTROL" once input is accepted.
    let controlOk = false;
    try {
      await expect(page.getByText(/—\s*CONTROL/)).toBeVisible({ timeout: 45000 });
      controlOk = true;
    } catch { /* controlOk stays false */ }
    await page.waitForTimeout(1200);
    testInfo.annotations.push({ type: 'control', description: controlOk ? 'PASS (channel open)' : 'FAIL — channel never opened' });

    // A live control channel is the precondition for sending input at all. Without
    // it (or without decode, which gates StreamView's pointer wiring) nothing can
    // be driven — that is a hard regression, fail loudly. (NO_GATE = measurement
    // pass: record everything, never throw, so all 24 tiles report their numbers.)
    const NO_GATE = !!process.env.STREAMHOST_NO_GATE;
    if (!NO_GATE) expect(controlOk, 'streamhost control channel must open').toBe(true);
    if (!controlOk && NO_GATE) {
      // Can't drive input without a channel; record and end this measurement.
      testInfo.annotations.push({ type: 'verdict', description: 'mouse=FAIL keyboard=FAIL (no control channel)' });
      return;
    }

    // 4a. NORMALIZE: bring the guest toward a known-clean state before baselining, so
    //     leftover open menus/dialogs don't contaminate idle AND the Start-menu probe
    //     is a deterministic closed→open transition (an already-open Start menu would
    //     otherwise make Ctrl+Esc a close, not an open — the run-to-run flake). Two
    //     Esc presses >500ms apart close a menu then a dialog; each is a single
    //     forwarded Esc (never the <500ms double-tap that exits to the grid).
    await page.bringToFront();
    await page.keyboard.press('Escape');
    await page.waitForTimeout(800);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(1200);

    // 4b. IDLE baseline: sample the self-churn several times and take the MINIMUM,
    //     so a one-off repaint (window fade, clock tick straddle) can't inflate it.
    let base = await shot(spec.stationDir, 'base');
    let idle: DiffResult = { changedFrac: 1, meanDelta: 255 };
    for (let i = 0; i < 3; i++) {
      await page.waitForTimeout(1000);
      const next = await shot(spec.stationDir, `idle${i}`);
      const d = diffPpm(base, next);
      if (d.changedFrac < idle.changedFrac) idle = d;
      base = next; // walk forward so we compare consecutive frames
    }
    // `base` is the last (quiet) sample — use it as the input baseline.
    testInfo.annotations.push({ type: 'idle', description: `min ${fmtDiff(idle)}` });

    // 5. MOUSE — real pointer over the video, verified on the framebuffer.
    let mouse: DiffResult | null = null; let ptrReached = 0;
    if (decodeOk) {
      const r = await driveMouse(page, spec, base);
      mouse = r.mouse; ptrReached = r.ptrReached;
    }
    const mouseReacted = reacted(mouse, idle, MOUSE_PASS_CF);
    testInfo.annotations.push({ type: 'mouse', description: `${fmtDiff(mouse)} ptrReached=${ptrReached} reacted=${mouseReacted}` });

    // 6. KEYBOARD — real keys through the global capture, verified on the framebuffer.
    const base2 = await shot(spec.stationDir, 'kbase');
    const keyDiff = await driveKeyboard(page, spec, base2);
    const keyReacted = reacted(keyDiff, idle, KEY_PASS_CF);
    testInfo.annotations.push({ type: 'keyboard', description: `${fmtDiff(keyDiff)} reacted=${keyReacted}` });

    // ---- verdict + machine-readable log line for the report table --------------
    const verdict = (reactedFlag: boolean, skip: string | undefined, canSend: boolean): 'PASS' | 'FAIL' | 'SKIP' => {
      if (reactedFlag) return 'PASS';
      if (skip) return 'SKIP';
      return canSend ? 'FAIL' : 'FAIL';
    };
    const mouseVerdict = spec.mouseSkip && !mouseReacted ? 'SKIP' : verdict(mouseReacted, undefined, controlOk);
    const keyVerdict = spec.keyboardSkip && !keyReacted ? 'SKIP' : verdict(keyReacted, undefined, controlOk);

    if (process.env.STREAMHOST_LOG) {
      appendFileSync(process.env.STREAMHOST_LOG, JSON.stringify({
        osId: spec.osId, stationDir: spec.stationDir, displayName: spec.displayName,
        pointer: spec.pointer, touch: !!spec.touch,
        decode: decodeOk ? dim : false, control: controlOk,
        idle, mouse, keyboard: keyDiff, ptrReached,
        mouseReacted, keyReacted, mouseVerdict, keyVerdict,
        mouseSkipReason: mouseVerdict === 'SKIP' ? spec.mouseSkip : null,
        keyboardSkipReason: keyVerdict === 'SKIP' ? spec.keyboardSkip : null,
      }) + '\n');
    }

    testInfo.annotations.push({ type: 'verdict', description: `mouse=${mouseVerdict} keyboard=${keyVerdict}` });

    // A documented known-limit is a SKIP, not a failure — but input WAS delivered
    // (decode + control proven, pointer reached the video); record and move on.
    if (mouseVerdict === 'SKIP') {
      testInfo.annotations.push({ type: 'mouse-skip', description: `${spec.mouseSkip} [measured ${fmtDiff(mouse)} vs idle ${fmtDiff(idle)}, ptrReached=${ptrReached}]` });
    }
    if (keyVerdict === 'SKIP') {
      testInfo.annotations.push({ type: 'keyboard-skip', description: `${spec.keyboardSkip} [measured ${fmtDiff(keyDiff)} vs idle ${fmtDiff(idle)}]` });
    }

    // FAIL loudly only when a channel that SHOULD react did not, and input demonstrably
    // could be sent (control open) — that is a genuine input regression. Suppressed
    // in NO_GATE measurement mode so every tile reports its numbers.
    if (!NO_GATE && mouseVerdict === 'FAIL') {
      expect(mouseReacted, `MOUSE regression on ${spec.osId}: no framebuffer reaction (${fmtDiff(mouse)} vs idle ${fmtDiff(idle)}, ptrReached=${ptrReached})`).toBe(true);
    }
    if (!NO_GATE && keyVerdict === 'FAIL') {
      expect(keyReacted, `KEYBOARD regression on ${spec.osId}: no framebuffer reaction (${fmtDiff(keyDiff)} vs idle ${fmtDiff(idle)})`).toBe(true);
    }
  });
}

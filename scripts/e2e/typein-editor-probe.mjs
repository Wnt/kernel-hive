// Type-in editor probe: drive the REAL editor in the real SPA against a live
// station, the way a visitor does: ☰ → Code editor, paste a listing, press
// "Type into machine", wait for the run to finish. It then optionally types
// RUN, takes the station's own framebuffer, and restores the golden.
//
// WHY. The editor's pacing comes from the registry (`typeIn.perCharMs` and its
// settles) and its keys go through the same daemon queue a visitor's do. Only
// a browser-in-the-loop run says whether a long listing arrives intact at that
// pace, which is exactly what tuning the numbers needs. PASS/FAIL is NOT
// decided here (see typing-pace-probe.mjs): the framebuffer is the proof and
// an eye reads it (AGENTS.md rule 9). This prints the measurable part: lines,
// characters, wall clock, effective ms/char, and the editor's own status line.
//
//   INVITE=<code or path> GALLERY_URL=https://kernelhive.madekivi.fi \
//     node typein-editor-probe.mjs <station> <listing.bas> [--run <cmd>] [--restore] [--fb-shot <dir>]
//                                  [--stop-after <seconds>] [--inject-keys <seconds>] [--then <steps>]
//                                  [--first <steps>] [--demo <label>] [--restore-first]
//
// The listing is pasted (a synthetic `paste` event, so the editor's own paste
// cleaning runs). `--run` types its argument + RETURN through the real
// keyboard after the run (lower case on a Commodore: Shift+letter there is a
// graphics glyph). `--fb-shot <dir>` captures the station framebuffer with
// `ssh -n lab labctl shot` into <dir> (a path labhost and CT950 both see, e.g.
// /data/vms/sandbox/<name>/proof); it needs the `lab` door. `--restore` ends
// with the visitor's own ☰ → Restore to golden, so a live station is left as
// it was found. `--stop-after` presses Stop mid-run and takes the framebuffer
// right after and again 3 s later: the two must match (no key after Stop). A
// `--inject-keys` holds the visitor's own Shift + Meta for 2 s (and taps S)
// that many seconds into the run, as a screenshot shortcut would: the editor
// pauses the physical keyboard while it types, so the listing must still arrive
// byte-exact (docs/TYPE-IN-EDITOR.md). `--then` plays the visitor's next keys
// after `--run`, through the real keyboard: comma-separated steps, each a key
// (`7`, `Enter`, `p`), `<key>*<n>` to press it n times, `@<ms>` to wait, or
// `#<label>` for a framebuffer shot (an INPUT answer, a game's keys).
// `--first` plays steps of the same form BEFORE the editor opens: the step a
// station's `typeIn.hint` asks the visitor for (B at the SAM's and the //e's
// boot menus, BASIC + RETURN twice on the KC 85/4). `--demo <label>` (with
// `-` as the listing) presses the stage menu's demo-typist row instead of the
// editor, for a keyboard station with a demoProgram but no typeIn block; `-`
// alone types nothing, so `--first`/`--then` are the visitor's whole input.
// `--restore-first` presses the visitor's own ☰ → Restore to golden BEFORE
// typing, then types the moment the SPA has reconnected by itself (no reload,
// no wait of its own): "the first keys after a restore" exactly as a visitor
// produces them (docs/TYPE-IN-EDITOR.md, "Typing right after a Restore").
// A signed-in session is required to see the stream at all
// (station-open.mjs's signIn header), hence INVITE + the public origin.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { galleryUrl, inviteCode, openStation, probeVideo, shotDir, signIn } from './station-open.mjs';

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
};
const [id, listingPath] = args;
if (!id || !listingPath) {
  console.error('usage: node typein-editor-probe.mjs <station> <listing.bas> [--run <cmd>] [--restore] [--fb-shot <dir>]');
  process.exit(2);
}
const listing = listingPath === '-' ? '' : fs.readFileSync(listingPath, 'utf8');
const runCmd = flag('--run');
const fbDir = flag('--fb-shot');
const restore = args.includes('--restore');
const restoreFirst = args.includes('--restore-first');
const stopAfter = Number(flag('--stop-after') ?? 0);
const thenSteps = (flag('--then') ?? '').split(',').filter(Boolean);
const firstSteps = (flag('--first') ?? '').split(',').filter(Boolean);
const demoLabel = flag('--demo');
const injectAfter = Number(flag('--inject-keys') ?? 0);
let injected = !injectAfter;
const base = galleryUrl();
const OUT = shotDir();
const TS = Date.now();
const tag = `typein-${id}-${TS}`;

const fbShot = (label) => {
  if (!fbDir) return;
  const path = `${fbDir}/${tag}-${label}.png`;
  try {
    execFileSync('ssh', ['-n', 'lab', `labctl shot ${id} ${path}`], { stdio: 'pipe', timeout: 60000 });
    console.log(`framebuffer ${label}: ${path}`);
  } catch (e) {
    console.log(`framebuffer ${label}: FAILED (${String(e.message || e).slice(0, 120)})`);
  }
};

// `!click:X:Y` / `!dclick:X:Y` — the real SPA pointer at X,Y of the station's
// PUBLISHED surface (the stream's own pixels), mapped through the <video>
// element's letterboxed box. The double-click is two deliberate press/release
// pairs (80 ms down, 150 ms apart): a zero-gap dblclick can arrive as one
// click on a guest that samples its button.
const pointer = async (page, spec) => {
  const [verb, x, y] = spec.split(':');
  const v = page.locator('video').first();
  const box = await v.boundingBox();
  const { vw, vh } = await v.evaluate((el) => ({ vw: el.videoWidth, vh: el.videoHeight }));
  if (!box || !vw || !vh) throw new Error(`pointer ${spec}: no live video`);
  const sc = Math.min(box.width / vw, box.height / vh);
  const px = box.x + (box.width - vw * sc) / 2 + Number(x) * sc;
  const py = box.y + (box.height - vh * sc) / 2 + Number(y) * sc;
  await page.mouse.move(px, py, { steps: 10 });
  await page.waitForTimeout(600);
  const tap = async () => {
    await page.mouse.down();
    await page.waitForTimeout(80);
    await page.mouse.up();
  };
  if (verb === 'click') await tap();
  else if (verb === 'dclick') { await tap(); await page.waitForTimeout(150); await tap(); }
  else throw new Error(`pointer ${spec}: verb must be click or dclick`);
};

const play = async (page, steps) => {
  for (const step of steps) {
    if (step.startsWith('@')) await page.waitForTimeout(Number(step.slice(1)));
    else if (step.startsWith('#')) fbShot(step.slice(1));
    else if (/^!d?click:/.test(step)) await pointer(page, step.slice(1)); // not the `!` key
    else {
      const [key, times] = step.split('*');
      for (let i = 0; i < Number(times ?? 1); i += 1) {
        await page.keyboard.press(key);
        await page.waitForTimeout(250);
      }
    }
  }
};

// The page screenshot is a courtesy: with a decoder busy on a heavy picture it can
// time out, and that must not take the run (and its --restore) down with it. The
// station framebuffer (fbShot) is the proof.
const pageShot = async (page, path) => {
  try {
    await page.screenshot({ path, timeout: 15000 });
  } catch (e) {
    console.log(`page screenshot ${path}: FAILED (${String(e.message || e).split('\n')[0].slice(0, 100)})`);
  }
};

const typeWithEditor = async (page) => {
  await page.click('button[aria-label="Controls"]');
  await page.getByRole('button', { name: /Code editor/ }).click();
  const ta = page.locator('.ti-panel textarea');
  await ta.waitFor({ timeout: 10000 });
  await ta.fill('');
  await ta.evaluate((el, text) => {
    const data = new DataTransfer();
    data.setData('text/plain', text);
    el.focus();
    el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
  }, listing);
  const status = page.locator('.ti-status');
  console.log(`editor: ${(await status.innerText()).trim()}`);
  await pageShot(page, `${OUT}/${tag}-before.png`);

  const go = page.locator('button.ti-go');
  for (let waited = 0; await go.isDisabled(); waited += 500) {
    if (waited > 30000) throw new Error(`Type button stayed disabled: ${await go.getAttribute('title')}`);
    await page.waitForTimeout(500);
  }
  const t0 = Date.now();
  await go.click();
  let last = '';
  for (;;) {
    const text = (await status.innerText()).trim();
    if (text !== last) { console.log(`  +${((Date.now() - t0) / 1000).toFixed(1)}s ${text}`); last = text; }
    if (!(await page.locator('button.ti-stop').count())) break;
    if (!injected && Date.now() - t0 > injectAfter * 1000) {
      injected = true;
      console.log(`  +${((Date.now() - t0) / 1000).toFixed(1)}s injecting physical Shift+Meta for 2 s`);
      await page.keyboard.down('Shift');
      await page.keyboard.down('Meta');
      await page.keyboard.press('KeyS');
      await page.waitForTimeout(2000);
      await page.keyboard.up('Meta');
      await page.keyboard.up('Shift');
    }
    if (stopAfter && Date.now() - t0 > stopAfter * 1000) {
      await page.locator('button.ti-stop').click();
      console.log(`  +${((Date.now() - t0) / 1000).toFixed(1)}s pressed Stop`);
      fbShot('stopped');
      await page.waitForTimeout(3000);
      fbShot('stopped-plus-3s');
      continue;
    }
    if (Date.now() - t0 > 30 * 60 * 1000) throw new Error('run did not finish in 30 min');
    await page.waitForTimeout(1000);
  }
  const ms = Date.now() - t0;
  const typed = listing.split('\n').filter((l) => l.trim()).join('').length;
  console.log(`editor: ${(await status.innerText()).trim()}`);
  console.log(`run ended after ${(ms / 1000).toFixed(1)} s: ${typed} chars, ${(ms / Math.max(1, typed)).toFixed(0)} ms/char all-in`);
  await pageShot(page, `${OUT}/${tag}-typed.png`);
  fbShot('typed');
};

// --demo <label>: the stage menu's "Type in a demo program" row (its aria-label
// is the station's demoProgram.label) instead of the editor -- for keyboard
// stations without a typeIn block. Waits while the row is disabled (typing).
const typeDemo = async (page, label) => {
  const row = () => page.locator(`button[aria-label="${label}"]`);
  await page.click('button[aria-label="Controls"]');
  await row().click();
  const t0 = Date.now();
  for (;;) {
    await page.waitForTimeout(3000);
    // the Controls button TOGGLES the menu: open it only if the row is not
    // showing, read the row (disabled while the typist runs), close it again
    const shown = (await row().count()) && (await row().isVisible());
    if (!shown) await page.click('button[aria-label="Controls"]');
    const busy = await row().isDisabled();
    await page.click('button[aria-label="Controls"]');
    if (!busy) break;
    if (Date.now() - t0 > 30 * 60 * 1000) throw new Error('demo did not finish in 30 min');
  }
  console.log(`demo typist done after ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  fbShot('typed');
};

// ☰ → Restore to golden, and the host's answer. Returns the POST's status.
const pressRestore = async (page) => {
  await page.click('button[aria-label="Controls"]');
  const answered = page.waitForResponse(
    (r) => r.url().includes(`/restore/${id}`) && r.request().method() === 'POST', { timeout: 180000 });
  const t0 = Date.now();
  await page.getByRole('button', { name: /Restore to golden/ }).click();
  const reply = await answered;
  console.log(`restore POST: HTTP ${reply.status()} after ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  return t0;
};

// The SPA's own reconnect after a restore: its "Restoring tile…" and
// "Reconnecting to restored tile…" overlay gone and the video live again.
const waitRestoredLive = async (page, t0) => {
  for (;;) {
    const busy = await page.getByText(/Restoring tile|Reconnecting to restored tile/).count();
    const video = busy ? null : await page.evaluate(probeVideo);
    if (video && video.readyState >= 2 && video.w > 0) break;
    if (Date.now() - t0 > 180000) throw new Error('no live stream within 180 s of Restore');
    await page.waitForTimeout(100);
  }
  console.log(`restore: stream live again ${((Date.now() - t0) / 1000).toFixed(1)} s after the click`);
};

const browser = await chromium.launch({
  headless: false,
  channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: process.env.DISPLAY || ':1' },
});
const code = inviteCode();
const storageState = code ? await signIn(browser, code, `${OUT}/${tag}-state.json`) : undefined;
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 }, storageState });
const page = await ctx.newPage();
const logs = [];
page.on('pageerror', (e) => logs.push(`[pageerror] ${String(e).slice(0, 200)}`));

try {
  const opened = await openStation(page, base, id, { direct: true, log: (m) => console.log(m) });
  if (!opened.ok) throw new Error(`station did not open: ${opened.why}`);
  console.log(`stream live ${opened.video.w}x${opened.video.h}`);
  if (restoreFirst) {
    await waitRestoredLive(page, await pressRestore(page));
    fbShot('restored-first');
  }
  if (firstSteps.length) {
    const vbox = await page.locator('video').first().boundingBox();
    if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
    await play(page, firstSteps);
  }

  if (demoLabel) await typeDemo(page, demoLabel);
  else if (listing) await typeWithEditor(page);
  // listing '-' without --demo: no typist at all, only the --first/--then keys
  // through the real SPA keyboard (a keyboard station with no editor and no demo)

  if (runCmd) {
    const vbox = await page.locator('video').first().boundingBox();
    if (vbox) await page.mouse.click(vbox.x + vbox.width / 2, vbox.y + vbox.height / 2);
    for (const ch of runCmd) {
      await page.keyboard.press(ch === ' ' ? 'Space' : ch);
      await page.waitForTimeout(250);
    }
    await page.keyboard.press('Enter');
    await page.waitForTimeout(4000);
    await pageShot(page, `${OUT}/${tag}-run.png`);
    fbShot('run');
  }

  await play(page, thenSteps);

  if (restore) {
    // Wait for the host to ANSWER the reset before reloading: a reload while the
    // POST is in flight sees the old stream still live, and the "restored"
    // framebuffer is then taken before the relaunch happened.
    await pressRestore(page);
    const back = await openStation(page, base, id, { direct: true, waitMs: 60000 });
    console.log(`restore: ${back.ok ? 'stream live again' : back.why}`);
    fbShot('restored');
  }
  console.log(`page shots: ${OUT}/${tag}-*.png`);
} finally {
  if (logs.length) console.log(logs.slice(-10).join('\n'));
  await browser.close();
}

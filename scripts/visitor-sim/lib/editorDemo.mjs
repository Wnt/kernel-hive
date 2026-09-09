// lib/editorDemo.mjs — drive a guest into opening a text editor, typing, and
// selecting text with the KEYBOARD, plus a few real mouse clicks. Unlike bare
// pointer motion (traceFigureEight in stationOpen.mjs), every key press and
// every click is a DISCRETE input.dispatch.key / input.dispatch.click span on
// the trace plane — so this is the journey that actually exercises the keyboard
// and click planes end to end, not just the continuous motion plane.
//
// WHY Ctrl+Esc, NOT the Windows key. The natural "open Run" gesture is Win+R,
// but Meta/Super collides with both the driving browser and the host desktop
// (on the operator's Mac, Cmd+R reloads the tab and never reaches the guest).
// Ctrl+Esc opens the classic Start menu on every Windows since 95 and is inert
// in Chrome, so it forwards cleanly into the guest; the Start menu's "Run..."
// item then answers to 'r', and Notepad is present on every one of
// win95/98se/2000/xp/nt4/reactos.

import { typeHumanPace } from './stationOpen.mjs';

// A recipe is an ordered list of steps run by openEditor(). Steps:
//   { click: 'center' }   click the middle of the video (focus + a real click)
//   { press: 'Chord' }    one Playwright key chord, forwarded to the guest
//   { type: 'text' }      typed at a human pace
//   { wait: ms }          dwell so the emulated guest can catch up
// The waits are deliberately generous: these are old guests reached over a
// public edge, and a Start menu that has not painted yet swallows the 'r'.
const WIN_START_RUN = [
  { click: 'center' },
  { wait: 700 },
  { press: 'Control+Escape' }, // open the classic Start menu
  { wait: 1400 },
  { press: 'r' }, //             Run...
  { wait: 1400 },
  { type: 'notepad' },
  { wait: 700 },
  { press: 'Enter' },
  { wait: 3000 }, //            Notepad paints
];

export const EDITOR_RECIPES = {
  win95: WIN_START_RUN,
  win98se: WIN_START_RUN,
  win2000: WIN_START_RUN,
  winxp: WIN_START_RUN,
  nt4: WIN_START_RUN,
  reactos: WIN_START_RUN,
};

// The default is the Windows Start->Run path: the six stations above all share
// it, and any other id the operator points --mix=editor at is assumed to be a
// Windows-family guest. Both helpers are exported so a caller (and a test) can
// tell an explicitly supported station from one riding the default.
export function recipeFor(station) {
  return EDITOR_RECIPES[station] ?? WIN_START_RUN;
}

export function isExplicitlySupported(station) {
  return Object.prototype.hasOwnProperty.call(EDITOR_RECIPES, station);
}

const FUNNY_LINES = [
  'Hello, yes this is dog!',
  'I can haz kernel?',
  'All your base are belong to us.',
  'Hello IT, have you tried turning it off and on again?',
  'The cake is a lie.',
  'Greetings from the year 199X.',
  'It is a mystery.',
];

export function pickFunnyLine(rng) {
  return FUNNY_LINES[Math.floor(rng() * FUNNY_LINES.length)];
}

/** `n` random-ish click points inside a box, each inset from the edge so a
 *  click always lands ON the video (never the window chrome or a scrollbar).
 *  Pure and deterministic given `rng` — unit-tested without a browser. */
export function randomClickPoints(box, n, rng, { inset = 0.12 } = {}) {
  const pts = [];
  const x0 = box.x + box.width * inset;
  const y0 = box.y + box.height * inset;
  const w = box.width * (1 - 2 * inset);
  const h = box.height * (1 - 2 * inset);
  for (let i = 0; i < n; i++) {
    pts.push({ x: x0 + rng() * w, y: y0 + rng() * h });
  }
  return pts;
}

async function videoBox(page) {
  return page.locator('video').first().boundingBox().catch(() => null);
}

/** Run a station's editor-open recipe against the live stream. The stream must
 *  already be up (a <video> with a box). Returns { ok, why }. */
export async function openEditor(page, station, { log } = {}) {
  const recipe = recipeFor(station);
  const box = await videoBox(page);
  if (!box) return { ok: false, why: 'no video box to aim the editor-open gesture at' };
  for (const step of recipe) {
    if (step.click === 'center') {
      await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    } else if (step.press) {
      await page.keyboard.press(step.press);
    } else if (step.type) {
      await typeHumanPace(page, step.type, { baseMs: 130, jitter: 50 });
    } else if (step.wait) {
      await page.waitForTimeout(step.wait);
    }
  }
  log?.(`editor-open recipe for ${station} (${isExplicitlySupported(station) ? 'supported' : 'default Windows recipe'})`);
  return { ok: true, why: 'editor recipe done' };
}

/** Select the just-typed line with the KEYBOARD: caret to line start, select to
 *  line end, then shrink the selection a little. Every press is a discrete
 *  input.dispatch.key on the trace plane. Old Notepad has no Ctrl+A, so this
 *  uses Home/Shift+End/Shift+Left, which every Windows editor honours. */
export async function keyboardSelect(page, rng) {
  await page.keyboard.press('Home');
  await page.waitForTimeout(200);
  await page.keyboard.press('Shift+End');
  await page.waitForTimeout(450);
  const shrink = 2 + Math.floor(rng() * 4);
  for (let i = 0; i < shrink; i++) {
    // Playwright's arrow-key name is 'ArrowLeft', not 'Left' — 'Left' throws
    // "Unknown key". (Verified on the framebuffer: Home/Shift+End already
    // selected the line before this step, so only the shrink was broken.)
    await page.keyboard.press('Shift+ArrowLeft');
    await page.waitForTimeout(120);
  }
}

/** A few real mouse clicks at random spots over the video — each one an
 *  input.dispatch.click. Returns { ok, why }. */
export async function randomClicks(page, rng, { n = 4 } = {}) {
  const box = await videoBox(page);
  if (!box) return { ok: false, why: 'no video box for clicks' };
  const pts = randomClickPoints(box, n, rng);
  for (const p of pts) {
    await page.mouse.click(p.x, p.y);
    await page.waitForTimeout(250 + Math.floor(rng() * 400));
  }
  return { ok: true, why: `clicked ${pts.length} spots` };
}

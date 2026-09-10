import { chromium } from 'playwright';

// landing-chrome-probe — is the mini display canvas CLEAN, and does the
// on-screen keyboard open BELOW it?
//
// Four questions no unit test in this repo can answer (vitest here is plain
// Node, no jsdom), each of which was a real defect found on an Android phone:
//
//   1. the touch-instructions sheet must not exist anywhere any more;
//   2. NOTHING may paint on top of the guest's picture inside `.landing-stage`
//      — proven two ways, by bounding-box intersection over every descendant
//      AND by a hit-test grid, because an overlay with pointer-events:none is
//      invisible to the second and an off-screen box is invisible to neither;
//   3. the ⊕ Right-click and ⌨ Keyboard controls sit BELOW the stage;
//   4. opening the keyboard must not resize the picture, and every keycap's
//      LABEL must be inside its key and inside every clipping ancestor — the
//      blank-keycap defect was a label clipped by a crushed row, and only the
//      label's own painted rect can see that.
//
// The picture rect, not the stage rect, is the reference for (2): the stage's
// letterbox mat is not the guest's screen.
//
// Run from a directory that resolves `playwright` (see scripts/e2e/README.md):
//   node landing-chrome-probe.mjs https://<lab>:8443/staging/<slot>/ 400

const BASE = process.argv[2];
const WIDTH = Number(process.argv[3] ?? 400);
const TAG = process.argv[4] ?? `w${WIDTH}`;
if (!BASE) { console.error('usage: landing-chrome-probe.mjs <base-url> [width] [tag]'); process.exit(2); }

const MOBILE = WIDTH < 700;
const browser = await chromium.launch({ args: ['--no-sandbox', '--ignore-certificate-errors'] });
const ctx = await browser.newContext({
  ignoreHTTPSErrors: true,
  viewport: { width: WIDTH, height: MOBILE ? 860 : 900 },
  deviceScaleFactor: MOBILE ? 2.5 : 1,
  isMobile: MOBILE,
  hasTouch: MOBILE,
  userAgent: MOBILE
    ? 'Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36'
    : undefined,
});
const page = await ctx.newPage();
const errors = [];
page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));

// ---------------------------------------------------------------------------
//  The measurement, all of it in one page-side pass so every rect comes from
//  the SAME layout. `mode` picks the reference: 'closed' before the keyboard is
//  opened, 'open' after.
// ---------------------------------------------------------------------------
const measure = () => page.evaluate(() => {
  const q = (s) => document.querySelector(s);
  const r = (el) => { const b = el.getBoundingClientRect(); return { x: +b.x.toFixed(1), y: +b.y.toFixed(1), w: +b.width.toFixed(1), h: +b.height.toFixed(1), b: +b.bottom.toFixed(1), rt: +b.right.toFixed(1) }; };
  const stage = q('.landing-stage');
  if (!stage) return { fatal: 'no .landing-stage' };
  const pic = stage.querySelector('video, canvas');
  const stageR = stage.getBoundingClientRect();
  const picR = pic ? pic.getBoundingClientRect() : stageR;

  const name = (el) => {
    const cls = typeof el.className === 'string' ? el.className.trim().split(/\s+/).slice(0, 3).join('.') : '';
    const txt = (el.textContent ?? '').trim().replace(/\s+/g, ' ').slice(0, 34);
    return `${el.tagName.toLowerCase()}${cls ? '.' + cls : ''}${txt ? ` "${txt}"` : ''}`;
  };
  const area = (a, b) => {
    const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
    const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    return w > 0 && h > 0 ? w * h : 0;
  };
  // Anything between the picture and the stage is a CONTAINER, not paint.
  const containers = new Set();
  for (let n = pic; n && n !== document.body; n = n.parentElement) containers.add(n);

  // (2a) every descendant of the stage whose box overlaps the PICTURE.
  const over = [];
  for (const el of stage.querySelectorAll('*')) {
    if (containers.has(el) || el === pic) continue;
    if (el.contains(pic)) continue;
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) === 0) continue;
    const box = el.getBoundingClientRect();
    if (box.width < 1 || box.height < 1) continue;
    const a = area(box, picR);
    if (a < 1) continue;
    // Name the nearest ANCESTOR that identifies what this is: an anonymous
    // <div> three levels inside the conversion wall is still the wall, and a
    // report that says "div | div | div" names nothing.
    let owner = '';
    for (let n = el; n && n !== stage; n = n.parentElement) {
      const c = typeof n.className === 'string' ? n.className : '';
      if (c) { owner = c.trim().split(/\s+/)[0]; break; }
    }
    // A wrapper whose own children do the painting is reported too — the
    // report is a list of FACTS, and the caller decides what is allowed.
    over.push({ el: name(el), owner, z: cs.zIndex, pe: cs.pointerEvents, rect: r(el), overlapPx: Math.round(a) });
  }

  // (2b) hit-test grid over the picture: what is actually on top?
  const hits = {};
  for (let i = 1; i <= 5; i += 1) {
    for (let j = 1; j <= 5; j += 1) {
      const x = Math.round(picR.left + (picR.width * i) / 6);
      const y = Math.round(picR.top + (picR.height * j) / 6);
      const el = document.elementFromPoint(x, y);
      const k = el ? name(el) : 'null';
      hits[k] = (hits[k] ?? 0) + 1;
    }
  }

  // (1) the instructions sheet, by CONTENT not by class.
  const body = document.body.innerText;
  const sheet = /Touch controls/i.test(body) || /glide the crosshair/i.test(body)
    || [...document.querySelectorAll('button')].some((b) => b.textContent.trim() === 'Got it');

  // (3) the controls, found by their label. Which of them EXIST depends on the
  // width — a desktop has no touch badges and keeps the keyboard in the ☰ menu
  // — so the caller asserts on the ones it finds, plus the rule that none of
  // them may live inside the canvas.
  const btn = (re) => [...document.querySelectorAll('button')].find((b) => re.test((b.textContent ?? '').trim()));
  const ctl = (el) => (el ? { rect: r(el), inStage: stage.contains(el) } : null);
  const buttonsInStage = [...stage.querySelectorAll('button')]
    .filter((b) => !/gate-/.test(typeof b.className === 'string' ? b.className : ''))
    .map(name);

  // (4) the keyboard, and every keycap label's painted box.
  const osk = q('.osk-sheet') ?? q('.osk-inline');
  const caps = [];
  if (osk) {
    for (const key of osk.querySelectorAll('.osk-qrow .osk-key, .osk-row .osk-key')) {
      const kr = key.getBoundingClientRect();
      // The LABEL's own rect, via a Range over the key's text node — the only
      // way to see a label clipped away by a crushed row.
      let lr = null;
      for (const node of key.childNodes) {
        if (node.nodeType !== 3 || !node.data.trim()) continue;
        const rg = document.createRange(); rg.selectNodeContents(node);
        lr = rg.getBoundingClientRect(); break;
      }
      if (!lr) continue;
      // Every ancestor that can CLIP, up to the sheet.
      let clip = null;
      for (let n = key.parentElement; n && n !== document.body; n = n.parentElement) {
        const cs = getComputedStyle(n);
        if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue;
        const nb = n.getBoundingClientRect();
        const inside = lr.top >= nb.top - 0.5 && lr.bottom <= nb.bottom + 0.5
          && lr.left >= nb.left - 0.5 && lr.right <= nb.right + 0.5;
        if (!inside) { clip = `${name(n)} ${JSON.stringify(r(n))}`; break; }
      }
      caps.push({
        label: (key.textContent ?? '').trim().slice(0, 3),
        keyH: +kr.height.toFixed(1),
        rowH: +(key.parentElement?.getBoundingClientRect().height ?? 0).toFixed(1),
        labelH: +lr.height.toFixed(1),
        labelW: +lr.width.toFixed(1),
        fontPx: +getComputedStyle(key).fontSize.replace('px', ''),
        inKey: lr.top >= kr.top - 0.5 && lr.bottom <= kr.bottom + 0.5,
        clippedBy: clip,
      });
    }
  }

  return {
    stage: r(stage),
    picture: pic ? r(pic) : null,
    decoded: pic && pic.tagName === 'VIDEO' ? `${pic.videoWidth}x${pic.videoHeight}` : (pic ? `${pic.width}x${pic.height}` : null),
    streaming: !!stage.querySelector('.sv-root'),
    sheet,
    over,
    hits,
    back: ctl(btn(/^←$/)),
    menu: ctl(btn(/^☰$/)),
    rightClick: ctl(btn(/Right-click/i)),
    keyboardBtn: ctl(btn(/Keyboard/i)),
    buttonsInStage,
    osk: osk ? { cls: osk.className, rect: r(osk), inStage: stage.contains(osk) } : null,
    caps,
    strip: [...document.querySelectorAll('.landing-strip__cell')].map((e) => e.textContent),
  };
});

const fail = [];
const shots = [];
const shot = async (label) => {
  const p = `${process.env.HOME}/e2e/shots/chrome-${TAG}-${label}-${Date.now()}.png`;
  await page.screenshot({ path: p, fullPage: false });
  shots.push(p);
  return p;
};

await page.goto(BASE, { waitUntil: 'domcontentloaded' });
// The stream has to be LIVE before any of this means anything: a poster hero
// has no picture to paint over and no keyboard to open.
for (let i = 0; i < 24; i += 1) {
  const m = await measure();
  if (m.streaming && m.decoded && !m.decoded.startsWith('0x')) break;
  await page.waitForTimeout(1000);
}
const closed = await measure();
console.log(`\n== ${TAG} · keyboard CLOSED ==`);
console.log(JSON.stringify({ ...closed, over: closed.over.map((o) => `${o.owner || '?'}:${o.el}`), caps: `${closed.caps.length} caps` }, null, 1));
await shot('closed');

if (closed.fatal) { console.log(`FAIL ${closed.fatal}`); process.exit(1); }
if (!closed.streaming || !closed.decoded || closed.decoded.startsWith('0x')) {
  fail.push(`no live picture to judge (streaming=${closed.streaming} decoded=${closed.decoded})`);
}

// (1) ------------------------------------------------------------------------
if (closed.sheet) fail.push('the touch-instructions sheet is still in the document');

// (2) ------------------------------------------------------------------------
// The gate scrim is a DELIBERATE exception (it covers the frozen frame at the
// end of the free minute); the trackpad crosshair is the POINTER, not chrome.
// The two things allowed to be on the picture, both by decision:
//   gate-*      the conversion wall, which exists to cover the frozen frame;
//   sv-cursor   the trackpad crosshair, which IS the pointer, not chrome —
//               an absolute station draws no cursor of its own.
const ALLOWED = /^(gate-|landing-gate|sv-cursor)/;
const allowed = (o) => ALLOWED.test(o.owner ?? '') || ALLOWED.test(o.el);
const painting = closed.over.filter((o) => !allowed(o));
if (painting.length) fail.push(`${painting.length} element(s) paint over the picture: ${painting.map((p) => `${p.owner || '?'}:${p.el}`).join(' | ')}`);
const strayHits = Object.keys(closed.hits).filter((k) => !/^(video|canvas)/.test(k) && !/(gate-|landing-gate|sv-cursor)/.test(k));
if (strayHits.length) fail.push(`hit-test finds non-picture on top: ${strayHits.join(' | ')}`);

// (3) ------------------------------------------------------------------------
// The blanket rule first: no control of any kind lives inside the canvas.
if (closed.buttonsInStage.length) {
  fail.push(`${closed.buttonsInStage.length} button(s) inside .landing-stage: ${closed.buttonsInStage.join(' | ')}`);
}
// Then each control this width actually offers. A desktop has no touch badges
// and keeps the keyboard behind ☰, so those two are asserted only if present;
// the back escape and the menu exist at every width.
const CONTROLS = [
  ['back ←', closed.back, true],
  ['menu ☰', closed.menu, true],
  ['⊕ Right-click', closed.rightClick, MOBILE],
  ['⌨ Keyboard', closed.keyboardBtn, MOBILE],
];
for (const [what, c, required] of CONTROLS) {
  if (!c) { if (required) fail.push(`no ${what} control found at all`); continue; }
  if (c.inStage) fail.push(`the ${what} control is INSIDE .landing-stage`);
  if (c.rect.y < closed.stage.b - 1) fail.push(`the ${what} control is not below the stage (top ${c.rect.y} < stage bottom ${closed.stage.b})`);
}

// (4) ------------------------------------------------------------------------
// Open the keyboard the way THIS width offers it: a dedicated control on a
// phone, the ☰ menu's row on a desktop. Both must land below the canvas.
const clickText = (re) => page.evaluate((src) => {
  const b = [...document.querySelectorAll('button')].find((x) => new RegExp(src, 'i').test((x.textContent ?? '').trim()));
  if (!b) return false;
  b.scrollIntoView({ block: 'center' });
  b.click();
  return true;
}, re.source);

let route = null;
if (await clickText(/Keyboard/)) route = 'control';
else if (await clickText(/^☰$/)) {
  await page.waitForTimeout(400);
  if (await clickText(/Keyboard/)) route = 'menu';
}
console.log(`OPEN  keyboard opened via: ${route ?? 'NOTHING'}`);
if (!route) fail.push('found no way to open the keyboard at this width');
if (route) {
  await page.waitForTimeout(1200);
  const open = await measure();
  console.log(`\n== ${TAG} · keyboard OPEN ==`);
  console.log(JSON.stringify({ ...open, over: open.over.map((o) => `${o.owner || '?'}:${o.el}`), caps: open.caps.slice(0, 3) }, null, 1));
  console.log(`CAPS  ${open.caps.length} measured · clipped=${open.caps.filter((c) => c.clippedBy).length} · outsideKey=${open.caps.filter((c) => !c.inKey).length} · minKeyH=${Math.min(...open.caps.map((c) => c.keyH))} · minLabelH=${Math.min(...open.caps.map((c) => c.labelH))}`);
  await shot('open');

  if (!open.osk) fail.push('the keyboard did not open');
  else {
    if (open.osk.inStage) fail.push('the keyboard opened INSIDE .landing-stage');
    if (open.osk.rect.y < open.stage.b - 1) fail.push(`the keyboard is not below the stage (top ${open.osk.rect.y} < stage bottom ${open.stage.b})`);
  }
  // The guest must keep its size — this is the "crushed into a slit" defect.
  if (open.picture && closed.picture) {
    const shrank = closed.picture.h - open.picture.h;
    if (shrank > 2) fail.push(`opening the keyboard shrank the picture by ${shrank.toFixed(1)}px (${closed.picture.h} → ${open.picture.h})`);
  }
  const overOpen = open.over.filter((o) => !allowed(o));
  if (overOpen.length) fail.push(`with the keyboard open, ${overOpen.length} element(s) paint over the picture: ${overOpen.map((p) => `${p.owner || '?'}:${p.el}`).join(' | ')}`);
  // Keycap legibility, as geometry.
  if (!open.caps.length) fail.push('no keycap labels measured at all');
  const clipped = open.caps.filter((c) => c.clippedBy || !c.inKey);
  if (clipped.length) fail.push(`${clipped.length}/${open.caps.length} keycap labels are clipped: e.g. ${JSON.stringify(clipped[0])}`);
  const tiny = open.caps.filter((c) => c.labelH < 6 || c.fontPx < 8);
  if (tiny.length) fail.push(`${tiny.length} keycap labels are too small to read: ${JSON.stringify(tiny[0])}`);
  const squashed = open.caps.filter((c) => c.keyH < 24);
  if (squashed.length) fail.push(`${squashed.length} keys are squashed below 24px tall (min ${Math.min(...open.caps.map((c) => c.keyH))})`);

  // WHICH change fixed the keycaps? Put the old shrinking rows back, in the
  // page, and measure again. If the labels stay legible with the rows able to
  // collapse, then moving the keyboard out of the height-clamped canvas was the
  // whole story and the `flex: 0 0 auto` guard is belt-and-braces for a short
  // viewport in the full station view — which is a claim worth checking rather
  // than asserting.
  await page.addStyleTag({ content: '.osk-row, .osk-qrow { flex: 0 1 auto !important; }' });
  await page.waitForTimeout(400);
  const ab = await measure();
  console.log(`AB    rows-allowed-to-shrink: clipped=${ab.caps.filter((c) => c.clippedBy).length}/${ab.caps.length} minRowH=${Math.min(...ab.caps.map((c) => c.rowH))} minKeyH=${Math.min(...ab.caps.map((c) => c.keyH))}`);
}

console.log(`\nSHOTS ${JSON.stringify(shots)}`);
console.log('ERRORS', JSON.stringify(errors.slice(0, 6)));
await browser.close();
if (errors.length) fail.push(`${errors.length} console/page error(s)`);
console.log(fail.length ? `FAIL ${TAG} ${JSON.stringify(fail, null, 1)}` : `PASS ${TAG}`);
process.exit(fail.length ? 1 : 0);

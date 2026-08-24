// rel-tap-probe — sniff what the SPA actually PUTS ON THE WIRE when a finger
// glides and then taps a RELATIVE-pointer station. The bug under test: the first
// button after a reload carried an absolute (0,0), which the daemon's abs->rel
// bridge honoured by pinning the guest cursor to the top-left corner.
//
//   node rel-tap-wire-probe.mjs <baseUrl> <station>
//   node rel-tap-wire-probe.mjs https://<lab>:8443/staging/<session> rhapsody
//
// Run it against the LIVE bundle and against a stage.sh slot to get a before/
// after pair on the same station in the same browser.
//
// Hooks WritableStreamDefaultWriter.prototype.write BEFORE any app code runs, so
// every input record (framed reliable button records and raw datagrams alike) is
// captured as bytes rather than inferred from behaviour.
import { chromium } from 'playwright';

// Placeholder per the repo's address rule: the real host comes from LAB_HOST.
const BASE = process.argv[2]
  || process.env.GALLERY_URL
  || `https://${process.env.LAB_HOST || '192.0.2.10'}:8443`;
const STATION = process.argv[3] || 'rhapsody';
const say = (...a) => console.log(...a);

const browser = await chromium.launch({
  headless: false, channel: 'chrome',
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--ignore-certificate-errors'],
  env: { ...process.env, DISPLAY: ':1' },
});
const ctx = await browser.newContext({ ignoreHTTPSErrors: true, hasTouch: true, viewport: { width: 1280, height: 800 } });
await ctx.addInitScript(() => {
  const w = globalThis.__wire = [];
  const proto = WritableStreamDefaultWriter.prototype;
  const orig = proto.write;
  proto.write = function (chunk) {
    try {
      if (chunk instanceof Uint8Array && chunk.length <= 16) w.push(Array.from(chunk));
      else if (chunk instanceof Uint8Array) globalThis.__big = (globalThis.__big || 0) + 1;
      else globalThis.__other = (globalThis.__other || 0) + 1;
    } catch { /* never break the app */ }
    return orig.call(this, chunk);
  };
});
await ctx.addInitScript(() => {
  const p = globalThis.__ptr = { down: 0, move: 0, types: {} };
  for (const ev of ['pointerdown', 'pointermove', 'pointerup']) {
    window.addEventListener(ev, (e) => {
      if (ev === 'pointerdown') p.down++;
      if (ev === 'pointermove') p.move++;
      p.types[e.pointerType] = (p.types[e.pointerType] || 0) + 1;
    }, true);
  }
});
const page = await ctx.newPage();
page.on('pageerror', (e) => say('[pageerror]', String(e).slice(0, 160)));

const url = `${BASE}/os/${STATION}`;
say('open', url);
await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 });

// Wait for real pixels: a decoding <video> with a size.
const ready = await page.waitForFunction(() => {
  for (const v of document.querySelectorAll('video')) {
    if (v.srcObject && v.readyState >= 2 && v.videoWidth > 0) return { w: v.videoWidth, h: v.videoHeight };
  }
  return null;
}, null, { timeout: 60000 }).then((h) => h.jsonValue()).catch(() => null);
say('stream:', JSON.stringify(ready));
if (!ready) { await browser.close(); process.exit(1); }

const box = await page.evaluate(() => {
  const v = [...document.querySelectorAll('video')].find((e) => e.srcObject);
  const r = v.getBoundingClientRect();
  return { x: r.x, y: r.y, w: r.width, h: r.height };
});
say('stage:', JSON.stringify(box));

// The first-visit touch coachmark covers the stage and swallows contacts.
const got = page.getByRole('button', { name: /got it/i });
if (await got.count().catch(() => 0)) { await got.first().click({ timeout: 5000 }).catch(() => {}); say('coachmark dismissed'); }
await page.waitForTimeout(400);

const cdp = await ctx.newCDPSession(page);
const at = (dx, dy) => [{ x: box.x + box.w / 2 + dx, y: box.y + box.h / 2 + dy, id: 1 }];
const touch = async (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts });

// Reset the capture so only the gesture is measured.
await page.evaluate(() => { globalThis.__wire.length = 0; });

// THE GESTURE THE OPERATOR REPRODUCED WITH: a glide (so the daemon has seen
// plenty of motion), then a still tap.
say('glide…');
await touch('touchStart', at(-120, -60));
for (let i = 1; i <= 40; i++) { await touch('touchMove', at(-120 + i * 5, -60 + i * 2)); await page.waitForTimeout(12); }
await touch('touchEnd', []);
await page.waitForTimeout(500);
say('tap… at', new Date().toISOString());
await touch('touchStart', at(60, 40));
await page.waitForTimeout(60);
await touch('touchEnd', []);
await page.waitForTimeout(900);

const diag = await page.evaluate(() => ({ ptr: globalThis.__ptr, big: globalThis.__big || 0, other: globalThis.__other || 0, wire: globalThis.__wire.length }));
say('diag:', JSON.stringify(diag));
say('tap done at', new Date().toISOString());
const wire = await page.evaluate(() => globalThis.__wire);
const dg = { 1: 0, 4: 0, 7: 0 };
const buttons = [];
for (const r of wire) {
  // A framed reliable record: u16 length prefix then the self-describing record.
  const framed = r.length >= 3 && (r[0] | (r[1] << 8)) === r.length - 2;
  if (framed && r[2] === 2) {
    const rec = r.slice(2);
    buttons.push(rec.length >= 11
      ? { btn: rec[1], down: !!rec[2], carried: { x: rec[3] | (rec[4] << 8), y: rec[5] | (rec[6] << 8) } }
      : { btn: rec[1], down: !!rec[2], carried: null, bytes: rec.length });
    continue;
  }
  if (!framed && (r[0] === 1 || r[0] === 4 || r[0] === 7)) dg[r[0]]++;
}
say('--- RAW ---');
for (const r of wire) say('  ', JSON.stringify(r));
say('--- WIRE ---');
say(`datagrams: moveAbs(type1)=${dg[1]}  moveRel(type4)=${dg[4]}  rehomeHint(type7)=${dg[7]}`);
say(`button records: ${buttons.length}`);
for (const b of buttons) say('  ', JSON.stringify(b));
const bad = buttons.filter((b) => b.carried && b.carried.x === 0 && b.carried.y === 0);
say(bad.length ? `VERDICT: ${bad.length} button record(s) carry an absolute (0,0)` : 'VERDICT: no button carries an absolute (0,0)');
await page.screenshot({ path: `${process.env.HOME}/e2e/shots/rel-tap-${STATION}-${Date.now()}.png` }).catch(() => {});
await browser.close();

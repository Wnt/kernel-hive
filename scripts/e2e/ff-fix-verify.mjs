// ff-fix-verify.mjs — E2E verification of the Firefox poisoned-session fix.
// Loads the LOCALLY built bundle (serve-dist.mjs), opens a station in Playwright
// Firefox N times, and asserts every session ends up with a FLOWING decode
// (output frames keep growing), counting how many runs needed the watchdog's
// session rebuild (captured from /clientlog POST bodies).
// Usage: node ff-fix-verify.mjs [runs] [origin] [browser]
import { chromium, firefox } from 'playwright';

const RUNS = Number(process.argv[2] || 10);
const ORIGIN = process.argv[3] || 'https://localhost:8543';
const BROWSER = process.argv[4] || 'firefox';
const TILE = process.env.TILE || 'FreeDOS';

const launcher = BROWSER === 'chromium' ? chromium : firefox;
let pass = 0, fail = 0, rebuiltRuns = 0;
for (let run = 1; run <= RUNS; run++) {
  const browser = await launcher.launch(
    BROWSER === 'chromium' ? { headless: true, args: ['--no-sandbox', '--ignore-certificate-errors'] } : { headless: true });
  const page = await browser.newPage({ ignoreHTTPSErrors: true, viewport: { width: 1600, height: 900 } });
  await page.addInitScript(() => {
    window.__vdOut = 0;
    window.__logBodies = [];
    const RealVD = window.VideoDecoder;
    window.VideoDecoder = class extends RealVD {
      constructor(init) {
        super({
          output: (f) => { window.__vdOut++; return init.output(f); },
          error: (e) => init.error(e),
        });
      }
    };
    window.VideoDecoder.isConfigSupported = RealVD.isConfigSupported.bind(RealVD);
    const realFetch = window.fetch.bind(window);
    window.fetch = (url, opts) => {
      try {
        if (String(url).includes('/clientlog') && opts?.body) window.__logBodies.push(String(opts.body));
      } catch { /* noop */ }
      return realFetch(url, opts);
    };
  });
  await page.goto(ORIGIN + '/', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2500);
  const re = new RegExp(TILE, 'i');
  let card = page.locator('button.os-card').filter({ hasText: re }).first();
  if (await card.count() === 0) card = page.getByText(re).first();
  await card.scrollIntoViewIfNeeded();
  const box = await card.boundingBox();
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);

  // Wait up to 20s for a FLOWING decode: >= 30 output frames.
  let outs = 0, flowing = false;
  const t0 = Date.now();
  while (Date.now() - t0 < 20000) {
    await page.waitForTimeout(1000);
    outs = await page.evaluate(() => window.__vdOut);
    if (outs >= 30) { flowing = true; break; }
  }
  // A final growth check: still increasing over the last second?
  const outs2 = await page.evaluate(() => window.__vdOut);
  await page.waitForTimeout(1200);
  const outs3 = await page.evaluate(() => window.__vdOut);
  const logs = await page.evaluate(() => window.__logBodies.join('\n'));
  const rebuilds = (logs.match(/ff-session-rebuild/g) || []).length;
  if (rebuilds > 0) rebuiltRuns++;
  const growing = outs3 > outs2;
  const ok = flowing && growing;
  if (ok) pass++; else fail++;
  console.log(`run ${run}: ${ok ? 'PASS' : 'FAIL'} outputs=${outs3} growing=${growing} rebuild-events=${rebuilds} t=${((Date.now() - t0) / 1000).toFixed(1)}s`);
  if (!ok) {
    const tail = logs.split('\n').slice(-3).join(' | ').slice(0, 600);
    console.log('   clientlog tail:', tail || '(none)');
  }
  await browser.close();
}
console.log(`\n${BROWSER}: ${pass}/${RUNS} PASS (${rebuiltRuns} runs recovered via session rebuild)`);
process.exit(fail ? 1 : 0);

// Deterministic evidence sweep for the registry-driven SceneV2 hall.
// Usage: node hall-parametric-shots.mjs --base http://127.0.0.1:5222 --out DIR
import { chromium } from '@playwright/test';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index >= 0 ? args[index + 1] : fallback;
};
const base = option('base', 'http://127.0.0.1:5222');
const out = option('out', '/tmp/hall-parametric');
const samples = Number(option('samples', '24'));
const only50 = args.includes('--only50');
mkdirSync(out, { recursive: true });

const browser = await chromium.launch({
  channel: 'chrome',
  headless: true,
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--hide-scrollbars'],
});
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
let loadedHallTest = '';
const errors = [];
page.on('pageerror', (error) => errors.push(`pageerror: ${error.message}`));
page.on('console', (message) => {
  if (message.type() === 'error') errors.push(`console: ${message.text()}`);
});

async function capture(query, name, viewport) {
  if (existsSync(`${out}/${name}.png`)) {
    process.stdout.write(`skip ${name}\n`);
    return;
  }
  await page.setViewportSize(viewport);
  const hallTest = new URLSearchParams(query).get('hallTest') ?? '';
  if (hallTest !== loadedHallTest) {
    await page.goto(`${base}/museum?${query}`, { waitUntil: 'load' });
    await page.waitForSelector('canvas');
    await page.waitForTimeout(1100);
    loadedHallTest = hallTest;
  } else {
    await page.evaluate((nextQuery) => {
      window.history.pushState(null, '', `?${nextQuery}`);
      window.dispatchEvent(new PopStateEvent('popstate'));
    }, query);
    await page.waitForTimeout(250);
  }
  const box = await page.locator('canvas').first().boundingBox();
  if (!box) throw new Error('canvas has no bounding box');
  await page.screenshot({
    path: `${out}/${name}.png`,
    clip: box,
    timeout: 120_000,
  });
  process.stdout.write(`${name}\n`);
}

if (!only50) {
  await page.goto(`${base}/museum?hallTest=36`, { waitUntil: 'load' });
  await page.waitForFunction(() => (window.__shots?.length ?? 0) > 0);
  await page.waitForTimeout(1500);
  loadedHallTest = '36';
  const sectionShots = await page.evaluate(
    () => window.__shots.filter((name) => name.startsWith('section-')),
  );
  for (const shot of sectionShots) {
    await capture(`hallTest=36&shot=${shot}`, `36-${shot}`, { width: 1600, height: 1000 });
  }

  for (const viewport of [
    { name: 'desktop', width: 1600, height: 1000 },
    { name: 'portrait', width: 390, height: 844 },
  ]) {
    for (let index = 0; index < samples; index += 1) {
      const railT = index / samples;
      await capture(
        `hallTest=36&railT=${railT.toFixed(6)}`,
        `36-rail-${viewport.name}-${String(index).padStart(2, '0')}`,
        viewport,
      );
    }
  }
}

for (const shot of ['hallWide', 'entrance', 'section-1990s-wide', 'section-2000s-wide']) {
  await capture(`hallTest=50&shot=${shot}`, `50-${shot}`, { width: 1600, height: 1000 });
}

writeFileSync(`${out}/browser-errors.txt`, `${errors.join('\n')}\n`);
await browser.close();
console.log(`done: ${out}; browser errors: ${errors.length}`);

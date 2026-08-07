// scene-shots.mjs — deterministic screenshot harness for the SceneV2 rewrite.
//
// Captures every camera bookmark exposed by spa/src/scene/shots.ts (read off
// the page via window.__shots, so the list lives in one place) from a running
// vite dev server. NOT part of CI — this is the agent/director review loop:
//   cd spa && npm run dev -- --port 5199        (or any port)
//   node tests/e2e-live/scene-shots.mjs [--base http://127.0.0.1:5199] [--out DIR]
// Uses the system Chrome (channel) headless — no playwright browser download.
import { chromium } from '@playwright/test';
import { mkdirSync } from 'fs';

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : dflt;
};
const BASE = opt('base', 'http://127.0.0.1:5199');
const OUT = opt('out', '/tmp/scene-shots');
mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch({
  channel: 'chrome',
  headless: true,
  args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader', '--hide-scrollbars'],
});
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });

await page.goto(`${BASE}/museum`, { waitUntil: 'load' });
const shots = await page.evaluate(() => window.__shots ?? []);
if (!shots.length) {
  console.error('no window.__shots on the page — is the dev server serving the rewrite?');
  process.exit(1);
}
console.log('bookmarks:', shots.join(', '));

for (const name of shots) {
  await page.goto(`${BASE}/museum?shot=${name}`, { waitUntil: 'load' });
  // frameloop="demand": wait for the env map + first renders to settle
  await page.waitForSelector('canvas');
  await page.waitForTimeout(1500);
  const canvas = page.locator('canvas').first();
  await canvas.screenshot({ path: `${OUT}/${name}.png` });
  console.log('shot', name);
}
await browser.close();
console.log('done →', OUT);

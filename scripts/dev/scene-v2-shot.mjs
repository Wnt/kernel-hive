#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const usage = `Usage: scene-v2-shot.mjs <url> <out.png|out-dir> [--w W --h H --patient] [--all-desks] [--resume]

Capture the largest canvas with system Chrome. The page must reach the load
state and expose a non-empty canvas. Three attempts use bounded timeouts and
1s/2s backoff; --patient adds a longer app/canvas settling wait.

--all-desks keeps one browser open, visits every exposed desk front/three4
pin, waits 60s when entering a new section, and writes one PNG per pin to the
output directory. --resume skips desk-pin PNGs already present there.

PLAYWRIGHT_PATH may name a playwright index.mjs when it is not installed under
tests/e2e-live in this worktree/main checkout or ~/e2e.`;

function fail(message, code = 2) {
  console.error(`scene-v2-shot: ${message}`);
  process.exit(code);
}

if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log(usage);
  process.exit(0);
}

const positional = [];
let width = 1920;
let height = 900;
let patient = false;
let allDesks = false;
let resume = false;
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  if (arg === '--patient') patient = true;
  else if (arg === '--all-desks') allDesks = true;
  else if (arg === '--resume') resume = true;
  else if (arg === '--w' || arg === '--h') {
    const value = Number(process.argv[++i]);
    if (!Number.isInteger(value) || value < 64 || value > 10000)
      fail(`${arg} must be an integer from 64 through 10000`);
    if (arg === '--w') width = value;
    else height = value;
  } else if (arg.startsWith('-')) fail(`unknown option: ${arg}`);
  else positional.push(arg);
}
if (positional.length !== 2) fail(usage);
const [url, outputArg] = positional;
try {
  new URL(url);
} catch {
  fail(`invalid URL: ${url}`);
}
const output = resolve(outputArg);
mkdirSync(allDesks ? output : dirname(output), { recursive: true });

function repoRoots() {
  try {
    const root = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      encoding: 'utf8',
    }).trim();
    const common = execFileSync('git', ['rev-parse', '--git-common-dir'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
    return [root, dirname(realpathSync(resolve(root, common)))];
  } catch {
    return [];
  }
}

const candidates = [
  process.env.PLAYWRIGHT_PATH,
  ...repoRoots().map((root) =>
    join(root, 'tests/e2e-live/node_modules/playwright/index.mjs'),
  ),
  join(homedir(), 'e2e/node_modules/playwright/index.mjs'),
].filter(Boolean);
const playwrightPath = candidates.find((candidate) => existsSync(candidate));
if (!playwrightPath)
  fail(`Playwright not found; checked: ${candidates.join(', ')}`);
const { chromium } = await import(pathToFileURL(playwrightPath).href);

const errors = [];
for (let attempt = 1; attempt <= 3; attempt += 1) {
  let browser;
  const pageErrors = [];
  try {
    browser = await chromium.launch({
      channel: 'chrome',
      headless: true,
      args: ['--no-sandbox', '--use-gl=angle', '--use-angle=swiftshader'],
    });
    const page = await browser.newPage({ viewport: { width, height } });
    const timeout = patient ? 75000 : 45000;
    page.setDefaultTimeout(timeout);
    page.on('pageerror', (error) => pageErrors.push(error.message));
    page.on('requestfailed', (request) => {
      console.warn(
        `scene-v2-shot: request failed ${request.url()} (${request.failure()?.errorText ?? 'unknown'})`,
      );
    });
    page.on('response', (response) => {
      if (!response.ok()) {
        console.warn(
          `scene-v2-shot: response ${response.status()} ${response.url()}`,
        );
      }
    });
    await page.goto(url, { waitUntil: 'load', timeout });
    await page.waitForFunction(
      () => {
        const canvases = [...document.querySelectorAll('canvas')];
        return (
          document.readyState === 'complete' &&
          canvases.some((canvas) => canvas.width > 1 && canvas.height > 1)
        );
      },
      undefined,
      { timeout },
    );
    if (patient) {
      try {
        await page.waitForFunction(
          () => !document.querySelector('.scene-v2-loading'),
          undefined,
          { timeout: 60000 },
        );
      } catch (error) {
        if (error.name !== 'TimeoutError') throw error;
        console.warn(
          'scene-v2-shot: loading toast remained after 60s; capturing as-is',
        );
      }
      await page.waitForTimeout(2000);
    } else {
      await page.waitForTimeout(2000);
    }
    if (allDesks) {
      const deskPins = await page.evaluate(() => {
        const debugWindow = window;
        const desks = debugWindow.__museumExhibitDebug?.() ?? [];
        const names = new Set(debugWindow.__shots ?? []);
        return desks.flatMap((desk) => {
          const prefix = `desk-${desk.id}`;
          return ['front', 'three4']
            .map((view) => ({
              name: `${prefix}-${view}`,
              sectionKey: desk.sectionKey,
            }))
            .filter(({ name }) => names.has(name));
        });
      });
      if (deskPins.length === 0) {
        throw new Error('page exposed no generated desk inspection pins');
      }
      const initialShot = new URL(url).searchParams.get('shot');
      const initialSection = deskPins.find(({ name }) => name === initialShot)?.sectionKey;
      const readySections = new Set(initialSection ? [initialSection] : []);
      for (const pin of deskPins) {
        const target = join(output, `${pin.name}.png`);
        if (resume && existsSync(target)) {
          console.log(`scene-v2-shot: keeping ${target} (${pin.name})`);
          continue;
        }
        await page.evaluate((name) => {
          const next = new URL(window.location.href);
          next.searchParams.set('shot', name);
          window.history.pushState({}, '', next);
          window.dispatchEvent(new PopStateEvent('popstate'));
        }, pin.name);
        if (!readySections.has(pin.sectionKey)) {
          await page.waitForTimeout(60000);
          readySections.add(pin.sectionKey);
        } else {
          await page.waitForTimeout(2000);
        }
        const bounds = await page.locator('canvas').first().boundingBox();
        if (!bounds || bounds.width < 2 || bounds.height < 2) {
          throw new Error(`canvas has no capture bounds at ${pin.name}`);
        }
        await page.screenshot({
          path: target,
          clip: {
            x: Math.max(0, bounds.x),
            y: Math.max(0, bounds.y),
            width: Math.min(width, bounds.width),
            height: Math.min(height, bounds.height),
          },
          timeout,
        });
        console.log(`scene-v2-shot: saved ${target} (${pin.name})`);
      }
      await browser.close();
      console.log(`scene-v2-shot: saved ${deskPins.length} desk inspection pins`);
      process.exit(0);
    }
    const handle = await page.evaluateHandle(
      () =>
        [...document.querySelectorAll('canvas')].sort(
          (a, b) => b.width * b.height - a.width * a.height,
        )[0],
    );
    const canvas = handle.asElement();
    if (!canvas) throw new Error('largest canvas disappeared before capture');
    const bounds = await canvas.boundingBox();
    if (!bounds || bounds.width < 2 || bounds.height < 2)
      throw new Error('largest canvas has no capture bounds');
    // Capture the known viewport clip directly. Element screenshots wait for
    // layout stability and can time out on an intentionally animated WebGL
    // canvas even though its bounds are fixed and it is ready to photograph.
    await page.screenshot({
      path: output,
      clip: {
        x: Math.max(0, bounds.x),
        y: Math.max(0, bounds.y),
        width: Math.min(width, bounds.width),
        height: Math.min(height, bounds.height),
      },
      timeout,
    });
    const size = await canvas.evaluate((element) => ({
      width: element.width,
      height: element.height,
    }));
    await browser.close();
    console.log(
      `scene-v2-shot: saved ${output} (${size.width}x${size.height}, attempt ${attempt})`,
    );
    process.exit(0);
  } catch (error) {
    const detail = pageErrors.length
      ? `; page errors: ${pageErrors.slice(-3).join('; ')}`
      : '';
    errors.push(`attempt ${attempt}: ${error.message}${detail}`);
    if (browser) await browser.close().catch(() => {});
    if (attempt < 3)
      await new Promise((done) => setTimeout(done, attempt * 1000));
  }
}
fail(`capture failed after 3 attempts\n${errors.join('\n')}`, 1);

#!/usr/bin/env node
// Standing SceneV2 visual QA lap. This intentionally composes the guarded
// scripts/dev toolbox instead of owning browser/server/capture ceremony here.
// Produces rail/section/lineup contact sheets for human review; it does not
// run an automated visual judge.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PORT = 5238;
const DEFAULT_SAMPLES = 12;
const VIEWPORTS = [
  { name: 'desktop', width: 1600, height: 1000 },
  { name: 'portrait', width: 390, height: 844 },
];
const LINEUP_MODELS = ['c64A', 'paramTower', 'paramCrt', 'terminalC', 'phoneC'];
const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, '../..');
const tools = {
  server: join(repoRoot, 'scripts/dev/scene-v2-server.sh'),
  shot: join(repoRoot, 'scripts/dev/scene-v2-shot.mjs'),
  sheet: join(repoRoot, 'scripts/dev/image-sheet.sh'),
};

const usage = `Usage: node tests/e2e-live/qa-lap.mjs [--out DIR] [--samples N]

Run the standing SceneV2 composition/coverage capture lap on port ${PORT} and
write contact sheets for human review.
Artifacts default to a timestamped directory under /tmp/osgallery-qa-lap.
The rail sweep defaults to ${DEFAULT_SAMPLES} evenly spaced stops per viewport.`;

function fail(message, exitCode = 1) {
  const error = new Error(message);
  error.exitCode = exitCode;
  throw error;
}

function parseArgs(argv) {
  let out;
  let samples = DEFAULT_SAMPLES;
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--help' || arg === '-h') {
      console.log(usage);
      process.exit(0);
    }
    if (arg !== '--out' && arg !== '--samples') fail(`unknown option: ${arg}`, 2);
    const value = argv[++index];
    if (!value) fail(`missing value for ${arg}`, 2);
    if (arg === '--out') out = resolve(value);
    else {
      samples = Number(value);
      if (!Number.isInteger(samples) || samples < 4 || samples > 48) {
        fail('--samples must be an integer from 4 through 48', 2);
      }
    }
  }
  const stamp = new Date().toISOString().replaceAll(':', '').replace(/\.\d{3}Z$/, 'Z');
  return {
    out: out ?? `/tmp/osgallery-qa-lap/${stamp}-${process.pid}`,
    samples,
  };
}

function run(command, args, options = {}) {
  console.log(`qa-lap: ${options.label ?? command}`);
  const result = spawnSync(command, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    env: { ...process.env, ...options.env },
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  return result;
}

function requireRun(command, args, options) {
  const result = run(command, args, options);
  if (result.error) fail(`${options.label}: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`${options.label} exited ${result.status ?? `on ${result.signal}`}`);
  }
  return result;
}

function relativeToOut(out, path) {
  return relative(out, path);
}

// The registry aggregate is rendered on demand, not committed — ask for it.
function decadesFromRegistry() {
  const result = spawnSync(
    'python3',
    [join(repoRoot, 'scripts/tiles-registry.py'), 'emit', 'index.json'],
    { cwd: repoRoot, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  );
  if (result.status !== 0) fail(`tiles-registry.py emit index.json failed: ${result.stderr ?? ''}`);
  const registry = JSON.parse(result.stdout);
  const decades = registry.tiles
    .filter((tile) => tile.enabled !== false)
    .map((tile) => Math.floor(tile.era_year / 10) * 10);
  return [...new Set(decades)].sort((a, b) => a - b);
}

function queryUrl(baseUrl, entries) {
  return `${baseUrl}/museum?${new URLSearchParams(entries)}`;
}

const { out, samples } = parseArgs(process.argv.slice(2));
if (existsSync(out) && readdirSync(out).length > 0) {
  fail(`output directory must be absent or empty: ${out}`, 2);
}
mkdirSync(out, { recursive: true });

const startedAt = new Date().toISOString();
const baseUrl = `http://127.0.0.1:${PORT}`;
const decades = decadesFromRegistry();
const capturesDir = join(out, 'captures');
const sheetsDir = join(out, 'contact-sheets');
const verdictPath = join(out, 'qa-lap-verdict.json');
mkdirSync(capturesDir, { recursive: true });
mkdirSync(sheetsDir, { recursive: true });

let stage = 'server-start';
let serverStarted = false;
let exitCode = 0;
let failure;
let failureStage;
let contactSheets = {};
const railShots = {};
const sectionShots = [];
const lineupShots = [];

function stopServer(label) {
  if (!serverStarted) return { status: 0 };
  const result = run(tools.server, ['stop', String(PORT)], { label });
  serverStarted = false;
  return result;
}

for (const [signal, exitCodeForSignal] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.once(signal, () => {
    stopServer(`stop SceneV2 server on ${PORT} after ${signal}`);
    process.exit(exitCodeForSignal);
  });
}

function capture(url, path, viewport) {
  requireRun(
    tools.shot,
    [url, path, '--w', String(viewport.width), '--h', String(viewport.height), '--patient'],
    { label: `capture ${relativeToOut(out, path)}` },
  );
}

function makeSheet(name, images) {
  const path = join(sheetsDir, `${name}.png`);
  requireRun(tools.sheet, [path, ...images, '--labels'], {
    label: `contact sheet ${name}`,
  });
  return path;
}

try {
  // Mark the lifecycle as ours before start so a partial bootstrap still gets
  // a pidfile-only cleanup attempt.
  serverStarted = true;
  requireRun(tools.server, ['start', String(PORT)], {
    label: `start SceneV2 server on ${PORT}`,
  });

  stage = 'rail-captures';
  for (const viewport of VIEWPORTS) {
    railShots[viewport.name] = [];
    for (let index = 0; index < samples; index += 1) {
      const railT = (index / samples).toFixed(6);
      const name = `rail-${viewport.name}-${String(index).padStart(2, '0')}-t${railT}`;
      const path = join(capturesDir, `${name}.png`);
      capture(queryUrl(baseUrl, { railT }), path, viewport);
      railShots[viewport.name].push(path);
    }
    contactSheets[`${viewport.name}Rail`] = makeSheet(
      `rail-${viewport.name}`,
      railShots[viewport.name],
    );
  }

  stage = 'section-captures';
  for (const decade of decades) {
    const name = `section-${decade}s-wide`;
    const path = join(capturesDir, `${name}.png`);
    capture(
      queryUrl(baseUrl, { shot: name }),
      path,
      VIEWPORTS[0],
    );
    sectionShots.push(path);
  }
  contactSheets.sections = makeSheet('sections-by-decade', sectionShots);

  stage = 'lineup-captures';
  for (const model of LINEUP_MODELS) {
    const path = join(capturesDir, `lineup-${model}.png`);
    capture(
      queryUrl(baseUrl, { lineup: model, shot: 'lineupOne' }),
      path,
      VIEWPORTS[0],
    );
    lineupShots.push(path);
  }
  contactSheets.lineup = makeSheet('lineup-five-model-sweep', lineupShots);
} catch (error) {
  failure = error instanceof Error ? error.message : String(error);
  failureStage = stage;
  exitCode = error.exitCode ?? 1;
} finally {
  stage = 'server-stop';
  if (serverStarted) {
    const stopped = stopServer(`stop SceneV2 server on ${PORT}`);
    if (stopped.status !== 0) {
      failure = [failure, `server stop exited ${stopped.status ?? stopped.signal}`]
        .filter(Boolean)
        .join('; ');
      failureStage ??= stage;
      exitCode ||= 1;
    }
  }
}

const verdict = failure ? 'UNKNOWN' : 'CAPTURED';
const artifactList = (paths) => paths.map((path) => relativeToOut(out, path));
const report = {
  schemaVersion: 1,
  verdict,
  startedAt,
  completedAt: new Date().toISOString(),
  baseUrl,
  port: PORT,
  railSamplesPerViewport: samples,
  viewports: VIEWPORTS,
  decades,
  lineupModels: LINEUP_MODELS,
  artifacts: {
    contactSheets: Object.fromEntries(
      Object.entries(contactSheets).map(([key, path]) => [key, relativeToOut(out, path)]),
    ),
    railShots: Object.fromEntries(
      Object.entries(railShots).map(([key, paths]) => [key, artifactList(paths)]),
    ),
    sectionShots: artifactList(sectionShots),
    lineupShots: artifactList(lineupShots),
  },
  failureStage: failureStage ?? null,
  failure: failure ?? null,
};
writeFileSync(verdictPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(`qa-lap: ${verdict}; report ${verdictPath}`);
process.exitCode = exitCode;

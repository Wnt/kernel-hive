#!/usr/bin/env node
// spa-watch.mjs — one-command watch/build/deploy loop for manual UI edits.
//
// Watches spa/src. On any change: `npm run build` (tsc -b && vite build) with
// its output streamed straight to this terminal, so compile errors show up
// exactly as tsc/vite print them. Only on a clean build does it deploy via
// `scripts/serve-https-spa.sh deploy` (rsync dist + manifests to the box). No
// hot reload, no dev server — just edit, save, watch this terminal.
import { spawnSync } from 'node:child_process';
import { watch } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const spaDir = path.join(repoRoot, 'spa');
const watchDir = path.join(spaDir, 'src');

const log = (msg) => console.log(`\n[spa-watch] ${msg}`);

let building = false;
let rerunPending = false;
let debounceTimer = null;

function run(cmd, args, cwd) {
  const result = spawnSync(cmd, args, { cwd, stdio: 'inherit' });
  return result.status === 0;
}

function buildAndDeploy() {
  if (building) {
    rerunPending = true;
    return;
  }
  building = true;
  rerunPending = false;

  log('building…');
  const built = run('npm', ['run', 'build'], spaDir);
  if (!built) {
    log('BUILD FAILED — fix the error above and save again.');
  } else {
    log('build OK, deploying…');
    const deployed = run('./scripts/serve-https-spa.sh', ['deploy'], repoRoot);
    log(deployed ? 'deployed.' : 'DEPLOY FAILED — see output above.');
  }

  building = false;
  if (rerunPending) buildAndDeploy();
  else log(`watching ${path.relative(repoRoot, watchDir)} for changes… (Ctrl+C to stop)`);
}

function onChange() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(buildAndDeploy, 400);
}

watch(watchDir, { recursive: true }, onChange);
log(`watching ${path.relative(repoRoot, watchDir)} for changes…`);
buildAndDeploy();

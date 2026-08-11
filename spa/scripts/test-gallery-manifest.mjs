import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, readdir } from 'node:fs/promises';
import { loadGalleryManifest, validateGalleryManifest } from '../src/data/galleryManifest.ts';

// The public lineup is RENDERED from registry/tiles/*.json, never committed, so
// this check renders it here and validates those exact bytes — the document the
// box will be handed, not a copy of it that could have gone stale in the tree.
const rendered = execFileSync(
  'python3',
  ['scripts/stations-registry.py', 'emit', 'gallery-manifest.json'],
  { cwd: new URL('../../', import.meta.url), maxBuffer: 32 * 1024 * 1024 },
);
const source = JSON.parse(rendered.toString('utf8'));
const validated = validateGalleryManifest(source);
assert(validated, 'generated gallery manifest must validate');
assert.equal(validated.entries.length, source.entries.length);
assert.equal(validated.entries.find((entry) => entry.id === 'c64')?.year, 1982);
assert.equal(validated.entries.find((entry) => entry.id === 'c64')?.eraLabel, '1982 · C64 + GEOS');

const duplicateOrder = structuredClone(source);
duplicateOrder.entries[1].order = duplicateOrder.entries[0].order;
assert.equal(
  validateGalleryManifest(duplicateOrder),
  null,
  'duplicate gallery order must fail validation',
);

const forbidden = /(?:credential|password|secret|token|login)/i;
function assertPublic(value, path = '$') {
  if (Array.isArray(value)) return value.forEach((item, index) => assertPublic(item, `${path}[${index}]`));
  if (!value || typeof value !== 'object') return;
  for (const [key, child] of Object.entries(value)) {
    assert(!forbidden.test(key), `public manifest contains forbidden field ${path}.${key}`);
    assertPublic(child, `${path}.${key}`);
  }
}
assertPublic(source);

const changed = structuredClone(source);
changed.entries.push({
  id: 'manifest-only-proof',
  era_year: 2099,
  displayName: 'Manifest-only proof tile',
  year: 2099,
  lineage: 'Runtime test',
  arch: 'x86_64',
  accent: '#123456',
  archetypeId: 'beige-tower-crt',
  transport: 'showcase',
  order: 999,
  eraLabel: '2099 · Runtime test',
  signalEndpoint: null,
  era: '2090s',
  eraSoftware: [],
  periodBrowser: '—',
  iconicApps: [],
  blurb: 'This row exists only in the fetched JSON.',
});

let request;
const runtimeRows = await loadGalleryManifest(async (input, init) => {
  request = { input, init };
  return new Response(JSON.stringify(changed), { status: 200 });
});
assert.equal(request.input, '/gallery-manifest.json');
assert.equal(request.init.cache, 'no-cache');
assert(runtimeRows.some((entry) => entry.id === 'manifest-only-proof'), 'fetched-only row must enter lineup');

// No bundled lineup to fall back on: a failed fetch or a rejected document must
// yield an EMPTY gallery, loudly, rather than a stale one that looks fine.
const errors = [];
const originalError = console.error;
console.error = (message) => errors.push(String(message));
try {
  const missingRows = await loadGalleryManifest(async () => new Response('not found', { status: 404 }));
  assert.deepEqual(missingRows, [], '404 must yield an empty lineup');

  const invalid = structuredClone(source);
  invalid.entries[0].password = 'must never be accepted';
  const invalidRows = await loadGalleryManifest(async () => new Response(JSON.stringify(invalid), { status: 200 }));
  assert.deepEqual(invalidRows, [], 'invalid shape must yield an empty lineup');
} finally {
  console.error = originalError;
}
assert.equal(errors.length, 2, 'a missing lineup must emit visible telemetry');

if (process.argv.includes('--built')) {
  const assetsDir = new URL('../dist/assets/', import.meta.url);
  const scripts = (await readdir(assetsDir)).filter((name) => name.endsWith('.js'));
  const bundle = (await Promise.all(scripts.map((name) => readFile(new URL(name, assetsDir), 'utf8')))).join('\n');
  assert(bundle.includes('gallery-manifest.json'), 'built app must fetch the runtime manifest endpoint');
  assert(!bundle.includes('manifest-only-proof'), 'runtime-only proof row must not be compiled into the bundle');
  // The lineup is fetched, not bundled: no museum copy may be compiled in.
  const sample = source.entries.find((entry) => entry.blurb)?.blurb;
  assert(sample, 'rendered manifest must carry blurbs to test against');
  assert(!bundle.includes(sample), 'museum copy must not be compiled into the bundle');
}

console.log('gallery-manifest: rendered document, duplicate-order rejection, runtime override, empty-on-failure PASS');

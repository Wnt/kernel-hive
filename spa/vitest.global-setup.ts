import { execFileSync } from 'node:child_process';

// The public lineup is rendered from registry/tiles/*.json on demand and never
// committed, so the suite renders it once here and hands the document to every
// test that needs a real lineup (see src/data/lineupFixture.ts). Nothing in the
// SPA's build, lint or type gates depends on it existing — only the tests do,
// and they get bytes that are current by construction.
type Project = { provide: (key: 'galleryManifest', value: unknown) => void };

export default function setup(project: Project) {
  const rendered = execFileSync(
    'python3',
    ['scripts/stations-registry.py', 'emit', 'gallery-manifest.json'],
    { cwd: new URL('../', import.meta.url), maxBuffer: 32 * 1024 * 1024 },
  );
  project.provide('galleryManifest', JSON.parse(rendered.toString('utf8')));
}

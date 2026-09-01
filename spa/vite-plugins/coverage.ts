// ============================================================================
//  vite-plugins/coverage — the SECOND bundle, and why it is not the first.
//  ---------------------------------------------------------------------------
//  `docs/ANALYTICS.md` §6 asks a question the probe catalogue cannot: not
//  "was this FEATURE reached" but "did this LINE ever run in production".
//  Answering it means shipping an istanbul-instrumented bundle, which is a real
//  cost (bigger, slower, and carrying a counter array the gallery does not
//  need), so it is a SECOND artefact and never the one that ships by default.
//
//  THE ARMING STRING IS DELIBERATELY NOT A BOOLEAN. `VITE_KH_COVERAGE=1` is a
//  value somebody sets by accident — a leftover export, a CI matrix cell, a
//  copied .env line — and an accidentally instrumented gallery is a silent 40%
//  regression nobody would look for. It must equal `instrument-this-build`
//  exactly, a string that only appears in `npm run build:coverage` and in this
//  file. Anything else, including `1` and `true`, builds the normal bundle.
//
//  THE DEFAULT BUNDLE MUST BE BYTE-IDENTICAL. That is why this plugin also owns
//  the ONLY import of `src/analytics/coverage.ts`: it injects it into main.tsx
//  during the instrumented build instead of main.tsx importing it and testing a
//  flag at runtime. A guarded import still ships the module, and "byte-
//  identical" then quietly becomes "identical apart from the part I added".
// ============================================================================

import { createHash } from 'node:crypto';
import type { Plugin } from 'vite';
import istanbul from 'vite-plugin-istanbul';

/** The exact value of VITE_KH_COVERAGE that arms instrumentation. */
export const ARMED = 'instrument-this-build';

/** Modules deliberately NOT instrumented, each for a reason that would show up
 *  as a lie in the report rather than as a missing row:
 *   - the two codegen outputs are data tables; "lines never executed" in a
 *     generated lookup is a fact about the generator, not about the gallery.
 *   - the analytics plane instruments itself if allowed to, so the collector
 *     would report its own send path as covered on every session and the sink
 *     as covered on any session that flushed. Measuring the measurer's uptime
 *     is not the question. */
const NOT_INSTRUMENTED = [
  'src/data/museumCatalog.ts',
  'src/three/archetypeRegistry.ts',
  'src/analytics/**',
  '**/*.test.ts',
];

/** Short, stable id for one instrumented build. Statement line numbers only
 *  mean anything against the build that produced them, so every stored map is
 *  keyed by this and maps from different builds are NEVER unioned. */
function buildId(): string {
  const seed = [
    process.env.KH_COVERAGE_BUILD_ID ?? '',
    process.env.GIT_COMMIT ?? '',
    process.env.VITE_BASE ?? '/',
  ].join('|');
  return createHash('sha256').update(seed || String(Date.now())).digest('hex').slice(0, 12);
}

/** True when this build is the instrumented one. */
export function coverageArmed(): boolean {
  return process.env.VITE_KH_COVERAGE === ARMED;
}

/** The instrumentation plugins, or nothing at all. Returning `[]` — rather than
 *  a plugin that decides at runtime — is what keeps the default output byte-
 *  identical: an inert plugin still perturbs module ordering and `define`. */
export function coveragePlugins(): Plugin[] {
  if (!coverageArmed()) return [];
  const id = buildId();
  // eslint-disable-next-line no-console -- an instrumented bundle must announce itself
  console.warn(`[kh-coverage] INSTRUMENTED BUILD ${id} — do not deploy this as the gallery`);
  return [
    injectCollector(id),
    istanbul({
      include: ['src/**/*.ts', 'src/**/*.tsx'],
      exclude: NOT_INSTRUMENTED,
      extension: ['.ts', '.tsx'],
      requireEnv: false,
      forceBuildInstrument: true,
    }) as Plugin,
  ];
}

/** Prepend the collector's import to the entry module, and hand it the build
 *  id. `enforce: 'pre'` so this runs before the istanbul transform sees the
 *  file — the injected line is one import and instrumenting it would put a
 *  statement counter on the collector's own arrival. */
function injectCollector(id: string): Plugin {
  return {
    name: 'kernel-hive-coverage-collector',
    enforce: 'pre',
    transform(code, moduleId) {
      if (!moduleId.endsWith('/src/main.tsx')) return null;
      return {
        code: `import { installCoverageReporter } from './analytics/coverage';\n`
          + `installCoverageReporter(${JSON.stringify(id)});\n${code}`,
        map: null,
      };
    },
  };
}

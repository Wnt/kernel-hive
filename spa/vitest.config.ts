import { defineConfig } from 'vitest/config';

// Unit-test config for the SPA's PURE-LOGIC modules only (parsers/adapters/
// state helpers) — the three.js/DOM-heavy modules (streamClient.ts,
// StreamView.tsx, the R3F SceneV2 graph, …) are out of scope here;
// see docs/history/TECH-DEBT-INVENTORY.md item 14. Tests run under plain Node
// (no jsdom) since none of the covered modules touch window/document.
//
// The coverage gate is PER-FILE (thresholds.perFile) so one thoroughly-tested
// module can't paper over a thin one — every file named in `include` below
// must individually clear 50% statement coverage. Everything else in src/ is
// deliberately excluded; see coverage-exclusions.json for the written reason
// per excluded module.
export default defineConfig({
  test: {
    environment: 'node',
    // Renders the public lineup from the registry and provides it to the tests
    // that need one; nothing is read from the tree (see vitest.global-setup.ts).
    globalSetup: ['./vitest.global-setup.ts'],
    include: ['src/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      // 'json' is what scripts/dev/reach-report.py reads to put a cov% beside
      // each probe's owner file — the axis that turns feature reach into a
      // keep/test/delete decision instead of a popularity list.
      reporter: ['text', 'html', 'json'],
      include: [
        'src/admin/observability/reportMath.ts',
        'src/admin/observability/traceFilters.ts',
        'src/analytics/catalogue/fleet.ts',
        'src/analytics/catalogue/index.ts',
        'src/analytics/catalogue/station.ts',
        'src/analytics/catalogue/types.ts',
        'src/analytics/catalogue/walkin.ts',
        'src/analytics/coverage.ts',
        'src/analytics/errors.ts',
        'src/analytics/flows.ts',
        'src/analytics/index.ts',
        'src/analytics/intent.ts',
        'src/analytics/metrics.ts',
        'src/data/galleryManifest.ts',
        'src/input/moveSamples.ts',
        'src/scene/hallEngagement.ts',
        'src/scene/progressiveLoading.ts',
        'src/three/annexb.ts',
        'src/three/guestQuirks.ts',
        'src/three/streamClient/auGate.ts',
        'src/three/streamClient/format.ts',
        'src/three/streamClient/scoring.ts',
        'src/three/streamSignal.ts',
        'src/ui/fleetFindEpisode.ts',
        'src/ui/grid/letterbox.ts',
        'src/ui/grid/thumbVtt.ts',
        'src/ui/posterReadEpisode.ts',
      ],
      thresholds: {
        perFile: true,
        statements: 50,
      },
    },
  },
});

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
    include: ['src/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: [
        'src/data/catalog.ts',
        'src/data/galleryManifest.ts',
        'src/input/moveSamples.ts',
        'src/scene/progressiveLoading.ts',
        'src/three/annexb.ts',
        'src/three/guestQuirks.ts',
        'src/three/streamClient/auGate.ts',
        'src/three/streamClient/format.ts',
        'src/three/streamClient/scoring.ts',
        'src/three/streamSignal.ts',
        'src/ui/grid/letterbox.ts',
        'src/ui/grid/thumbVtt.ts',
      ],
      thresholds: {
        perFile: true,
        statements: 50,
      },
    },
  },
});

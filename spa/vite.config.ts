import { execFileSync } from 'node:child_process';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { coveragePlugins } from './vite-plugins/coverage';

// `npm run dev` has no box behind it, so nothing would answer the app's fetches
// for the runtime documents (Vite's history fallback hands back index.html) and
// the grid would come up empty with no poster prose. Render them from the
// registry per request instead: the dev gallery shows the CURRENT
// registry/stations/*.json and registry/posters/*.md — save the file, reload the
// tab — with no bundled copy to go stale and no generated file in the tree. On
// the box the same bytes arrive the other way, published by serve-https-spa.sh.
const RUNTIME_DOCUMENTS = ['/gallery-manifest.json', '/poster-docs.json', '/fleet-table.json'];

function registryDocuments(): Plugin {
  return {
    name: 'kernel-hive-registry-documents',
    apply: 'serve',
    configureServer(server) {
      for (const route of RUNTIME_DOCUMENTS) {
        const artifact = route.slice(1);
        server.middlewares.use(route, (_req, res) => {
          try {
            const body = execFileSync(
              'python3',
              ['../scripts/stations-registry.py', 'emit', artifact],
              { cwd: import.meta.dirname, maxBuffer: 32 * 1024 * 1024 },
            );
            res.setHeader('Content-Type', 'application/json');
            res.end(body);
          } catch (error) {
            // A registry that does not validate must fail visibly here, with
            // the validator's own words, rather than serving a half-built page.
            const reason = error instanceof Error ? error.message : String(error);
            server.config.logger.error(`[registry-documents] ${artifact}: ${reason}`);
            res.statusCode = 500;
            res.end(JSON.stringify({ error: `${artifact} render failed`, reason }));
          }
        });
      }
    },
  };
}

// A staged UI (scripts/dev/stage.sh) is served under /staging/<session>/ from
// the same origin, so its hashed assets and its two runtime documents resolve
// against that base; the live gallery keeps base '/'.
const BASE = process.env.VITE_BASE ?? '/';

// The build/commit identifier baked into every bundle: analytics/instana.ts's
// `kh.bundle` meta AND three/clientDebug.ts's BUNDLE_MARKER (our own
// /clientlog plane) both read this ONE value, so a beacon in Instana and a
// row in our own clientlog.jsonl name the same build — the whole point of
// running both.
//
// SAME SHAPE `scripts/host/box-install.sh` stamps into `.deployed-rev` and
// `scripts/dev/box-deploy.sh --status` prints: `<branch>@<short-sha>`. An
// operator can diff a beacon's kh.bundle against `box-deploy.sh --status`
// output character-for-character rather than translating between two id
// schemes. SHORT, not full: box-install.sh already made that call (`git
// rev-parse --short HEAD`, git's own auto-disambiguating length) and this
// reuses the identical command, so the two ids are not just the same SHAPE
// but the same VALUE for a checkout at the same commit.
//
// Computed here (not exported from a caller like serve-https-spa.sh) so
// EVERY build path gets it for free — `npm run dev`, `npm run build`,
// stage.sh's staged preview, a contributor's checkout, CI — with no risk of
// one caller forgetting to wire it. A caller MAY still override by exporting
// VITE_KH_BUILD_ID itself (checked first, same "explicit always wins" rule
// registry/local.env's own tooling follows).
//
// DEGRADES HONESTLY: no git, a detached/shallow checkout with no branch name,
// or any git failure yields the literal placeholder below — never a value
// that merely LOOKS like a commit id.
const NO_BUILD_ID = 'unknown-build';
function computeBuildId(): string {
  const override = process.env.VITE_KH_BUILD_ID;
  if (override) return override;
  try {
    const opts = { cwd: import.meta.dirname, stdio: ['ignore', 'pipe', 'ignore'] } as const;
    const run = (args: string[]) => execFileSync('git', args, opts).toString().trim();
    const branch = run(['rev-parse', '--abbrev-ref', 'HEAD']);
    const short = run(['rev-parse', '--short', 'HEAD']);
    if (!branch || branch === 'HEAD' || !short) return NO_BUILD_ID;
    const dirty = run(['status', '--porcelain', '--untracked-files=no']).length > 0;
    return dirty ? `${branch}@${short}-dirty` : `${branch}@${short}`;
  } catch {
    return NO_BUILD_ID;
  }
}
const BUILD_ID = computeBuildId();

export default defineConfig({
  base: BASE,
  // `coveragePlugins()` is [] unless VITE_KH_COVERAGE holds its exact arming
  // string, and an empty spread is not a no-op plugin: it leaves the plugin
  // list, the module graph and the output BYTE-IDENTICAL. That is the whole
  // contract of the instrumented lane — see vite-plugins/coverage.ts.
  plugins: [react(), registryDocuments(), ...coveragePlugins()],
  // Exposed to app code as `import.meta.env.VITE_KH_BUILD_ID` — read by
  // three/clientDebug.ts's BUNDLE_MARKER, the single place both consumers
  // (Instana `meta`, our own /clientlog + snapshot payloads) get it from.
  define: {
    'import.meta.env.VITE_KH_BUILD_ID': JSON.stringify(BUILD_ID),
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: false,
  },
  // es2022 baseline throughout (top-level await etc.) — the gallery already
  // requires WebTransport/WebCodecs-era browsers, so there is nothing to
  // transpile down for.
  oxc: { target: 'es2022' },
  build: {
    target: 'es2022',
    // 'hidden': emit a .map file per asset (for Instana's JS-stack-trace
    // translation, uploaded by scripts/serve-https-spa.sh's
    // publish_instana_sourcemaps) WITHOUT writing a `//# sourceMappingURL=`
    // comment into the shipped JS. A browser only ever fetches a source map
    // it was told about, so 'hidden' means the map is never served to a
    // visitor's devtools even though the file sits in dist/ —
    // serve-https-spa.sh's deploy() additionally excludes *.map from what
    // reaches the public webroot, so this is belt-and-braces, not the only
    // guard. See that script for why maps are upload-only, not served.
    sourcemap: 'hidden',
  },
});

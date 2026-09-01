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
// Also exported into process.env under its own name, so Vite's SEPARATE
// index.html `%VITE_..%` placeholder mechanism (a plain env-var substitution
// pass, unrelated to the `define` block below which only rewrites
// `import.meta.env.*` inside JS/TS) can see it too. spa/index.html's inline
// bootstrap needs this value for `kh.bundle` — it runs before any bundle
// evaluates, so it cannot read `import.meta.env.VITE_KH_BUILD_ID` the way
// three/clientDebug.ts's BUNDLE_MARKER does. Setting it here, once, keeps
// both readers (the `define` substitution below and index.html's
// placeholder pass) agreeing on the exact same computed value rather than
// each deriving it — same principle as the git-computed value only being
// computed once above.
process.env.VITE_KH_BUILD_ID = BUILD_ID;

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
    // true: emit a .map file per asset AND write a `//# sourceMappingURL=`
    // comment into the shipped JS, so both consumers work:
    //  - a human with devtools open on the public gallery can resolve a
    //    minified frame back to real source, same as any other public site;
    //  - Instana's stack-trace translation still gets its own copy via
    //    scripts/serve-https-spa.sh's publish_instana_sourcemaps, uploaded
    //    straight to Instana's private store rather than relying on its
    //    crawler to fetch the map from us.
    // The maps are public on purpose: the built bundle already ships
    // unauthenticated (only the app shell at '/' is passkey-gated — see
    // docs/PUBLIC-GALLERY.md and serve-https-spa.sh's deploy()), and the
    // source itself is the openly-public kernel-hive GitHub repo, so a map
    // reveals nothing the repo doesn't already. A .map is fetched only when
    // a visitor's devtools is open, so it costs nothing for an ordinary
    // visit. See serve-https-spa.sh's deploy() and publish_instana_sourcemaps
    // for the full reasoning and why BOTH delivery paths are kept.
    sourcemap: true,
  },
});

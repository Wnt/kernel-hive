import { execFileSync } from 'node:child_process';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

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

export default defineConfig({
  base: BASE,
  plugins: [react(), registryDocuments()],
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: false,
  },
  // es2022 baseline throughout (top-level await etc.) — the gallery already
  // requires WebTransport/WebCodecs-era browsers, so there is nothing to
  // transpile down for.
  oxc: { target: 'es2022' },
  build: { target: 'es2022' },
});

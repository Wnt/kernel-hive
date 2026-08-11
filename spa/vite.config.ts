import { execFileSync } from 'node:child_process';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// `npm run dev` has no box behind it, so nothing would answer the SPA's
// /gallery-manifest.json fetch (Vite's history fallback hands back index.html)
// and the grid would come up empty. Render it from the registry on every
// request instead: the dev gallery then shows the CURRENT registry/tiles/*.json
// — save the file, reload the tab — with no bundled copy to go stale and no
// generated file to keep in the tree. On the box the same bytes arrive the
// other way, published to the webroot by serve-https-spa.sh.
function registryManifest(): Plugin {
  return {
    name: 'kernel-hive-registry-manifest',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/gallery-manifest.json', (_req, res) => {
        try {
          const body = execFileSync(
            'python3',
            ['../scripts/tiles-registry.py', 'emit', 'gallery-manifest.json'],
            { cwd: import.meta.dirname, maxBuffer: 32 * 1024 * 1024 },
          );
          res.setHeader('Content-Type', 'application/json');
          res.end(body);
        } catch (error) {
          // A registry that does not validate must fail visibly here, with the
          // validator's own words, rather than serving a half-built lineup.
          const reason = error instanceof Error ? error.message : String(error);
          server.config.logger.error(`[registry-manifest] ${reason}`);
          res.statusCode = 500;
          res.end(JSON.stringify({ error: 'gallery manifest render failed', reason }));
        }
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), registryManifest()],
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

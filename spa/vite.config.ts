import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
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

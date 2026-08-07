# spa/ — The Kernel Hive (web app)

The React SPA of the OS gallery: a browsable "living computer museum" where each
exhibit is a retro/exotic OS you can watch and remote-control live. Streams come
from the Rust `streamhost` daemon (one instance per QEMU tile on the lab box)
over WebTransport and are decoded in-browser with WebCodecs. The legacy neko
transport has been removed. Browsers without WebCodecs retain the streamhost
platform WebRTC fallback in `src/three/webRtcFallbackClient.ts`.

Stack: Vite + React + TypeScript, react-three-fiber for the 3D museum, zustand
for state.

## Routes

- `/` — 2D grid of tiles (`src/ui/grid/GridView.tsx`); click a card to open a
  live `StreamView` with full keyboard/mouse control.
- `/os/:osId` — direct link to one tile's stream.
- `/museum` — the registry-driven 3D hall (`src/scene/`): real-scale
  parametric hardware, constrained rail navigation, info cards, focused live
  screens, and click-through into `/os/:osId`.

Rename the museum via `MUSEUM_NAME` in `src/config.ts` — it flows through the
whole UI.

## Develop / build

Prerequisite: Node.js with npm. The repository does not declare an `engines`
range; the fresh-clone path was verified with Node 22 and npm 10.

```bash
cd spa
npm ci
npm run dev        # Vite dev server on :5173
npm run lint       # ESLint (flat config, zero warnings tolerated)
npm run build      # tsc -b && vite build -> dist/
```

`predev`/`prebuild` run `scripts/ensure-credentials.mjs`, which copies
`src/data/credentials.example.ts` → `src/data/credentials.ts` if it is missing,
so a fresh clone builds out of the box. The real `credentials.ts` (per-OS VM
login hints shown by the password panel) is **gitignored — never commit it**;
provide it locally or ship the example placeholders.

The deployed bundle is served by `scripts/serve/osgallery-https-server.py` on
the lab box (`https://192.0.2.10:8443`).

## Data contract

The app consumes a manifest of VMs. Without a live manifest source it falls
back to the bundled mock (`src/mock/manifest.json`) with the identical schema;
placard fields (era software, period browser, iconic apps, blurb) are enriched
from the curated catalog in `src/data/catalog.ts` — real manifest data always
wins.

## Art pipeline

The application icons and retained showcase-poster source art live under
`public/assets/generated/`; its README lists the exact files. The reproducible
bitmap pipeline (poster tone matching and favicon/luma-key export) is
`scripts/process-mj-assets.sh` (+ `scripts/process_mj_assets.py`), reading raw
Midjourney masters from `$MJ_OUTPUT_DIR` (default `spa/mj-output/`, gitignored).

## Testing

Live end-to-end suites (Playwright against the real lab box) live in
`tests/e2e-live/` at the repo root — they are integration tests, not CI tests.

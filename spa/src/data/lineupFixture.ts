// TEST-ONLY. The real public lineup, as rendered from the registry by
// vitest.global-setup.ts — the same bytes the box is handed as
// /gallery-manifest.json.
//
// Tests that need a realistic lineup (hall layout, station kits, hardware
// bindings, soft-hide) used to import a committed copy of this document. There
// is no committed copy any more: the registry entry is the single source, and
// this module is how the suite reads what it renders to. Importing it from app
// code is a build error by construction — it pulls in `vitest`.
import { inject } from 'vitest';

// The document as it comes off the emitter, before validateGalleryManifest maps
// it into RuntimeVMManifestEntry (bootVideo is still a bare string here).
type RenderedEntry = {
  id: string;
  displayName: string;
  era_year: number;
  order: number;
  transport: string;
  [field: string]: unknown;
};

declare module 'vitest' {
  interface ProvidedContext {
    galleryManifest: { schemaVersion: number; entries: RenderedEntry[] };
  }
}

export const renderedManifest = inject('galleryManifest');
export const renderedEntries = renderedManifest.entries;

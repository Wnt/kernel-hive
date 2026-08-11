import { useEffect, useState } from 'react';
import type { PosterDoc } from '../types';

// Runtime poster prose. /poster-docs.json is published to the webroot by
// `serve-https-spa.sh manifests`, so poster copy edits go live on a browser
// refresh with no SPA rebuild. The same generated JSON is bundled as a LAZY
// fallback chunk (dev server, or a webroot that predates the file) — it is
// only downloaded when the runtime fetch fails, so the main bundle stays free
// of the ~450 kB of prose.
type DocsFile = { posters: Record<string, PosterDoc> };

function isDocsFile(value: unknown): value is DocsFile {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { posters?: unknown }).posters === 'object' &&
    (value as { posters: unknown }).posters !== null
  );
}

async function fetchDocs(): Promise<Record<string, PosterDoc>> {
  try {
    const response = await fetch('/poster-docs.json', { cache: 'no-cache' });
    if (response.ok) {
      const parsed: unknown = await response.json();
      if (isDocsFile(parsed)) return parsed.posters;
    }
  } catch {
    // fall through to the bundled fallback chunk
  }
  const embedded: unknown = (
    await import('../../../scripts/serve/webroot/poster-docs.json', { with: { type: 'json' } })
  ).default;
  return isDocsFile(embedded) ? embedded.posters : {};
}

let docsPromise: Promise<Record<string, PosterDoc>> | null = null;

function loadPosterDocs(): Promise<Record<string, PosterDoc>> {
  docsPromise ??= fetchDocs();
  return docsPromise;
}

/** The full poster document for one exhibit; undefined while loading or absent. */
export function usePosterDoc(osId: string): PosterDoc | undefined {
  const [docs, setDocs] = useState<Record<string, PosterDoc> | null>(null);
  useEffect(() => {
    let alive = true;
    void loadPosterDocs().then((loaded) => {
      if (alive) setDocs(loaded);
    });
    return () => {
      alive = false;
    };
  }, []);
  return docs?.[osId];
}

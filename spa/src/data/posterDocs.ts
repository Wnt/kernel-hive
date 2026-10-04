import { useEffect, useState } from 'react';
import type { PosterDoc, TypeInDoc } from '../types';

// '/' for the live gallery, '/staging/<session>/' for a staged UI
// (scripts/dev/stage.sh) whose runtime documents are rendered from that
// session's registry. Read defensively: the registry checks import this file
// under plain node, where import.meta.env does not exist.
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';


// Runtime poster prose. /poster-docs.json is rendered from registry/posters/*.md
// and published to the webroot by `serve-https-spa.sh manifests`, so poster copy
// edits go live on a browser refresh with no UI rebuild. Nothing is bundled:
// registry/posters/<id>.md is the single source, the served document is its only
// projection, and ~450 kB of prose stays out of the build entirely. The dev
// server renders the same document per request (see vite.config.ts).
//
// The same document carries the type-in editor's example programs and manual
// links as a SIBLING key, `typeIn` (registry/examples/<id>/), so one fetch
// serves both and a bundle that predates the editor reads it unchanged.
type DocsFile = { posters: Record<string, PosterDoc>; typeIn?: Record<string, TypeInDoc> };

function isDocsFile(value: unknown): value is DocsFile {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as { posters?: unknown }).posters === 'object' &&
    (value as { posters: unknown }).posters !== null
  );
}

async function fetchDocs(): Promise<DocsFile> {
  try {
    const response = await fetch(`${RUNTIME_BASE}poster-docs.json`, { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const parsed: unknown = await response.json();
    if (!isDocsFile(parsed)) throw new Error('schema validation failed');
    return parsed;
  } catch (error) {
    const reason = error instanceof Error ? error.message : 'unknown error';
    console.error(`[poster-docs] no poster prose (${reason}) — publish it with 'serve-https-spa.sh manifests'`);
    return { posters: {} };
  }
}

let docsPromise: Promise<DocsFile> | null = null;

function loadPosterDocs(): Promise<DocsFile> {
  docsPromise ??= fetchDocs();
  return docsPromise;
}

function useDocs(enabled = true): DocsFile | null {
  const [docs, setDocs] = useState<DocsFile | null>(null);
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    void loadPosterDocs().then((loaded) => {
      if (alive) setDocs(loaded);
    });
    return () => {
      alive = false;
    };
  }, [enabled]);
  return docs;
}

/** The full poster document for one exhibit; undefined while loading or absent. */
export function usePosterDoc(osId: string): PosterDoc | undefined {
  return useDocs()?.posters[osId];
}

const NO_TYPE_IN: TypeInDoc = { examples: [], manuals: [] };

/** One station's example programs + manual links. undefined while loading (or
 *  while `enabled` is false — nothing is fetched until it is asked for); an
 *  empty doc once loaded for a station that has none. */
export function useTypeInDoc(osId: string, enabled = true): TypeInDoc | undefined {
  const docs = useDocs(enabled);
  if (!docs) return undefined;
  const doc = docs.typeIn?.[osId];
  return doc && Array.isArray(doc.examples) && Array.isArray(doc.manuals) ? doc : NO_TYPE_IN;
}

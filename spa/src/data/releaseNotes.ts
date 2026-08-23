import { useEffect, useState } from 'react';

// Runtime release notes. /release-notes.json is generated from `git log` by
// scripts/release-notes.py (`make release-notes`) alongside README.md's digest
// and docs/RELEASE-NOTES.md's archive, and it lives in spa/public/ so a plain
// `npm run build` ships it — it is a build-time artefact of the repo's own
// history, not a registry-rendered document, so it does NOT travel through
// serve-https-spa.sh's manifest publish. Same base-URL rule as the other
// runtime documents, so a staged UI resolves /staging/<session>/release-notes.json.
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

interface ReleaseEntry {
  /**
   * What the entry is about: a registry station id for the Stations section,
   * otherwise the recognised scope token of the commit subject. Null when
   * nothing in the subject named a scope.
   */
  scope: string | null;
  /**
   * The commit subject as a bullet. A single-token `scope: ` prefix is stripped
   * and the opening letter upper-cased, except where the opening word is a name
   * that owns its spelling (stage.sh, macos753, VICE) -- see recase() in
   * scripts/release-notes.py. A multi-word scope phrase ("chokanji poster: ")
   * is kept, because stripping it would throw away the "poster".
   */
  text: string;
  sha: string;
  date: string;
}

export interface ReleaseSection {
  title: string;
  count: number;
  entries: ReleaseEntry[];
  /** Dependencies only: rendered as its count line, entries deliberately empty. */
  collapsed?: boolean;
}

export interface ReleaseWeek {
  number: number;
  start: string;
  end: string;
  startDate: string;
  endDate: string;
  inProgress: boolean;
  commitCount: number;
  sections: ReleaseSection[];
}

export interface ReleaseNotesDoc {
  /** Human-readable statement of the week boundary, e.g. "Sunday 09:00 Europe/Helsinki". */
  cutoff: string;
  /** ISO8601 timestamp of the first commit in the repo (the open-source release). */
  epoch: string;
  generatedFrom: string;
  /** Newest week first. */
  weeks: ReleaseWeek[];
}

function isReleaseNotesDoc(value: unknown): value is ReleaseNotesDoc {
  if (typeof value !== 'object' || value === null) return false;
  const doc = value as { cutoff?: unknown; weeks?: unknown };
  return typeof doc.cutoff === 'string' && Array.isArray(doc.weeks);
}

async function fetchReleaseNotes(): Promise<ReleaseNotesDoc | null> {
  try {
    const response = await fetch(`${RUNTIME_BASE}release-notes.json`, { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const parsed: unknown = await response.json();
    if (!isReleaseNotesDoc(parsed)) throw new Error('schema validation failed');
    return parsed;
  } catch (error) {
    const reason = error instanceof Error ? error.message : 'unknown error';
    console.error(`[release-notes] no release notes (${reason}) — regenerate them with 'make release-notes'`);
    return null;
  }
}

let notesPromise: Promise<ReleaseNotesDoc | null> | null = null;

/** The generated release notes; `undefined` while loading, `null` when unavailable. */
export function useReleaseNotes(): ReleaseNotesDoc | null | undefined {
  const [doc, setDoc] = useState<ReleaseNotesDoc | null | undefined>(undefined);
  useEffect(() => {
    let alive = true;
    notesPromise ??= fetchReleaseNotes();
    void notesPromise.then((loaded) => {
      if (alive) setDoc(loaded);
    });
    return () => {
      alive = false;
    };
  }, []);
  return doc;
}

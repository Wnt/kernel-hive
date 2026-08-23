import { useEffect, useState } from 'react';

// Runtime release notes. /release-notes.json is written by
// scripts/release-notes.py (`make release-notes`), which only lays out the
// hand-written registry/release-notes/<end-date>.json files — one per closed
// week, written by the operator's Sunday Claude Code pass. It lives in
// spa/public/ so a plain `npm run build` ships it, and it does NOT travel
// through serve-https-spa.sh's manifest publish, which republishes the STATION
// registry's documents and knows nothing about this one. Same base-URL rule as
// the other runtime documents, so a staged UI resolves
// /staging/<session>/release-notes.json.
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

export interface ReleaseSection {
  /** e.g. "New stations" — one of the fixed themes. */
  theme: string;
  text: string;
}

export interface ReleaseWeek {
  /** Week ordinal. Week 1 starts at the first public commit; week 0 predates it. */
  week: number;
  /** Short editorial headline for the week, e.g. "The retronet signs on". */
  title: string;
  /** ISO8601 start/end of the half-open week span, already in Helsinki time. */
  start: string;
  end: string;
  /** The same two boundaries as bare dates, for display. */
  startDate: string;
  endDate: string;
  /** Kept as provenance; deliberately NOT displayed — a raw commit count is a
   *  developer metric, and it made the week the project was published look
   *  like its quietest. */
  commitCount: number;
  /** Added lines of hand-written source that week, docs excluded. This is the
   *  size figure the page shows. */
  codeLines: number;
  /**
   * The week in three fixed themes, in order: what is new to go and see, what
   * a visitor can now do, and what got better. The themes are the same every
   * week (week 0 adds a leading "The story so far") and are enforced by
   * scripts/release-notes.py, so a reader who learns the shape once keeps it.
   * Each `text` may carry the inline markup releaseNotesMarkup.ts parses.
   */
  summary: ReleaseSection[];
  /** One-line highlights, rendered as a list. */
  bullets: string[];
  /**
   * Present only on a week reconstructed from a history OTHER than this
   * repository's — today just week 0, summarised from the private `osgallery`
   * repo the lab was built in before it was published. Its presence, not the
   * week number, is what makes the view print the "before the repository was
   * public" note.
   */
  source?: string;
}

export interface ReleaseNotesDoc {
  /** Human-readable statement of the week boundary, e.g. "Sunday 09:00 Europe/Helsinki". */
  cutoff: string;
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

/** The published release notes; `undefined` while loading, `null` when unavailable. */
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

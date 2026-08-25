// The walk-in exhibition manifest — WALKIN-BRIEF §5.3.
//
// A walk-in browses the museum the way a visitor reads placards: every listed
// exhibit's prose, hero and era, and NONE of its interactive state. The server
// builds that document by ALLOWLIST in gate.py; this module parses it by the
// same allowlist, so a field added to the registry later cannot leak into the
// walk-in UI just because someone widened a projection. A row that carries a
// `signalEndpoint` is ignored here on purpose: the visitor's one live surface
// arrives from the CLAIM (§3), never from a manifest row.

/** One exhibit as a walk-in may see it. Read-only placard data. */
export interface WalkinExhibit {
  id: string;
  displayName: string;
  year: number | string;
  era: string;
  eraLabel: string;
  lineage: string;
  arch: string;
  accent: string;
  blurb: string;
  notes?: string;
  eraSoftware: string[];
  iconicApps: string[];
  periodBrowser?: string;
}

/** The exhibition fields §5.3 allows a walk-in to see, and nothing else. */
const ALLOWED = [
  'id', 'displayName', 'year', 'era', 'eraLabel', 'lineage', 'arch',
  'accent', 'blurb', 'notes', 'eraSoftware', 'iconicApps', 'periodBrowser',
] as const;

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : [];
}

function text(value: unknown, fallback = ''): string {
  return typeof value === 'string' ? value : fallback;
}

/** Project one raw row onto the allowlist. Null when it is not an exhibit row. */
export function parseExhibit(value: unknown): WalkinExhibit | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (typeof row.id !== 'string' || !row.id) return null;
  if (typeof row.displayName !== 'string' || !row.displayName) return null;
  // Soft-hidden stations (registry `listing`) are not public yet — walk-ins
  // included. `listed` is absent on a listed row, so only an explicit false hides.
  if (row.listed === false) return null;
  const kept: Record<string, unknown> = {};
  for (const key of ALLOWED) if (row[key] !== undefined) kept[key] = row[key];
  const year = typeof kept.year === 'number' || typeof kept.year === 'string' ? kept.year : '';
  return {
    id: row.id,
    displayName: row.displayName,
    year,
    era: text(kept.era),
    eraLabel: text(kept.eraLabel),
    lineage: text(kept.lineage),
    arch: text(kept.arch),
    accent: text(kept.accent, '#9c4f35'),
    blurb: text(kept.blurb),
    notes: typeof kept.notes === 'string' ? kept.notes : undefined,
    eraSoftware: strings(kept.eraSoftware),
    iconicApps: strings(kept.iconicApps),
    periodBrowser: typeof kept.periodBrowser === 'string' ? kept.periodBrowser : undefined,
  };
}

/** Parse a whole manifest document; either `{entries:[…]}` or a bare array. */
export function parseWalkinManifest(document: unknown): WalkinExhibit[] {
  const rows = Array.isArray(document)
    ? document
    : (document as { entries?: unknown })?.entries;
  if (!Array.isArray(rows)) return [];
  const out: WalkinExhibit[] = [];
  for (const row of rows) {
    const exhibit = parseExhibit(row);
    if (exhibit) out.push(exhibit);
  }
  // Chronological, the way the hall itself is laid out.
  return out.sort((a, b) => eraYear(a) - eraYear(b) || a.displayName.localeCompare(b.displayName));
}

function eraYear(exhibit: WalkinExhibit): number {
  const year = typeof exhibit.year === 'number' ? exhibit.year : parseInt(String(exhibit.year), 10);
  return Number.isFinite(year) ? year : 9999;
}

const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

async function fetchDocument(path: string, base = ''): Promise<unknown | null> {
  try {
    const response = await fetch(`${base}${path}`, { cache: 'no-cache' });
    if (!response.ok) return null;
    return (await response.json()) as unknown;
  } catch {
    return null;
  }
}

/**
 * The listed fleet as placards.
 *
 * `/walkin/manifest.json` is the real source (lane 1 serves it). Until it
 * exists — and on a staged build, which has no walk-in plane behind it — the
 * PUBLIC gallery manifest is read instead and pushed through the SAME
 * allowlist, so the page shows true exhibition data and still cannot render a
 * field a walk-in is not allowed to see.
 */
export async function loadWalkinExhibits(): Promise<WalkinExhibit[]> {
  // The projection is served by the walk-in plane at the origin root; the
  // gallery manifest is a per-staging-slot runtime document, so it keeps the
  // bundle's base.
  const walkin = await fetchDocument('/walkin/manifest.json');
  if (walkin) return parseWalkinManifest(walkin);
  const gallery = await fetchDocument('gallery-manifest.json', RUNTIME_BASE);
  return gallery ? parseWalkinManifest(gallery) : [];
}

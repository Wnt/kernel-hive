import type { ArchetypeId, Transport } from '../three/archetypeRegistry';
import type { RuntimeVMManifestEntry } from '../types';

export interface GalleryManifest {
  schemaVersion: 1;
  entries: RuntimeVMManifestEntry[];
}

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

const ARCHETYPES = new Set<ArchetypeId>([
  'beige-ibm-pc',
  'beige-tower-crt',
  'putty-lcd',
  'sparc-pizzabox',
  'mono-terminal',
  'touch-phone',
  'apple-studio',
]);
const TRANSPORTS = new Set<Transport>(['streamhost', 'showcase']);
const ENTRY_FIELDS = new Set([
  'id', 'era_year', 'displayName', 'year', 'lineage', 'arch', 'ramMB', 'ramKB', 'notes',
  'accent', 'era', 'eraSoftware', 'periodBrowser', 'iconicApps', 'blurb',
  'archetypeId', 'transport', 'order', 'eraLabel', 'signalEndpoint',
  'endpoint', 'pointerRel', 'hardwareInput', 'coldBoot', 'bootVideo',
  'relativePointerOnly', 'listed',
]);
const ID = /^[a-z0-9][a-z0-9-]*$/;
const ACCENT = /^#[0-9a-f]{6}$/i;

function object(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function optionalString(value: unknown): value is string | undefined {
  return value === undefined || typeof value === 'string';
}

function optionalBoolean(value: unknown): value is boolean | undefined {
  return value === undefined || typeof value === 'boolean';
}

function parseEntry(value: unknown): RuntimeVMManifestEntry | null {
  const entry = object(value);
  if (!entry) return null;
  if (!Object.keys(entry).every((key) => ENTRY_FIELDS.has(key))) return null;
  if (typeof entry.id !== 'string' || !ID.test(entry.id)) return null;
  if (typeof entry.era_year !== 'number' || !Number.isInteger(entry.era_year)) return null;
  if (typeof entry.displayName !== 'string' || !entry.displayName) return null;
  if (typeof entry.year !== 'number' || !Number.isInteger(entry.year)) return null;
  if (typeof entry.lineage !== 'string' || typeof entry.arch !== 'string') return null;
  if (typeof entry.accent !== 'string' || !ACCENT.test(entry.accent)) return null;
  if (typeof entry.archetypeId !== 'string' || !ARCHETYPES.has(entry.archetypeId as ArchetypeId)) return null;
  if (typeof entry.transport !== 'string' || !TRANSPORTS.has(entry.transport as Transport)) return null;
  if (typeof entry.order !== 'number' || !Number.isInteger(entry.order) || entry.order < 0) return null;
  if (typeof entry.eraLabel !== 'string' || !entry.eraLabel.startsWith(`${entry.year} · `)) return null;
  if (entry.transport === 'streamhost') {
    if (typeof entry.signalEndpoint !== 'string' || !entry.signalEndpoint.startsWith('/signal/')) return null;
  } else if (entry.signalEndpoint !== null && entry.signalEndpoint !== undefined) {
    return null;
  }
  if (entry.ramMB !== undefined && (typeof entry.ramMB !== 'number' || !Number.isFinite(entry.ramMB))) return null;
  if (entry.ramKB !== undefined && (typeof entry.ramKB !== 'number' || !Number.isFinite(entry.ramKB))) return null;
  if (!optionalString(entry.notes) || typeof entry.era !== 'string') return null;
  if (typeof entry.periodBrowser !== 'string' || typeof entry.blurb !== 'string' || !optionalString(entry.endpoint)) return null;
  if (!Array.isArray(entry.eraSoftware) || !entry.eraSoftware.every((item) => typeof item === 'string')) return null;
  if (!Array.isArray(entry.iconicApps) || !entry.iconicApps.every((item) => typeof item === 'string')) return null;
  if (!optionalBoolean(entry.pointerRel) || !optionalBoolean(entry.hardwareInput) || !optionalBoolean(entry.coldBoot)) return null;
  if (!optionalBoolean(entry.relativePointerOnly) || !optionalBoolean(entry.listed)) return null;
  if (entry.bootVideo !== undefined && typeof entry.bootVideo !== 'string') return null;

  const bootVideo = typeof entry.bootVideo === 'string' ? { mp4: entry.bootVideo } : undefined;
  return { ...entry, bootVideo } as unknown as RuntimeVMManifestEntry;
}

export function validateGalleryManifest(value: unknown): GalleryManifest | null {
  const document = object(value);
  if (!document || document.schemaVersion !== 1 || !Array.isArray(document.entries) || document.entries.length === 0) return null;
  if (!Object.keys(document).every((key) => key === '_generated' || key === 'schemaVersion' || key === 'entries')) return null;
  if (document._generated !== undefined && typeof document._generated !== 'string') return null;
  const entries: RuntimeVMManifestEntry[] = [];
  const ids = new Set<string>();
  const orders = new Set<number>();
  for (const raw of document.entries) {
    const entry = parseEntry(raw);
    if (!entry || ids.has(entry.id) || orders.has(entry.order)) return null;
    ids.add(entry.id);
    orders.add(entry.order);
    entries.push(entry);
  }
  entries.sort((a, b) => a.order - b.order);
  return { schemaVersion: 1, entries };
}

// The lineup has ONE source: /gallery-manifest.json, rendered from
// registry/stations/*.json and served from the same origin as this bundle. There is
// deliberately no embedded copy to fall back on — a bundled snapshot is a second
// answer to "what is in the museum" that goes stale silently (it is why a
// registry edit used to need a Vite build to show up), and the origin that would
// have served the fallback is the same one that just failed to serve the
// manifest. An empty lineup is the honest, loud failure.
export async function loadGalleryManifest(fetcher: FetchLike = fetch): Promise<RuntimeVMManifestEntry[]> {
  try {
    const response = await fetcher('/gallery-manifest.json', { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const runtime = validateGalleryManifest(await response.json());
    if (!runtime) throw new Error('schema validation failed');
    return runtime.entries;
  } catch (error) {
    const reason = error instanceof Error ? error.message : 'unknown error';
    console.error(`[gallery-manifest] no lineup (${reason}) — publish it with 'serve-https-spa.sh manifests'`);
    return [];
  }
}

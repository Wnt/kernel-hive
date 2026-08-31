import { useEffect, useState } from 'react';
import { reach } from '../analytics';

// Runtime fleet table. /fleet-table.json is rendered from registry/stations/*.json
// (+ registry/bridge-suites.json) by stations-registry.py and published to the
// webroot beside gallery-manifest.json, so the /fleet view always shows what the
// registry says NOW: nothing is bundled, and a registry edit is a browser refresh
// away. Same base-URL rule as the other runtime documents (staged UIs resolve
// /staging/<session>/fleet-table.json).
const RUNTIME_BASE: string = (import.meta as ImportMeta & { env?: { BASE_URL?: string } }).env?.BASE_URL ?? '/';

interface FleetEmulator {
  family: string;
  version: string | null;
  source: string;
  driver?: string;
}

interface FleetKiosk {
  suite: string;
  distro: string;
  kind: string;
}

interface FleetMachine {
  qemuBinary?: string | null;
  qemuMachine?: string | null;
  accel?: string | null;
  vmMemoryMB?: number | null;
  smp?: number | null;
  vga?: string | null;
  geometry?: string | null;
  launcher?: string | null;
  role?: string;
}

interface FleetPointer {
  method: string | null;
  transport: string | null;
  absolute: boolean;
  present: boolean;
  device: string | null;
  backend: string | null;
  scale: number | null;
  buttons?: string;
  via?: string;
}

interface FleetGolden {
  resetMode: string | null;
  snapshot: string | null;
  kind: string | null;
  instant: boolean;
}

interface FleetExec {
  kind: string;
  supported: boolean;
  port: number | null;
  user: string | null;
  detail: string | null;
}

interface FleetNetwork {
  status: 'internet' | 'host-only' | 'isolated' | 'nic-only' | 'none' | string;
  detail: string;
  hostfwd: string[];
  source: string;
}

interface FleetIcq {
  uin: string;
  nick: string;
  client: string;
  live: boolean;
}

// Membership of the offline retronet bridge (vmbr-rn). `null` = not on it.
// Merged by fleet_table.py from the station's registry `retronet` block (bridge
// facts) and scripts/retronet/icq/roster.json (the persona) — neither restates
// the other, and stations-registry.py fails the gate if they drift apart.
interface FleetRetronet {
  planes: string[];
  address: string | null;
  addressing: 'dhcp' | 'static' | null;
  link: string | null;
  guard: string | null;
  joined: string | null;
  doc: string | null;
  icq: FleetIcq | null;
}

export interface FleetEntry {
  id: string;
  displayName: string;
  year: number;
  era: string | null;
  lineage: string | null;
  arch: string | null;
  guestRamMB: number | null;
  guestRamKB: number | null;
  lifecycle: string;
  listed: boolean;
  tier: number;
  tierLabel: string;
  emulator: FleetEmulator | null;
  ui: 'desktop' | 'text-console' | 'home-computer' | 'mobile' | 'other' | null;
  screen: { width: number | null; height: number | null; bpp: number | null; source: string } | null;
  kiosk: FleetKiosk | null;
  machine: FleetMachine;
  capture: string | null;
  keyboardPath: string | null;
  pointer: FleetPointer;
  keyPacingMs: { holdMs: number; gapMs: number } | null;
  fps: number | null;
  audio: boolean | null;
  audioSource: string | null;
  idlePauseSecs: number | null;
  golden: FleetGolden | null;
  exec: FleetExec | null;
  network: FleetNetwork | null;
  retronet: FleetRetronet | null;
  slot: number | null;
  guestDoc: string | null;
  /** Interaction totals, merged in from /usage/stations.json at render time —
   *  NOT part of the generated document, which is derived from the registry and
   *  says nothing about how a machine is used. Undefined until that fetch lands
   *  (or forever, on a deployment with no counter plane). */
  usage?: StationUsage;
}

/** One machine's interaction totals. No identities: /usage/stations.json is the
 *  aggregate half of the counters on purpose, and the per-person half is served
 *  only to an admin, from /auth/usage/report. See scripts/serve/usage.py. */
export interface StationUsage {
  clicks: number;
  keys: number;
  lastAt?: string;
}

export interface FleetTableDoc {
  schemaVersion: number;
  tierLabels: Record<string, string>;
  entries: FleetEntry[];
}

function isFleetTableDoc(value: unknown): value is FleetTableDoc {
  if (typeof value !== 'object' || value === null) return false;
  const doc = value as { schemaVersion?: unknown; entries?: unknown };
  return doc.schemaVersion === 1 && Array.isArray(doc.entries);
}

async function fetchFleetTable(): Promise<FleetTableDoc | null> {
  try {
    const response = await fetch(`${RUNTIME_BASE}fleet-table.json`, { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const parsed: unknown = await response.json();
    if (!isFleetTableDoc(parsed)) throw new Error('schema validation failed');
    return parsed;
  } catch (error) {
    const reason = error instanceof Error ? error.message : 'unknown error';
    console.error(`[fleet-table] no fleet table (${reason}) — publish it with 'serve-https-spa.sh manifests'`);
    return null;
  }
}

async function fetchStationUsage(): Promise<Record<string, StationUsage>> {
  try {
    // An absolute path, unlike the registry documents above: this one is a live
    // server route, not a file a staged UI copies beside itself.
    // The producer half of the auto-vs-act pair: this runs on every visit to
    // /fleet whether or not anybody looks at the two columns it feeds. Its
    // consumers are fleet.usage.shown / fleet.usage.sorted in FleetTable.tsx.
    reach('fleet.usage.fetch', 'auto');
    const response = await fetch('/usage/stations.json', { cache: 'no-store', credentials: 'same-origin' });
    if (!response.ok) return {};
    const parsed = (await response.json()) as { stations?: Record<string, StationUsage> };
    return parsed.stations && typeof parsed.stations === 'object' ? parsed.stations : {};
  } catch {
    // A fleet table that renders without the popularity columns is the right
    // failure: they are an annotation, not the table.
    return {};
  }
}

/** Per-station interaction totals, or an empty map while loading / unavailable. */
export function useStationUsage(): Record<string, StationUsage> {
  const [usage, setUsage] = useState<Record<string, StationUsage>>({});
  useEffect(() => {
    let alive = true;
    void fetchStationUsage().then((loaded) => {
      if (alive) setUsage(loaded);
    });
    return () => {
      alive = false;
    };
  }, []);
  return usage;
}

let tablePromise: Promise<FleetTableDoc | null> | null = null;

/** The rendered fleet table; `undefined` while loading, `null` when unavailable. */
export function useFleetTable(): FleetTableDoc | null | undefined {
  const [doc, setDoc] = useState<FleetTableDoc | null | undefined>(undefined);
  useEffect(() => {
    let alive = true;
    tablePromise ??= fetchFleetTable();
    void tablePromise.then((loaded) => {
      if (alive) setDoc(loaded);
    });
    return () => {
      alive = false;
    };
  }, []);
  return doc;
}

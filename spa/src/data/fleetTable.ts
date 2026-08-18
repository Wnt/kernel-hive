import { useEffect, useState } from 'react';

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
  slot: number | null;
  guestDoc: string | null;
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

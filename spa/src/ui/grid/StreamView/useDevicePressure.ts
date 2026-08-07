import { useEffect, useState } from 'react';

// ---------------------------------------------------------------------------
//  DevicePressureIndicator (Item 6) — feature-detected PressureObserver('cpu')
//  collapsed to the worst-of level across sources, plus an optional
//  navigator.getBattery() low-battery flag. Read-only observers: NO input path,
//  no T_STATS/T_INPUT touch. StreamView renders a DISTINCT HUD chip from this and
//  uses it to disambiguate 'device under load' from a 'spotty' NETWORK banner.
// ---------------------------------------------------------------------------
type CpuPressure = 'nominal' | 'fair' | 'serious' | 'critical';
const PRESSURE_RANK: Record<CpuPressure, number> = { nominal: 0, fair: 1, serious: 2, critical: 3 };

interface PressureRecordLike { source: string; state: CpuPressure }
interface PressureObserverLike {
  observe: (source: string, opts?: { sampleInterval?: number }) => void;
  disconnect: () => void;
}
type PressureObserverCtor = new (
  cb: (records: PressureRecordLike[]) => void,
) => PressureObserverLike;
interface BatteryLike {
  level: number;
  charging: boolean;
  addEventListener: (t: string, cb: () => void) => void;
  removeEventListener: (t: string, cb: () => void) => void;
}

const LOW_BATTERY_LEVEL = 0.2; // ≤20% and not charging ⇒ low-battery flag.

export interface DevicePressureState { cpu: CpuPressure | null; lowBattery: boolean }

export function useDevicePressure(active: boolean): DevicePressureState {
  const [state, setState] = useState<DevicePressureState>({ cpu: null, lowBattery: false });

  useEffect(() => {
    if (!active) return;
    let disposed = false;

    // ---- PressureObserver('cpu') — worst-of across reported sources ----
    let observer: PressureObserverLike | null = null;
    const Ctor = (window as unknown as { PressureObserver?: PressureObserverCtor }).PressureObserver;
    if (Ctor) {
      try {
        observer = new Ctor((records) => {
          if (disposed || !records.length) return;
          let worst: CpuPressure = 'nominal';
          for (const r of records) {
            if (r.source === 'cpu' && PRESSURE_RANK[r.state] > PRESSURE_RANK[worst]) worst = r.state;
          }
          setState((s) => (s.cpu === worst ? s : { ...s, cpu: worst }));
        });
        observer.observe('cpu', { sampleInterval: 1000 });
      } catch { observer = null; /* unsupported / permissions-policy */ }
    }

    // ---- navigator.getBattery() low-battery flag ----
    let battery: BatteryLike | null = null;
    let onBattery: (() => void) | null = null;
    const getBattery = (navigator as unknown as { getBattery?: () => Promise<BatteryLike> }).getBattery;
    if (typeof getBattery === 'function') {
      getBattery.call(navigator).then((b) => {
        if (disposed) return;
        battery = b;
        onBattery = () => {
          const low = b.level <= LOW_BATTERY_LEVEL && !b.charging;
          setState((s) => (s.lowBattery === low ? s : { ...s, lowBattery: low }));
        };
        b.addEventListener('levelchange', onBattery);
        b.addEventListener('chargingchange', onBattery);
        onBattery();
      }).catch(() => { /* unsupported / denied */ });
    }

    return () => {
      disposed = true;
      try { observer?.disconnect(); } catch { /* noop */ }
      if (battery && onBattery) {
        try { battery.removeEventListener('levelchange', onBattery); } catch { /* noop */ }
        try { battery.removeEventListener('chargingchange', onBattery); } catch { /* noop */ }
      }
    };
  }, [active]);

  return state;
}

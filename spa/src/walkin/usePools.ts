import { useEffect, useState } from 'react';
import type { WalkinPool, WalkinState } from '../data/walkinTypes';
import { fetchWalkinState } from './api';

// Live walk-in pool status, lifted out of WalkinLanding so the merged grid and
// the landing page poll it the same way rather than growing two timers with two
// different periods. Pool status is live, not a page-load snapshot: a visitor
// deciding between three machines should see one free up while they read.

export interface WalkinPools {
  state: WalkinState | null;
  error: string | null;
}

export function poolFor(state: WalkinState | null, os: string): WalkinPool | undefined {
  return state?.pools.find((pool) => pool.os === os);
}

export function useWalkinPools(enabled = true): WalkinPools {
  const [state, setState] = useState<WalkinState | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    const tick = () => {
      fetchWalkinState().then(
        (next) => { if (alive) { setState(next); setError(null); } },
        (reason: unknown) => {
          if (alive) setError(reason instanceof Error ? reason.message : 'walk-in status unavailable');
        },
      );
    };
    tick();
    const timer = setInterval(tick, 15_000);
    return () => { alive = false; clearInterval(timer); };
  }, [enabled]);

  return { state, error };
}

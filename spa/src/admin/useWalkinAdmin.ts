import { useCallback, useEffect, useRef, useState } from 'react';
import type { WalkinAccess, WalkinAdminStatus } from './walkinAdminTypes';
import { WalkinAdminError, fetchWalkinStatus, purgeWalkinAccounts, setWalkinAccess, setWalkinDrain } from './walkinAdminApi';

// Position rank so the panel can tell "reachable" from "blocked by the env
// floor" (CONTRACT-LEDGER.md §4.2: WALKIN_OPEN can only lower the ceiling,
// never raise it — closed < invited < open).
const RANK: Record<WalkinAccess, number> = { closed: 0, invited: 1, open: 2 };
export const accessRank = (a: WalkinAccess): number => RANK[a];

export type WalkinAdminState =
  | { phase: 'loading' }
  // /auth/walkin/status is admin-only; a viewer or signed-out tab gets a 401/403
  // here, which is not "the feature is broken" — it is "sign in as an admin".
  | { phase: 'forbidden' }
  | { phase: 'error'; message: string }
  | { phase: 'ready'; status: WalkinAdminStatus };

export type LastResult =
  | { kind: 'access'; access: WalkinAccess; disconnected: number }
  | { kind: 'drain'; drain: boolean }
  | { kind: 'purge'; purged: number };

export function useWalkinAdmin() {
  const [state, setState] = useState<WalkinAdminState>({ phase: 'loading' });
  const [busy, setBusy] = useState(false);
  const [lastResult, setLastResult] = useState<LastResult | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  // /auth/walkin/status carries no `drain` field (frozen contract, §3) — a
  // reload or a second admin's tab cannot recover whether a drain is in
  // effect. Track only what THIS tab has asked for, and say so in the UI.
  const [drainRequested, setDrainRequested] = useState(false);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);

  const refresh = useCallback(async () => {
    try {
      const status = await fetchWalkinStatus();
      if (!alive.current) return;
      setState({ phase: 'ready', status });
    } catch (error) {
      if (!alive.current) return;
      if (error instanceof WalkinAdminError && (error.status === 401 || error.status === 403)) {
        setState({ phase: 'forbidden' });
        return;
      }
      const message = error instanceof Error ? error.message : 'unknown error';
      setState({ phase: 'error', message });
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);

  const changeAccess = useCallback(async (access: WalkinAccess) => {
    setBusy(true);
    setActionError(null);
    try {
      const result = await setWalkinAccess(access);
      setLastResult({ kind: 'access', access: result.access, disconnected: result.disconnected });
      await refresh();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : 'unknown error');
    } finally {
      setBusy(false);
    }
  }, [refresh]);

  const toggleDrain = useCallback(async (drain: boolean) => {
    setBusy(true);
    setActionError(null);
    try {
      await setWalkinDrain(drain);
      setDrainRequested(drain);
      setLastResult({ kind: 'drain', drain });
    } catch (error) {
      setActionError(error instanceof Error ? error.message : 'unknown error');
    } finally {
      setBusy(false);
    }
  }, []);

  const purge = useCallback(async (olderThanDays: number) => {
    setBusy(true);
    setActionError(null);
    try {
      const result = await purgeWalkinAccounts(olderThanDays);
      setLastResult({ kind: 'purge', purged: result.purged });
      await refresh();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : 'unknown error');
    } finally {
      setBusy(false);
    }
  }, [refresh]);

  return { state, busy, lastResult, actionError, drainRequested, changeAccess, toggleDrain, purge, refresh };
}

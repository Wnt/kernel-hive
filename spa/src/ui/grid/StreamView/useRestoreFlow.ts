/* eslint-disable react-hooks/exhaustive-deps -- callback/effect lifted VERBATIM
   from StreamView with byte-identical dependency arrays; the ref/setter arrive as
   stable params, which defeats the rule's static ref/setState stability inference
   (the original in-component code passed the rule clean). rules-of-hooks (the
   correctness rule) stays enforced. */
import { useCallback, useEffect, type Dispatch, type RefObject, type SetStateAction } from 'react';

type RestoreState = 'idle' | 'busy' | 'ok' | 'err';

// ---- RESTORE TO CHECKPOINT (streamhost only) ---------------------------------
//  Non-destructive host-side reset of THIS station to its curated checkpoint scene
//  (the same clean starting state the input regression suite certifies). Same
//  origin as the UI; no operator token required — the endpoint is LAN-gated
//  and non-destructive, so the exhibit's "Restore to golden snapshot" button
//  works for any visitor. No confirmation prompt: the action is cheap, obvious
//  from its label, and undone by using the exhibit again.
export function useRestoreFlow({
  osId, restoreState, setRestoreState,
  beginRestoreReconnect, finishRestoreReconnect, restoreTimer,
}: {
  osId: string;
  restoreState: RestoreState;
  setRestoreState: Dispatch<SetStateAction<RestoreState>>;
  beginRestoreReconnect?: () => void;
  finishRestoreReconnect?: () => void;
  restoreTimer: RefObject<number>;
}): { restoreToGolden: () => void } {
  const restoreToGolden = useCallback(() => {
    if (restoreState === 'busy') return;
    setRestoreState('busy');
    beginRestoreReconnect?.();
    fetch(`/restore/${encodeURIComponent(osId)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        setRestoreState('ok');
      })
      .catch((e) => {
        console.warn('[StreamView] restore failed:', e);
        setRestoreState('err');
      })
      .finally(() => {
        // Success means the checkpoint is ready; failure means the old live guest is
        // still the recovery target. Either way, signal immediately instead of
        // waiting for WebTransport close/stall detection.
        finishRestoreReconnect?.();
        if (restoreTimer.current) clearTimeout(restoreTimer.current);
        restoreTimer.current = window.setTimeout(() => setRestoreState('idle'), 4500);
      });
  }, [osId, restoreState, beginRestoreReconnect, finishRestoreReconnect]);
  useEffect(() => () => { if (restoreTimer.current) clearTimeout(restoreTimer.current); }, []);

  return { restoreToGolden };
}

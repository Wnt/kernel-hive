/* eslint-disable react-hooks/exhaustive-deps -- callback/effect lifted VERBATIM
   from StreamView with byte-identical dependency arrays; the ref/setter arrive as
   stable params, which defeats the rule's static ref/setState stability inference
   (the original in-component code passed the rule clean). rules-of-hooks (the
   correctness rule) stays enforced. */
import { useCallback, useEffect, useRef, type Dispatch, type RefObject, type SetStateAction } from 'react';
import { beginFlow, startTiming, type Timing } from '../../../analytics';
import type { FlowHandle } from '../../../analytics/flows';
import type { Attrs } from '../../../analytics/trace';
import type { LivePhase } from '../../../three/streamSessionTypes';

type RestoreState = 'idle' | 'busy' | 'ok' | 'err';

// ---- RESTORE TO CHECKPOINT (streamhost only) ---------------------------------
//  Non-destructive host-side reset of THIS station to its curated checkpoint scene
//  (the same clean starting state the input regression suite certifies). Same
//  origin as the UI; no operator token required — the endpoint is LAN-gated
//  and non-destructive, so the exhibit's "Restore to golden snapshot" button
//  works for any visitor. No confirmation prompt: the action is cheap, obvious
//  from its label, and undone by using the exhibit again.
//
//  TELEMETRY (`station.restore` / `station.restore.toRestoredMs`,
//  catalogue/station.ts). This was the one gap in an otherwise end-to-end
//  golden-reset story: the SERVER already times its own reset
//  (`serve.restore`/`.reset`), but nothing measured what the VISITOR
//  experiences — click to picture back. The fetch resolving is the host
//  ACCEPTING the reset, not the machine being usable again, so the clock does
//  not stop there: it stops on the reconnected session's first painted frame,
//  which arrives asynchronously through `phase` going `'live'` after
//  `beginRestoreReconnect` set it `'connecting'` (useStreamhostSession's
//  `expectedRestore` flag — the same signal `station.connect`'s own funnel
//  uses for "the visitor can see the machine again", not a second definition
//  of done).
export function useRestoreFlow({
  osId, restoreState, setRestoreState,
  beginRestoreReconnect, finishRestoreReconnect, restoreTimer,
  phase, stationAttrs,
}: {
  osId: string;
  restoreState: RestoreState;
  setRestoreState: Dispatch<SetStateAction<RestoreState>>;
  beginRestoreReconnect?: () => void;
  finishRestoreReconnect?: () => void;
  restoreTimer: RefObject<number>;
  phase: LivePhase;
  stationAttrs?: Attrs;
}): { restoreToGolden: () => void } {
  // One attempt's telemetry, open from the click until the reconnected
  // session paints (or the attempt is abandoned/torn down). Bounded to one
  // in flight — a second click while `busy` is a no-op below, same as before.
  const pending = useRef<{ flow: FlowHandle; ms: Timing } | null>(null);

  const settle = useCallback((outcome: 'ok' | 'fail' | 'close', reason?: string) => {
    const p = pending.current;
    if (!p) return;
    pending.current = null;
    if (outcome === 'ok') {
      p.flow.step('restored');
      // Clock stopped before the flow closes, so the measurement lands as a
      // span event on `station.restore` itself rather than on whatever happens
      // to be open outside it — see analytics/metrics.ts `reportTiming`.
      p.ms.stop();
      p.flow.ok();
    } else if (outcome === 'fail') {
      p.flow.fail(reason);
      p.ms.abandon();
    } else {
      // Torn down rather than finished (station switched away, unmount) — the
      // funnel already shows this as a drop-off; see flows.ts's own rule.
      p.flow.close();
      p.ms.abandon();
    }
  }, []);

  const restoreToGolden = useCallback(() => {
    if (restoreState === 'busy') return;
    setRestoreState('busy');
    const flow = beginFlow('station.restore');
    if (stationAttrs) flow.tag(stationAttrs);
    pending.current = { flow, ms: startTiming('station.restore.toRestoredMs', stationAttrs) };
    beginRestoreReconnect?.();
    fetch(`/restore/${encodeURIComponent(osId)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        setRestoreState('ok');
        pending.current?.flow.step('reset');
      })
      .catch((e) => {
        console.warn('[StreamView] restore failed:', e);
        setRestoreState('err');
        settle('fail', 'resetFailed');
      })
      .finally(() => {
        // Success means the checkpoint is ready; failure means the old live guest is
        // still the recovery target. Either way, signal immediately instead of
        // waiting for WebTransport close/stall detection.
        finishRestoreReconnect?.();
        if (restoreTimer.current) clearTimeout(restoreTimer.current);
        restoreTimer.current = window.setTimeout(() => setRestoreState('idle'), 4500);
      });
  }, [osId, restoreState, beginRestoreReconnect, finishRestoreReconnect, settle, stationAttrs]);

  // Completion: the reconnected session's first painted frame, not the fetch.
  // A `phase` transition to `'live'` while nothing is pending is an ordinary
  // connect/resume and must not be mistaken for a restore completing. A
  // reconnect that gives up (`phase === 'error'`, the session's own retry
  // ladder exhausted) settles the pair rather than leaking it — the funnel
  // then shows exactly where a restore stopped, the same as `station.connect`.
  useEffect(() => {
    if (!pending.current) return;
    if (phase === 'live') settle('ok');
    else if (phase === 'error') settle('fail', 'reconnectFailed');
  }, [phase, settle]);

  useEffect(() => () => {
    if (restoreTimer.current) clearTimeout(restoreTimer.current);
    settle('close');
  }, []);

  return { restoreToGolden };
}

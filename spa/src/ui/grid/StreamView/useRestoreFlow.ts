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

// A reset that keeps the stream (D4's ctl-socket relaunch, e.g. nokia9300)
// never leaves `phase === 'live'`, so there is no reconnect to time out on —
// only a generous ceiling for "did a frame ever change". D4's proven resets
// land in 1.7-4.1s (reset-tile.sh, control-socket path); this leaves room for
// a slow guest without holding the busy state open indefinitely.
export const FRAME_WATCH_TIMEOUT_MS = 8000;
export const FRAME_WATCH_POLL_MS = 100;

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
//  not stop there:
//    - the DEFAULT path stops it on the reconnected session's first painted
//      frame, which arrives asynchronously through `phase` going `'live'`
//      after `beginRestoreReconnect` set it `'connecting'` (useStreamhostSession's
//      `expectedRestore` flag — the same signal `station.connect`'s own funnel
//      uses for "the visitor can see the machine again", not a second
//      definition of done).
//    - a `resetKeepsStream` station (manifest field, emit_gallery_manifest.py)
//      never drops its WebTransport on reset (D4's ctl-socket relaunch), so
//      there is no reconnect and no `phase` transition to watch. That branch
//      skips `beginRestoreReconnect`/`finishRestoreReconnect` entirely — tearing
//      the transport down would be pure regression, the guest side never asked
//      for it — and instead watches `frameEpoch` (bumped once per painted
//      frame) for the first change after the POST returns, with
//      FRAME_WATCH_TIMEOUT_MS falling back to the ordinary teardown/reconnect
//      path so a station that turns out not to keep the stream up still
//      recovers instead of hanging on "Restoring…" forever.
export function useRestoreFlow({
  osId, restoreState, setRestoreState, setRestoreError, restoreErrorTimer,
  beginRestoreReconnect, finishRestoreReconnect, restoreTimer,
  phase, stationAttrs, resetKeepsStream, frameEpoch,
}: {
  osId: string;
  restoreState: RestoreState;
  setRestoreState: Dispatch<SetStateAction<RestoreState>>;
  /** In-page surface for the 404/error path (U1 finding B1) — never silent. */
  setRestoreError: Dispatch<SetStateAction<string | null>>;
  restoreErrorTimer: RefObject<number>;
  beginRestoreReconnect?: () => void;
  finishRestoreReconnect?: () => void;
  restoreTimer: RefObject<number>;
  phase: LivePhase;
  stationAttrs?: Attrs;
  /** manifest `resetKeepsStream` — see the header comment. */
  resetKeepsStream?: boolean;
  /** useStreamhostSession's per-frame paint counter; required to take the
   *  resetKeepsStream branch — its absence (a non-streamhost transport, or a
   *  session not yet open) falls back to the ordinary reconnect path. */
  frameEpoch?: RefObject<number>;
}): { restoreToGolden: () => void } {
  // One attempt's telemetry, open from the click until the reconnected
  // session paints (or the attempt is abandoned/torn down). Bounded to one
  // in flight — a second click while `busy` is a no-op below, same as before.
  const pending = useRef<{ flow: FlowHandle; ms: Timing } | null>(null);
  const frameWatchInterval = useRef(0);
  const frameWatchTimer = useRef(0);

  const clearFrameWatch = useCallback(() => {
    if (frameWatchInterval.current) { window.clearInterval(frameWatchInterval.current); frameWatchInterval.current = 0; }
    if (frameWatchTimer.current) { window.clearTimeout(frameWatchTimer.current); frameWatchTimer.current = 0; }
  }, []);

  const settle = useCallback((outcome: 'ok' | 'fail' | 'close', reason?: string) => {
    clearFrameWatch();
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
  }, [clearFrameWatch]);

  // resetKeepsStream branch: poll frameEpoch for a change from its POST-resolve
  // baseline. `pending` (not a local flag) gates every tick, so a settle from
  // ANY other path (unmount, phase flipping to 'error' some other way) stops
  // the poll for free. Timeout falls back to the reconnect path — that is the
  // only place this branch calls begin/finishRestoreReconnect.
  const startFrameWatch = useCallback((baseline: number) => {
    frameWatchInterval.current = window.setInterval(() => {
      if (!pending.current) { clearFrameWatch(); return; }
      if ((frameEpoch?.current ?? baseline) !== baseline) {
        clearFrameWatch();
        settle('ok');
      }
    }, FRAME_WATCH_POLL_MS);
    frameWatchTimer.current = window.setTimeout(() => {
      clearFrameWatch();
      if (!pending.current) return;
      beginRestoreReconnect?.();
      finishRestoreReconnect?.();
    }, FRAME_WATCH_TIMEOUT_MS);
  }, [settle, clearFrameWatch, frameEpoch, beginRestoreReconnect, finishRestoreReconnect]);

  const restoreToGolden = useCallback(() => {
    if (restoreState === 'busy') return;
    setRestoreState('busy');
    const flow = beginFlow('station.restore');
    if (stationAttrs) flow.tag(stationAttrs);
    pending.current = { flow, ms: startTiming('station.restore.toRestoredMs', stationAttrs) };
    const keepsStream = !!resetKeepsStream && !!frameEpoch;
    if (!keepsStream) beginRestoreReconnect?.();
    fetch(`/restore/${encodeURIComponent(osId)}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
    })
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        setRestoreState('ok');
        pending.current?.flow.step('reset');
        if (keepsStream) startFrameWatch(frameEpoch!.current);
      })
      .catch((e) => {
        console.warn('[StreamView] restore failed:', e);
        setRestoreState('err');
        // U1 finding B1: this used to be console-only — a visitor saw the panel
        // close and nothing else. Same auto-dismiss shape as the fullscreen
        // rejection toast (useCinemaMode.ts's setFsError).
        setRestoreError(e instanceof Error && e.message ? `Restore failed: ${e.message}` : 'Restore failed');
        if (restoreErrorTimer.current) clearTimeout(restoreErrorTimer.current);
        restoreErrorTimer.current = window.setTimeout(() => setRestoreError(null), 6000);
        settle('fail', 'resetFailed');
      })
      .finally(() => {
        // Success means the checkpoint is ready; failure means the old live guest is
        // still the recovery target. Either way, signal immediately instead of
        // waiting for WebTransport close/stall detection. Not for keepsStream: its
        // transport was never torn down, so there is nothing to signal — calling
        // this here would start a reconnect the guest side never asked for.
        if (!keepsStream) finishRestoreReconnect?.();
        if (restoreTimer.current) clearTimeout(restoreTimer.current);
        restoreTimer.current = window.setTimeout(() => setRestoreState('idle'), 4500);
      });
  }, [
    osId, restoreState, beginRestoreReconnect, finishRestoreReconnect, settle, stationAttrs,
    resetKeepsStream, frameEpoch, startFrameWatch, setRestoreError, restoreErrorTimer,
  ]);

  // Completion (non-keepsStream path): the reconnected session's first painted
  // frame, not the fetch. A `phase` transition to `'live'` while nothing is
  // pending is an ordinary connect/resume and must not be mistaken for a
  // restore completing. A reconnect that gives up (`phase === 'error'`, the
  // session's own retry ladder exhausted) settles the pair rather than leaking
  // it — the funnel then shows exactly where a restore stopped, the same as
  // `station.connect`. Still correct for a keepsStream restore that fell back
  // to the reconnect path on the frame-watch timeout: it is `pending` (via
  // beginRestoreReconnect above) exactly the same way by then.
  useEffect(() => {
    if (!pending.current) return;
    if (phase === 'live') settle('ok');
    else if (phase === 'error') settle('fail', 'reconnectFailed');
  }, [phase, settle]);

  useEffect(() => () => {
    if (restoreTimer.current) clearTimeout(restoreTimer.current);
    if (restoreErrorTimer.current) clearTimeout(restoreErrorTimer.current);
    clearFrameWatch();
    settle('close');
  }, []);

  return { restoreToGolden };
}

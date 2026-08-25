// ============================================================================
//  sessionResume — the TRANSPORT half of coming back to the foreground
//  ---------------------------------------------------------------------------
//  Sibling of videoResume.ts, and the pair is the whole story of a black screen
//  after an app switch. videoResume asks "is our own <video> still pulling?";
//  this asks "is the session on the other end of the wire still there?".
//
//  Backgrounding throttles the 100 ms ABR tick to ~1/min and freezes it outright
//  in an installed PWA, so nothing that normally notices a dead session runs
//  while the tab is away. Recovery used to be purely reactive — wait for a tick,
//  wait out the stale threshold, wait out a backoff — which is the long black
//  area after the banner clears. Drive it from the resume event instead: one
//  grace window for a session that merely slept to prove itself, then an
//  IMMEDIATE reconnect with the backoff ladder reset.
// ============================================================================

import { sessionNeedsReconnect, RESUME_GRACE_MS, type ResumeProbeTarget } from './resumePolicy';
import { attachResumeSignals, isVisible } from './resumeSignals';
import { fetchSignal } from './signal';
import { logClientEvent } from '../clientDebug';

// ---- ERROR-PHASE RECOVERY (the "Mode D" fix, STREAM-DEBUGGING.md) ----------
//  When the retry ladder exhausts, the session parks in `phase error` behind a
//  "tap Reconnect" banner — and before this existed it parked FOREVER, even
//  after the network came back (field case 2026-08-25: an installed PWA whose
//  network plane died after a thaw; every attempt failed; the visitor stared
//  at black until a manual Reload). The visitor should never have to find the
//  button: while parked, probe the station's signaling endpoint on a slow
//  cadence (one small GET, no WebTransport, no ticket spend on failure) and
//  restart the ladder the moment it answers. A resume/online signal probes
//  immediately — coming back to the tab is exactly when recovery is wanted.
//  Bounded: a reachable box with a genuinely broken station would otherwise
//  loop ladder→park→probe→ladder forever.
export const RECOVERY_PROBE_MS = 20000;
export const MAX_RECOVERY_ROUNDS = 20;

export interface ResumeWatcherDeps {
  isCancelled(): boolean;
  /** Only a session that has PAINTED resumes; a cold connect owns its own budget. */
  isLiveReached(): boolean;
  /** fail() parked the session in `phase error`; recovery may un-park it. */
  isParked(): boolean;
  /** The station's signaling endpoint — the recovery reachability probe. */
  signalEndpoint: string;
  getClient(): ResumeProbeTarget | null;
  /** Tear the current attempt down and start a fresh ladder, no backoff. */
  reconnect(): void;
}

/** Attach the foreground-resume liveness check + the parked-error recovery
 *  probe. Returns the detach function. */
export function attachSessionResume(deps: ResumeWatcherDeps): () => void {
  let timer = 0;
  let probing = false;
  let rounds = 0;

  const probeAndRecover = async () => {
    if (probing || deps.isCancelled() || !deps.isParked() || !isVisible()) return;
    if (rounds >= MAX_RECOVERY_ROUNDS) return; // logged once below, then quiet
    probing = true;
    rounds++;
    try {
      await fetchSignal(deps.signalEndpoint);
    } catch {
      probing = false;
      if (rounds === MAX_RECOVERY_ROUNDS) {
        logClientEvent('recovery-giveup', `signaling unreachable after ${rounds} probes ep=${deps.signalEndpoint}`);
      }
      return; // still unreachable — the interval tries again
    }
    probing = false;
    // Re-check: the probe was an await and anything may have changed inside it.
    if (deps.isCancelled() || !deps.isParked() || !isVisible()) return;
    logClientEvent('recovery-reconnect', `signaling reachable again after ${rounds} probe(s) — restarting the ladder`);
    rounds = 0;
    deps.reconnect();
  };
  // Same bare-env guard as resumeSignals: on a server / bare test env there is
  // no window, no probes, and the detach below stays a harmless no-op.
  const canListen = typeof window !== 'undefined';
  const probeInterval = canListen
    ? window.setInterval(() => { void probeAndRecover(); }, RECOVERY_PROBE_MS)
    : 0;
  const onOnline = () => { void probeAndRecover(); };
  if (canListen) window.addEventListener('online', onOnline);

  const onResume = () => {
    // Parked sessions have no client to health-check — probe reachability now.
    if (deps.isParked()) { void probeAndRecover(); return; }
    if (deps.isCancelled() || timer) return;
    if (!isVisible() || !deps.isLiveReached()) return;
    timer = window.setTimeout(() => {
      timer = 0;
      void (async () => {
        if (deps.isCancelled() || !deps.isLiveReached() || !isVisible()) return;
        const c = deps.getClient();
        if (!c) return;
        const dead = await sessionNeedsReconnect(c);
        // Re-check everything: the grace window and the ping are both awaits,
        // and the visitor may have left again inside either one.
        if (deps.isCancelled() || deps.getClient() !== c || !dead || !isVisible()) return;
        deps.reconnect();
      })();
    }, RESUME_GRACE_MS);
  };
  const detach = attachResumeSignals(onResume);
  return () => {
    detach();
    if (canListen) {
      window.clearInterval(probeInterval);
      window.removeEventListener('online', onOnline);
    }
    if (timer) { clearTimeout(timer); timer = 0; }
  };
}

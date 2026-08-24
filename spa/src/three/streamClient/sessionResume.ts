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

export interface ResumeWatcherDeps {
  isCancelled(): boolean;
  /** Only a session that has PAINTED resumes; a cold connect owns its own budget. */
  isLiveReached(): boolean;
  getClient(): ResumeProbeTarget | null;
  /** Tear the current attempt down and start a fresh ladder, no backoff. */
  reconnect(): void;
}

/** Attach the foreground-resume liveness check. Returns the detach function. */
export function attachSessionResume(deps: ResumeWatcherDeps): () => void {
  let timer = 0;
  const onResume = () => {
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
    if (timer) { clearTimeout(timer); timer = 0; }
  };
}

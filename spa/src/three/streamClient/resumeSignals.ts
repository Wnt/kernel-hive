// ============================================================================
//  resumeSignals — "the visitor is looking at this again"
//  ---------------------------------------------------------------------------
//  One event set, shared by everything that has to react to a return from the
//  background, because getting the set wrong is how a resume bug survives a
//  fix. In an INSTALLED PWA on Android — the case this exists for — a return
//  from another app is not one event:
//
//    visibilitychange   the reliable one. Android delivers it on every app
//                       switch, in standalone exactly as in a tab, and it is
//                       what tells us the exhibit is on screen again.
//    pageshow           bfcache / discard restore, where the document is
//                       revived without a visibility TRANSITION — nothing else
//                       fires and the element is still paused.
//    resume             Page Lifecycle: Chrome-Android FREEZES a backgrounded
//                       PWA, and this is the only event that marks the thaw.
//                       (Paired with `freeze`, which we deliberately ignore —
//                       being paused while frozen is correct.)
//    focus              belt and braces for a restore that reinstates the
//                       window without a visibility change. Idempotent, so a
//                       duplicate costs one cheap probe.
//    pause (on the el)  the most direct signal there is: something stopped the
//                       sink. Guarded on visibility, since a pause while hidden
//                       is the UA doing the right thing. Nothing in this UI
//                       ever pauses deliberately, so there is no gesture to
//                       fight.
//
//  Every listener is a HINT, never a fact: each one re-probes the actual state
//  before acting, so firing four times on one app switch is harmless.
// ============================================================================

/** True when the document is on screen. Safe on a server / bare test env. */
export function isVisible(): boolean {
  if (typeof document === 'undefined') return true;
  return document.visibilityState === 'visible';
}

type Off = () => void;

/**
 * Fire `onResume` whenever the page may have come back to the foreground.
 * Returns the detach function.
 */
export function attachResumeSignals(onResume: () => void): Off {
  if (typeof document === 'undefined' || typeof window === 'undefined') return () => undefined;
  const hint = () => onResume();
  document.addEventListener('visibilitychange', hint);
  document.addEventListener('resume', hint);
  window.addEventListener('pageshow', hint);
  window.addEventListener('focus', hint);
  return () => {
    document.removeEventListener('visibilitychange', hint);
    document.removeEventListener('resume', hint);
    window.removeEventListener('pageshow', hint);
    window.removeEventListener('focus', hint);
  };
}

/**
 * Also react to the SINK stopping on its own. `el` is read lazily because the
 * element outlives individual sessions and may not be mounted yet.
 */
export function attachSinkPauseSignal(getEl: () => HTMLVideoElement | null, onPause: () => void): Off {
  const el = getEl();
  if (!el) return () => undefined;
  const hint = () => { if (isVisible()) onPause(); };
  el.addEventListener('pause', hint);
  return () => el.removeEventListener('pause', hint);
}

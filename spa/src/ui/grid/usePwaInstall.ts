import { useCallback, useEffect, useState } from 'react';

// Not in lib.dom yet — the install-prompt event Chromium fires when the app
// meets the installability criteria.
interface BeforeInstallPromptEvent extends Event {
  readonly platforms: string[];
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>;
}

declare global {
  interface Window {
    // Stashed by the early-capture script in index.html so a prompt that fires
    // before the SPA mounts (common on repeat visits, where the service worker
    // is already active) is not lost.
    __kernelHiveInstallPrompt?: BeforeInstallPromptEvent | null;
  }
}

// Bridge events the index.html capture dispatches so this hook, mounting later,
// still learns about a prompt that already fired.
const INSTALL_PROMPT_EVENT = 'kernelhive:installprompt';
const APP_INSTALLED_EVENT = 'kernelhive:appinstalled';

function runningStandalone(): boolean {
  try {
    return (
      window.matchMedia?.('(display-mode: standalone)').matches
      || (window.navigator as unknown as { standalone?: boolean }).standalone === true
    );
  } catch {
    return false;
  }
}

// iOS/iPadOS Safari never fires beforeinstallprompt; its only route is the Share
// sheet, so the UI falls back to instructions there.
function isIosSafari(): boolean {
  try {
    const ua = navigator.userAgent;
    const iOS = /iPad|iPhone|iPod/.test(ua)
      || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
    const chromeLike = /CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
    return iOS && !chromeLike && /Safari/.test(ua);
  } catch {
    return false;
  }
}

export interface PwaInstall {
  /** A native prompt is available and the app is not installed — show the button. */
  canInstall: boolean;
  /** Already installed / launched from the home screen. */
  installed: boolean;
  /** iOS Safari: no programmatic prompt; show Share-sheet instructions instead. */
  iosSafari: boolean;
  /** Fire the browser's native install prompt. No-op when none is pending. */
  promptInstall: () => void;
}

/**
 * PWA install affordance. Mirrors the beforeinstallprompt pattern: the event is
 * captured (and preventDefault'd) as early as index.html, stashed on window, and
 * surfaced here as `canInstall` so a footer button can fire it on demand.
 * `appinstalled` and display-mode standalone flip it to `installed`.
 */
export function usePwaInstall(): PwaInstall {
  const [deferred, setDeferred] = useState<BeforeInstallPromptEvent | null>(
    () => window.__kernelHiveInstallPrompt ?? null,
  );
  const [installed, setInstalled] = useState<boolean>(runningStandalone);

  useEffect(() => {
    const sync = () => setDeferred(window.__kernelHiveInstallPrompt ?? null);
    const onBeforePrompt = (e: Event) => {
      e.preventDefault();
      window.__kernelHiveInstallPrompt = e as BeforeInstallPromptEvent;
      setDeferred(e as BeforeInstallPromptEvent);
    };
    const onInstalled = () => {
      window.__kernelHiveInstallPrompt = null;
      setDeferred(null);
      setInstalled(true);
    };
    // The event itself (fires after mount) and the early-capture bridge (fired
    // before mount) both feed the same state.
    window.addEventListener('beforeinstallprompt', onBeforePrompt);
    window.addEventListener(INSTALL_PROMPT_EVENT, sync);
    window.addEventListener('appinstalled', onInstalled);
    window.addEventListener(APP_INSTALLED_EVENT, onInstalled);
    sync(); // pick up anything stashed before this effect ran
    return () => {
      window.removeEventListener('beforeinstallprompt', onBeforePrompt);
      window.removeEventListener(INSTALL_PROMPT_EVENT, sync);
      window.removeEventListener('appinstalled', onInstalled);
      window.removeEventListener(APP_INSTALLED_EVENT, onInstalled);
    };
  }, []);

  const promptInstall = useCallback(() => {
    const evt = window.__kernelHiveInstallPrompt ?? deferred;
    if (!evt) return;
    void evt.prompt();
    void evt.userChoice
      .then(() => {
        // A prompt is single-use; Chromium will not let us reuse the event.
        window.__kernelHiveInstallPrompt = null;
        setDeferred(null);
      })
      .catch(() => {});
  }, [deferred]);

  return {
    canInstall: !!deferred && !installed,
    installed,
    iosSafari: isIosSafari(),
    promptInstall,
  };
}

// StreamView keyboard-lock + key-forwarding predicates.
// Extracted verbatim from StreamView.tsx (pure module helpers — no React state).

type KeyboardLockApi = { lock?: (keys?: string[]) => Promise<void>; unlock?: () => void };
export const keyboardLockApi = (): KeyboardLockApi | undefined =>
  (navigator as unknown as { keyboard?: KeyboardLockApi }).keyboard;

// GFN cinema model — FULL System Keyboard Lock. GeForce NOW's fullscreen handler
// (webrtc-streaming-client.js `Ig(true)`, ~L16638) calls navigator.keyboard.lock()
// with a large CURATED key list that already includes ArrowLeft/ArrowRight. We go
// one step further and call lock() with NO ARGUMENT: that captures EVERY key the
// OS/browser would otherwise swallow (Ctrl/Cmd+Arrow = macOS Mission Control /
// move-space, F11, Cmd+W, PrintScreen, …) and delivers it to the page so we can
// forward it to the guest AND preventDefault the system action. The no-arg form is
// a strict superset of GFN's list and needs no per-combo maintenance.
//   Escape is a deliberate exception the UA enforces even under a full lock: a
// SHORT Escape keydown is still delivered to us (→ guest), while press-and-HOLD
// Escape exits fullscreen. That IS our hold-to-exit-cinema gesture, so the existing
// Escape timer/exit path keeps working unchanged.
//   lock() only actually intercepts system keys while the document is fullscreen,
// and is a graceful no-op when the API is absent (Safari/Firefox — JS-level
// keydown capture + preventDefault remains the baseline there).
export function lockAllSystemKeys(): void {
  if (!window.isSecureContext) return;
  const kb = keyboardLockApi();
  if (!kb?.lock) return;
  try { kb.lock()?.catch(() => { /* rejected — JS-level capture still applies */ }); }
  catch { /* unsupported */ }
}
export function unlockSystemKeys(): void {
  if (!window.isSecureContext) return;
  try { keyboardLockApi()?.unlock?.(); } catch { /* not supported */ }
}

// preventDefault policy — GFN's `lb()` predicate (webrtc-streaming-client.js L17082)
// preventDefaults essentially every key it forwards while streaming, so the OS/
// browser never also acts on it. We split by fullscreen:
//   WINDOWED: leave the browser's own shortcuts (Ctrl/Cmd/Alt combos, F5/F11/F12)
//     alone so the user keeps every escape hatch (System Keyboard Lock isn't active
//     outside fullscreen anyway, so there's nothing to gain by grabbing them).
//   FULLSCREEN cinema (System Keyboard Lock active): we OWN the keyboard. Prevent
//     the system default for EVERY forwarded key, INCLUDING modifier+arrow combos —
//     this is the whole fix: on macOS Ctrl+ArrowRight / Cmd+ArrowRight are Mission
//     Control "move a space" and get swallowed before the guest (DOOM) sees them.
//     Keyboard Lock delivers the key; this preventDefault kills the residual OS/
//     browser action. Cmd+W/Cmd+Q/Cmd+Tab aren't page-preventable, so this can't
//     trap the user; F11/F12 stay usable as a manual break-out.
export function needsPreventDefault(e: KeyboardEvent, fs: boolean): boolean {
  if (e.key === 'F11' || e.key === 'F12') return false;
  if (!fs) {
    if (e.ctrlKey || e.metaKey || e.altKey) return false;
    if (e.key === 'F5') return false;
    return true;
  }
  return true;
}

// The GeForce-NOW-style stats toggle: Cmd+N (mac) / Ctrl+N (win/linux), no other
// modifiers. Reliable in fullscreen where keyboard.lock hands us the key.
export function isDebugToggle(e: KeyboardEvent): boolean {
  if (!(e.metaKey || e.ctrlKey)) return false;
  if (e.altKey || e.shiftKey) return false;
  return e.code === 'KeyN' || e.key === 'n' || e.key === 'N';
}

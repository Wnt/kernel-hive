/* eslint-disable react-hooks/exhaustive-deps -- effects/callbacks are lifted
   VERBATIM from StreamView with byte-identical dependency arrays; the refs/setters
   arrive as stable params, which defeats the rule's static ref/setState stability
   inference (the original in-component code passed the rule clean). rules-of-hooks
   (the correctness rule) stays enforced. */
import { useCallback, useEffect, type Dispatch, type RefObject, type SetStateAction } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { currentFullscreenElement, enterFullscreen, leaveFullscreen } from './fullscreen';
import { lockAllSystemKeys, unlockSystemKeys } from './keyboardLock';
import { MAX_LOCK_DELTA } from './env';
import type { Vec2 } from './types';

// Fullscreen + System-Keyboard-Lock + Pointer-Lock cinema machinery (#56–62 of
// the god-component, minus revealChrome which the orchestrator owns because an
// earlier effect also needs it). Ordering, deps and listener wiring are identical.
export function useCinemaMode({
  streamable, mouseCapture, fs, pointerRel,
  containerRef, controlRef,
  releaseHeldButtons, acquireLockRef, revealChrome, requestLock, lockTargetEl, acquireLock,
  setFs, setChromeVisible, setHint, setShowResume, setPointerLocked, setFsError,
  fsErrorTimer, hideTimer, hintTimer,
  fsRef, lockedRef, wantControlRef, vcursorRef, lastGuestRef, unknownErrRef, unadjustedRef,
}: {
  streamable: boolean;
  mouseCapture: boolean;
  fs: boolean;
  pointerRel: boolean;
  containerRef: RefObject<HTMLDivElement | null>;
  controlRef: RefObject<StreamControlHandle | null>;
  releaseHeldButtons: (target?: StreamControlHandle | null) => void;
  acquireLockRef: RefObject<() => void>;
  revealChrome: () => void;
  requestLock: () => void;
  lockTargetEl: () => HTMLElement | null;
  acquireLock: () => void;
  setFs: Dispatch<SetStateAction<boolean>>;
  setChromeVisible: Dispatch<SetStateAction<boolean>>;
  setHint: Dispatch<SetStateAction<boolean>>;
  setShowResume: Dispatch<SetStateAction<boolean>>;
  setPointerLocked: Dispatch<SetStateAction<boolean>>;
  setFsError: Dispatch<SetStateAction<string | null>>;
  fsErrorTimer: RefObject<number>;
  hideTimer: RefObject<number>;
  hintTimer: RefObject<number>;
  fsRef: RefObject<boolean>;
  lockedRef: RefObject<boolean>;
  wantControlRef: RefObject<boolean>;
  vcursorRef: RefObject<Vec2 | null>;
  lastGuestRef: RefObject<Vec2 | null>;
  unknownErrRef: RefObject<number>;
  unadjustedRef: RefObject<boolean>;
}): { toggleFullscreen: () => void } {
  // ---- keyboard.lock (re)assert — capture system keys (Esc/F11/combos) so they
  //  reach the guest. Only effective inside fullscreen + a secure context; a
  //  no-op elsewhere. Called on mount AND re-asserted whenever we enter FS.
  const relockKeyboard = useCallback(() => {
    if (!streamable) return;
    lockAllSystemKeys();
  }, [streamable]);

  // ---- FULLSCREEN (container) — keeps keyboard.lock + control inside FS ------
  //  Uses the cross-browser shim (unprefixed OR webkit) and LOGS rejections
  //  instead of hiding them — the root cause of "nothing happens on Fullscreen".
  const toggleFullscreen = useCallback(() => {
    const el = containerRef.current;
    if (!el) return;
    if (!currentFullscreenElement()) {
      enterFullscreen(el)
        .then(() => {
          relockKeyboard();
          // Pointer-lock is acquired from the `fullscreenchange` handler (below),
          // NOT here: Chrome rejects requestPointerLock issued in this async
          // post-fullscreen continuation (the click's transient activation is spent),
          // whereas it treats the fullscreenchange event as validly activated.
        })
        .catch((err) => {
          // Surface it: console for diagnosis + a brief on-screen toast.
          console.warn('[StreamView] requestFullscreen rejected:', err);
          setFsError(
            (err as Error)?.message
              ? `Fullscreen blocked: ${(err as Error).message}`
              : 'Fullscreen was blocked by the browser',
          );
          if (fsErrorTimer.current) clearTimeout(fsErrorTimer.current);
          fsErrorTimer.current = window.setTimeout(() => setFsError(null), 5000);
        });
    } else {
      leaveFullscreen().catch((err) => {
        console.warn('[StreamView] exitFullscreen rejected:', err);
      });
    }
  }, [relockKeyboard]);
  // Clear the fullscreen-rejection toast timer on unmount.
  useEffect(() => () => { if (fsErrorTimer.current) clearTimeout(fsErrorTimer.current); }, []);
  useEffect(() => {
    // Track BOTH the unprefixed and webkit change events; on WebKit only the
    // prefixed one fires, and without it `fs` never flips (the old bug).
    const onFsChange = () => {
      const isFs = currentFullscreenElement() === containerRef.current;
      // A fullscreen transition may consume pointerup. Release before changing
      // coordinate/capture modes so a held guest button cannot survive it.
      releaseHeldButtons();
      setFs(isFs);
      // Hide the bar in the SAME batched update as setFs(true) so it is never
      // painted for even one frame on fullscreen-enter (the FS effect below also
      // sets this, but one render later — which flashed the bar).
      if (isFs) setChromeVisible(false);
      // Acquire whole-mouse capture HERE (streamhost stations): Chrome honours
      // requestPointerLock from a fullscreenchange handler but rejects it from the
      // async post-fullscreen promise continuation. mouseCapture is constant for
      // the component's life (key={osId} remounts per station), so the []-deps closure
      // is safe; acquireLockRef keeps the callback itself fresh.
      if (isFs && mouseCapture) acquireLockRef.current();
    };
    document.addEventListener('fullscreenchange', onFsChange);
    document.addEventListener('webkitfullscreenchange', onFsChange);
    return () => {
      document.removeEventListener('fullscreenchange', onFsChange);
      document.removeEventListener('webkitfullscreenchange', onFsChange);
    };
  }, [mouseCapture, releaseHeldButtons]);

  // ---- ENTERING FULLSCREEN: no-banner + hint toast + top-edge reveal --------
  useEffect(() => {
    fsRef.current = fs;
    if (!fs) {
      // Windowed: chrome always present; clear any pending timers/toast.
      setChromeVisible(true);
      setHint(false);
      if (hideTimer.current) { clearTimeout(hideTimer.current); hideTimer.current = 0; }
      if (hintTimer.current) { clearTimeout(hintTimer.current); hintTimer.current = 0; }
      // Leaving fullscreen tears down whole-mouse capture: release the lock and
      // clear all capture intent so the windowed path is a normal free pointer.
      wantControlRef.current = false;
      lockedRef.current = false;
      vcursorRef.current = null;
      setShowResume(false);
      // Release the System Keyboard Lock on FS exit (GFN Ig(false) → keyboard.unlock).
      // Outside fullscreen the lock is inert anyway, and holding it can keep the UA
      // from restoring normal Ctrl/Cmd shortcuts once the user is back in the grid.
      unlockSystemKeys();
      try { if (document.pointerLockElement) document.exitPointerLock?.(); } catch { /* noop */ }
      // Dropping keyboard.lock / pointer-lock on FS exit (incl. the GFN hold-Esc
      // gesture, which never blurs the window) must flush every held scancode —
      // otherwise the guest keeps a stuck Esc-down (0x01) / modifier. releaseAllKeys
      // sends key-up for each down scancode and clears the set.
      try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
      releaseHeldButtons();
      return;
    }
    // Fullscreen: hide chrome, show the auto-dismissing hint once.
    // Re-assert keyboard.lock now that we are actually in FS (it only captures
    // system keys — Esc/F11/⌘combos — while fullscreen is active).
    relockKeyboard();
    setChromeVisible(false);
    setHint(true);
    if (hintTimer.current) clearTimeout(hintTimer.current);
    hintTimer.current = window.setTimeout(() => setHint(false), 4000);

    const el = containerRef.current;
    if (!el) return;
    // Reveal the floating bar only when the pointer reaches the very top edge —
    // so ordinary guest control in the middle never resurrects the banner.
    // Ignore edge-reveal while the pointer is captured: under lock clientX/Y are
    // frozen at the click point (the top-bar Fullscreen button, clientY<=44), so
    // every movement would falsely re-reveal the bar during captured cinema play.
    // Captured (streamhost) stations get NO passive edge-reveal: any moment the lock
    // is not engaged the local cursor could drift into the top 44px and resurrect
    // the bar. The ONLY deliberate reveal for a captured station is Cmd/Ctrl+N.
    if (!mouseCapture) {
      const onMove = (e: PointerEvent) => { if (e.clientY <= 44) revealChrome(); };
      el.addEventListener('pointermove', onMove);
      return () => {
        el.removeEventListener('pointermove', onMove);
        if (hintTimer.current) { clearTimeout(hintTimer.current); hintTimer.current = 0; }
      };
    }
    return () => {
      if (hintTimer.current) { clearTimeout(hintTimer.current); hintTimer.current = 0; }
    };
  }, [fs, revealChrome, relockKeyboard, mouseCapture, releaseHeldButtons]);

  // ---- POINTER-LOCK reconcile: change/error listeners + locked motion feed ---
  //  A single effect owns the pointerlockchange / pointerlockerror lifecycle and
  //  the movementX/Y integrator. It mirrors GFN's Pp() (change) / _p() (error)
  //  handlers and the mouse-input.js locked-move loop, with TWO send modes:
  //   - ABSOLUTE stations (default): accumulate + clamp a virtual cursor and
  //     sendMouseMove(abs); the daemon relativizes PS/2 stations server-side via its
  //     homing bridge.
  //   - pointerRel stations (qnx/freedos/msdoswin1, daemon SH_POINTER=rel): ship the
  //     raw movementX/Y as DIRECT type=4 RelMotion datagrams (sendMouseMoveRel)
  //     for true 1:1 tracking — see onLockedMove below.
  useEffect(() => {
    if (!mouseCapture) return;

    const onLockChange = () => {
      const target = lockTargetEl();
      const locked = !!target && document.pointerLockElement === target;
      lockedRef.current = locked;
      setPointerLocked(locked);
      if (locked) {
        // GFN .then() success: reset the post-Esc backoff, drop the resume UI.
        unknownErrRef.current = 0;
        setShowResume(false);
        // Seed the virtual cursor: last known guest point, else screen centre.
        const r = controlRef.current?.getResolution();
        const seed =
          lastGuestRef.current ??
          (r ? { x: Math.floor(r.w / 2), y: Math.floor(r.h / 2) } : { x: 0, y: 0 });
        vcursorRef.current = { x: seed.x, y: seed.y };
      } else {
        // GFN on-loss: clear want-control (a fresh click is required to re-lock)
        // and — only if we are STILL the fullscreen element (i.e. NOT a deliberate
        // hold-Esc FS exit, which drops the lock too) — reveal chrome + the
        // "Click to resume control" affordance. Read the live DOM (not stale React
        // state) so an FS-exit doesn't briefly flash the resume overlay.
        wantControlRef.current = false;
        // Esc that drops pointer lock is eaten by the UA with no keyup (and may not
        // fire an FS change) — flush held scancodes so it can't stick down.
        try { controlRef.current?.releaseAllKeys(); } catch { /* noop */ }
        releaseHeldButtons();
        if (currentFullscreenElement() === containerRef.current) {
          if (mouseCapture) setShowResume(true);
          revealChrome();
        }
      }
    };

    const onLockError = () => {
      // Mirror GFN _p(): downgrade unadjustedMovement once, then fall back to the
      // resume affordance rather than busy-retrying.
      if (unadjustedRef.current) { unadjustedRef.current = false; requestLock(); }
      else if (fsRef.current && mouseCapture) setShowResume(true);
    };

    // Locked motion → accumulated absolute virtual cursor (streamhost only).
    const onLockedMove = (e: MouseEvent) => {
      if (!lockedRef.current || !mouseCapture) return;
      const h = controlRef.current;
      const vc = vcursorRef.current;
      if (!h || !vc) return;
      let dx = e.movementX || 0;
      let dy = e.movementY || 0;
      if (dx === 0 && dy === 0) return;                       // GFN dr rule (a)
      // Chrome emits one bogus large delta on lock-engage/focus transitions.
      // Clamp per-axis (don't drop the whole event) so real motion still advances.
      if (Math.abs(dx) > MAX_LOCK_DELTA) dx = Math.sign(dx) * MAX_LOCK_DELTA;
      if (Math.abs(dy) > MAX_LOCK_DELTA) dy = Math.sign(dy) * MAX_LOCK_DELTA;
      // RELATIVE-POINTER stations: ship the raw delta as a DIRECT type=4 RelMotion
      // (no abs virtual cursor, no homing bridge). This is the real 1:1 fix for
      // qnx/freedos/msdoswin1 — the guest advances its own cursor by exactly dx/dy.
      if (pointerRel && h.sendMouseMoveRel) {
        h.sendMouseMoveRel(Math.round(dx), Math.round(dy));
        return;
      }
      const r = h.getResolution();
      const maxX = Math.max(0, (r?.w ?? 1) - 1);
      const maxY = Math.max(0, (r?.h ?? 1) - 1);
      vc.x = Math.min(Math.max(vc.x + dx, 0), maxX);          // GFN Nm() clamp
      vc.y = Math.min(Math.max(vc.y + dy, 0), maxY);
      lastGuestRef.current = { x: vc.x, y: vc.y };
      h.sendMouseMove(Math.round(vc.x), Math.round(vc.y));
    };

    document.addEventListener('pointerlockchange', onLockChange);
    document.addEventListener('mozpointerlockchange', onLockChange);
    document.addEventListener('pointerlockerror', onLockError);
    document.addEventListener('mozpointerlockerror', onLockError);
    window.addEventListener('mousemove', onLockedMove);

    return () => {
      document.removeEventListener('pointerlockchange', onLockChange);
      document.removeEventListener('mozpointerlockchange', onLockChange);
      document.removeEventListener('pointerlockerror', onLockError);
      document.removeEventListener('mozpointerlockerror', onLockError);
      window.removeEventListener('mousemove', onLockedMove);
    };
  }, [mouseCapture, lockTargetEl, requestLock, acquireLock, revealChrome, pointerRel, releaseHeldButtons]);

  return { toggleFullscreen };
}

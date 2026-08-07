import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import type { ArmMode } from '../../../input/touchGestures';
import { autoModel, isPrecisePointer } from '../../../input/pointerModeAuto';
import { useTouchGestures, type TouchBadgeState, type TouchGestureController } from './useTouchGestures';
import { coachSeen, markCoachSeen } from './coachmark';
import { isTouchDevice } from './env';
import type { PresentAspect } from '../presentAspect';
import type { GestureState, Vec2 } from './types';

// ---------------------------------------------------------------------------
//  useTouchControl — the StreamView-facing touch aggregator (T-3/T-4/T-5).
//  ---------------------------------------------------------------------------
//  Keeps StreamView.tsx thin (it is at its line budget): this hook owns which
//  touch model is live, the shared refs the touch overlays read imperatively (the
//  abs virtual cursor + the loupe pointer snapshot), the pen-hover throttle clock,
//  and the gesture-initiated Paste. The actual recognizer/trackpad engines live
//  under useTouchGestures.
//
//  TRACKPAD IS THE DEFAULT on a touch device (2026-08-05): most visitors have no
//  stylus, and a fingertip on a phone covers ~90 guest px of a 1288×1024 exhibit
//  it is trying to point at. The model then FOLLOWS THE DEVICE — an S-Pen coming
//  into hover range switches to direct pointing before its tip even lands, a
//  finger hands the surface back. That policy is input/pointerModeAuto; this hook
//  supplies it with events and a clock, and owns the two side effects a switch
//  has: seeding the virtual cursor where the guest pointer actually is, and
//  updating trackpadRef SYNCHRONOUSLY so the very event that caused the switch is
//  already handled in the new model (these listeners are on window in the capture
//  phase, so they run before the surface's own handlers).
//
//  Using the ⋯ menu's toggle PINS the model: an explicit choice is never undone
//  by the auto rule. The pin lasts for this stream (a new tile remounts the hook).
// ---------------------------------------------------------------------------

export interface TouchControl {
  controller: TouchGestureController;
  badge: TouchBadgeState;
  setArm: (mode: ArmMode) => void;
  /** current touch model — trackpad (relative) vs direct (absolute). */
  trackpadMode: boolean;
  /** flip the model AND pin it, so the auto rule stops changing it. */
  toggleTrackpad: () => void;
  /** live mirror of trackpadMode for the event handlers (no stale closures). */
  trackpadRef: RefObject<boolean>;
  /** abs virtual-cursor position in guest px (OnScreenCursor sprite). */
  cursorRef: RefObject<Vec2 | null>;
  /** the trackpad is dragging with its button held — the sprite paints it. */
  heldRef: RefObject<boolean>;
  /** last-forwarded pen-hover timestamp for the abs-tile throttle. */
  penHoverRef: RefObject<number>;
  /** paste clipboard text into the guest — MUST be called from a user gesture. */
  paste: () => void;
  /** the touch-help coachmark is showing (auto once, or re-opened from the ⋯ menu). */
  helpOpen: boolean;
  /** re-open the touch-help coachmark (⋯ menu). */
  showHelp: () => void;
  /** dismiss the coachmark + persist the seen-flag. */
  dismissHelp: () => void;
}

export function useTouchControl({
  pointerRel,
  controlRef,
  pressedButtonsRef,
  lastGuestRef,
  gestureRef,
  stageRef,
  presentAspect,
}: {
  pointerRel: boolean;
  controlRef: RefObject<StreamControlHandle | null>;
  pressedButtonsRef: RefObject<Set<number>>;
  /** Last guest point the surface pointed at — where a switch seeds the cursor. */
  lastGuestRef: RefObject<Vec2 | null>;
  /** Live pinch-zoom transform; the trackpad scales its gain by the magnification. */
  gestureRef: RefObject<GestureState>;
  /** The stage the picture is drawn in — measured to keep pointer speed the same
   *  on every exhibit whatever its resolution (input/trackpad setTrack). */
  stageRef: RefObject<HTMLDivElement | null>;
  presentAspect: PresentAspect | null;
}): TouchControl {
  // Rel-pointer tiles are BROKEN under direct absolute touch (a tap teleports a
  // cursor the guest draws from deltas), so they are trackpad-only. Every other
  // touch device starts on the trackpad too; a desktop pointer starts direct.
  const [trackpadMode, setTrackpadMode] = useState(() => pointerRel || isTouchDevice());
  const trackpadRef = useRef(trackpadMode);
  const cursorRef = useRef<Vec2 | null>(null);
  const heldRef = useRef(false);
  const penHoverRef = useRef(0);
  /** The ⋯ toggle was used: the auto rule stops overriding the visitor. */
  const pinnedRef = useRef(false);

  const gestures = useTouchGestures({
    controlRef, pressedButtonsRef, pointerRel, trackpadRef, cursorRef, heldRef, gestureRef,
    stageRef, presentAspect,
  });
  const { controller } = gestures;

  // Coachmark: auto-show once (first live tile), re-openable from the ⋯ menu.
  const [helpOpen, setHelpOpen] = useState(() => !coachSeen());
  const showHelp = useCallback(() => setHelpOpen(true), []);
  const dismissHelp = useCallback(() => { markCoachSeen(); setHelpOpen(false); }, []);

  // ONE writer for the model, so the ref and the React state can never disagree
  // (the ref is what the event handlers read, and they read it mid-event).
  const setTrackpad = useCallback((on: boolean) => {
    if (trackpadRef.current === on) return;
    // Hand the outgoing engine a cancel first. A switch can land mid-contact (a
    // pen brought into hover range while a finger is still down), and the release
    // would then be routed to the OTHER engine, which knows nothing about it —
    // leaving the button held in the guest with nothing on the glass.
    controller.cancel();
    // Entering the trackpad: put its virtual cursor where the guest pointer is,
    // so the sprite is not somewhere else than the click it is about to make.
    if (on) {
      const g = lastGuestRef.current;
      if (g) controller.seedCursor(g.x, g.y);
    }
    trackpadRef.current = on;
    setTrackpadMode(on);
  }, [controller, lastGuestRef]);

  const toggleTrackpad = useCallback(() => {
    pinnedRef.current = true;
    setTrackpad(!trackpadRef.current);
  }, [setTrackpad]);

  // ---- MODEL FOLLOWS THE DEVICE (input/pointerModeAuto) ---------------------
  //  Window + capture phase so a switch is already in force for the very event
  //  that triggered it, and so an S-Pen hovering anywhere over the page counts.
  //  The handler is deliberately allocation-free: for the overwhelmingly common
  //  event (a hover sample in the model we are already in) it is two comparisons
  //  and a return, which is what keeps a desktop mouse stream free of cost.
  useEffect(() => {
    if (pointerRel) return; // rel tiles have no second model to switch to
    const preciseAt = { ms: -Infinity };
    const onPointer = (e: PointerEvent) => {
      if (pinnedRef.current) return;
      const nowMs = performance.now();
      if (isPrecisePointer(e.pointerType)) preciseAt.ms = nowMs;
      const model = autoModel({
        pointerType: e.pointerType,
        isDown: e.type === 'pointerdown',
        nowMs,
        preciseAtMs: preciseAt.ms,
        model: trackpadRef.current ? 'trackpad' : 'direct',
      });
      setTrackpad(model === 'trackpad');
    };
    const types = ['pointerdown', 'pointermove', 'pointerover'];
    const on = onPointer as EventListener;
    for (const t of types) window.addEventListener(t, on, true);
    return () => { for (const t of types) window.removeEventListener(t, on, true); };
  }, [pointerRel, setTrackpad]);

  const paste = useCallback(() => {
    const h = controlRef.current;
    if (!h) return;
    // The clipboard read must run inside the tap's user-activation, so kick it off
    // synchronously here (typeText is ASCII-only — a documented limitation).
    void h.getClipboard().then((t) => { if (t) h.typeText(t); }).catch(() => { /* denied */ });
  }, [controlRef]);

  return {
    controller: gestures.controller,
    badge: gestures.badge,
    setArm: gestures.setArm,
    trackpadMode,
    toggleTrackpad,
    trackpadRef,
    cursorRef,
    heldRef,
    penHoverRef,
    paste,
    helpOpen,
    showHelp,
    dismissHelp,
  };
}

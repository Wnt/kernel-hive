import { useCallback, useEffect, useRef, useState, type RefObject } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import {
  createRecognizer,
  intentToOps,
  type ArmMode,
  type GestureIntent,
  type Recognizer,
} from '../../../input/touchGestures';
import { createTrackpad, TAP_RELEASE_MS, type Trackpad, type TrackpadOp } from '../../../input/trackpad';
import { contentRectFor, type Resolution } from '../letterbox';
import { hapticTap } from '../../keyboard/haptics';
import type { PresentAspect } from '../presentAspect';
import type { GestureState, Vec2 } from './types';

/** How many GUEST px one CSS px of the DISPLAYED picture covers (input/trackpad
 *  setTrack). Measured, not assumed: the picture is letterboxed inside the stage,
 *  and an era-correct station is stretched into a display-aspect box whose width has
 *  nothing to do with its framebuffer's. Falls back to 1:1 before layout exists,
 *  which is only ever a frame before the first contact. */
function guestPerCssPx(box: HTMLElement | null, res: Resolution, display: PresentAspect | null): number {
  const w = box?.offsetWidth ?? 0;
  const h = box?.offsetHeight ?? 0;
  if (w <= 0 || h <= 0 || res.w <= 0) return 1;
  const content = contentRectFor(w, h, display ?? res);
  return content.width > 0 ? res.w / content.width : 1;
}

// ---------------------------------------------------------------------------
//  useTouchGestures — the thin DOM/React shell around the PURE single-finger
//  engines. It owns the one thing they deliberately do NOT: expanding emitted
//  intents onto the live StreamControlHandle. It carries BOTH engines and
//  switches per-event on trackpadRef (T-3):
//    - DIRECT mode → the absolute-coordinate recognizer (input/touchGestures).
//    - TRACKPAD mode → the relative / virtual-cursor engine (input/trackpad):
//      rel stations ship sendMouseMoveRel; abs stations drive a local cursor sprite.
//  useStreamInput's touch branch drives it with BOTH the guest px (recognizer)
//  and the raw CSS px (trackpad deltas); the returned `badge` + `setArm` back
//  the on-screen armed-state chip, which BOTH models use for right-click.
// ---------------------------------------------------------------------------

/** Imperative sink useStreamInput calls for each single-finger touch event.
 *  `x,y` are GUEST px (recognizer); `cx,cy` are raw viewport CSS px (trackpad). */
export interface TouchGestureController {
  /** `right` = an S-Pen barrel press → right-click (direct mode only). */
  begin(id: number, x: number, y: number, t: number, cx: number, cy: number, right?: boolean): void;
  move(id: number, x: number, y: number, t: number, cx: number, cy: number): void;
  end(id: number, x: number, y: number, t: number, cx: number, cy: number): void;
  /** pointercancel — the touch was stolen (e.g. a 2nd finger began a pinch). */
  cancel(): void;
  /** CONSUME the one-shot right-click arm, if the badge has one set.
   *
   *  The badge (TouchControlBadge) sets the arm on the recognizer, but a STYLUS
   *  never reaches the recognizer — `pointerType` is 'pen', so useStreamInput's
   *  mouse branch handles it — and the arm was therefore invisible to the one
   *  input that needs it most. On this device the S-Pen barrel cannot produce a
   *  right-DRAG at all: Android eats the press (no pointerdown, no contextmenu,
   *  measured 2026-08-05), so the barrel gives a right CLICK and nothing more.
   *  The arm is how a stylus gets a right press-drag-release with real motion —
   *  which is what a spring-loaded Motif menu needs. This was the agreed fallback
   *  when the barrel was first investigated (88393d0, 2026-07-26). */
  takeArm(): boolean;
  /** Put the trackpad's virtual cursor at a GUEST point (input/trackpad
   *  setCursor). Called when the surface switches into trackpad mode, so the
   *  sprite appears where the stylus left the guest pointer rather than at a
   *  stale centre. */
  seedCursor(x: number, y: number): void;
}

/** Current arming state, mirrored into React state for the badge. */
export interface TouchBadgeState {
  armMode: ArmMode;
}

export function useTouchGestures({
  controlRef,
  pressedButtonsRef,
  pointerRel,
  trackpadRef,
  cursorRef,
  heldRef,
  gestureRef,
  stageRef,
  presentAspect,
}: {
  controlRef: RefObject<StreamControlHandle | null>;
  pressedButtonsRef: RefObject<Set<number>>;
  pointerRel: boolean;
  trackpadRef: RefObject<boolean>;
  cursorRef: RefObject<Vec2 | null>;
  /** The trackpad is dragging with its button held — the sprite paints it. */
  heldRef: RefObject<boolean>;
  /** Live local view transform — only `.s` is read, per contact (see below). */
  gestureRef: RefObject<GestureState>;
  /** The stage the picture is drawn in — measured per contact for the gain. */
  stageRef: RefObject<HTMLDivElement | null>;
  /** Era-correct display box, when the station has one (presentAspect.ts). */
  presentAspect: PresentAspect | null;
}): {
  controller: TouchGestureController;
  badge: TouchBadgeState;
  setArm: (mode: ArmMode) => void;
} {
  const [armMode, setArmMode] = useState<ArmMode>('none');
  const recognizerRef = useRef<Recognizer | null>(null);
  const trackpadEngineRef = useRef<Trackpad | null>(null);
  const controllerRef = useRef<TouchGestureController | null>(null);
  const releaseTimer = useRef(0); // trackpad deferred tap-release deadline

  // Engines + controller are built ONCE (refs, not effects) so the imperative
  // sink handed to useStreamInput is stable across renders.
  if (!recognizerRef.current) {
    recognizerRef.current = createRecognizer({
      onChange: () => {
        const r = recognizerRef.current;
        if (r) setArmMode(r.getArm());
      },
    });
  }
  if (!trackpadEngineRef.current) {
    trackpadEngineRef.current = createTrackpad({
      rel: pointerRel,
      onCursor: (c) => { cursorRef.current = c; },
      onHold: (h) => { heldRef.current = h; },
    });
  }

  if (!controllerRef.current) {
    const rec = recognizerRef.current;
    const tp = trackpadEngineRef.current;
    // Expand recognizer intents onto the shared control handle. Route button-0
    // through pressedButtonsRef so the component's existing teardown / blur /
    // visibility flush (releaseHeldButtons) can never leave a drag stuck down.
    const apply = (intents: GestureIntent[]) => {
      const h = controlRef.current;
      if (!h) return;
      for (const it of intents) {
        for (const op of intentToOps(it)) {
          if (op.kind === 'move') { h.sendMouseMove(op.x, op.y); continue; }
          if (op.down) hapticTap(); // a click landed — same pulse as a key
          if (op.button === 0) {
            if (op.down) pressedButtonsRef.current.add(0);
            else pressedButtonsRef.current.delete(0);
          }
          // reposition:false = a pure button record (the tight double-click
          // burst). Omitting the coords skips the abs move that precedes a
          // positioned button, which is what stops the daemon's warpd
          // button-guard re-arming between the two clicks and spreading them
          // back out. The cursor is already on the spot.
          if (op.reposition === false) h.sendMouseButton(op.button, op.down);
          else h.sendMouseButton(op.button, op.down, op.x, op.y);
        }
      }
    };
    // Expand trackpad ops: RelMotion for rel stations, abs move + click for abs stations.
    const applyTp = (ops: TrackpadOp[]) => {
      const h = controlRef.current;
      if (!h) return;
      for (const op of ops) {
        if (op.kind === 'rel') { h.sendMouseMoveRel?.(op.dx, op.dy); continue; }
        if (op.kind === 'move') { h.sendMouseMove(op.x, op.y); continue; }
        // ONE PULSE PER BUTTON-DOWN, which is what makes a double-click feel
        // like two quick taps without any pattern being scripted: it IS two
        // clicks, so it buzzes twice, in the visitor's own tapping rhythm. A
        // canned two-pulse burst could only fire on the SECOND tap — the first
        // has already been felt by then — and would land as three. A drag stays
        // one pulse: it inherits the press it was given and opens no new one.
        if (op.down) hapticTap();
        // EVERY button, not just 0: a trackpad right-drag holds button 2, and a
        // button missing from this set is one releaseHeldButtons cannot flush on
        // blur / tab-hide — i.e. one that stays down in the guest.
        if (op.down) pressedButtonsRef.current.add(op.button);
        else pressedButtonsRef.current.delete(op.button);
        h.sendMouseButton(op.button, op.down, op.x, op.y);
      }
    };
    // CONSUME the badge's one-shot arm. The recognizer owns the arm state for
    // both engines, so there is exactly one armed flag and one badge to repaint.
    const takeArm = () => {
      if (rec.getArm() !== 'right-click') return false;
      rec.setArm('none');
      return true;
    };
    const clearRelease = () => {
      if (releaseTimer.current) { clearTimeout(releaseTimer.current); releaseTimer.current = 0; }
    };
    controllerRef.current = {
      begin(id, x, y, t, cx, cy, right) {
        // This contact may be about to INHERIT the pending click, so stop the
        // release before anything else — the engine decides, and it must not be
        // racing a timer while it does.
        clearRelease();
        // SELF-HEAL (stuck-button guard): if a previous touch's button-up was lost
        // — a browser gesture stealing the pointerup, or the OS eating it on an
        // app-switch — a button can stay held DOWN in the guest, and the next touch
        // would then DRAG instead of click (the "mouse stuck down" bug). Release
        // anything stranded before starting this touch so a tap can never stick.
        // releaseHeldButtons (blur/hide) is the outer net; this is the per-touch net.
        //
        // ASK THE TRACKPAD FIRST. It holds a button between contacts ON PURPOSE —
        // a tap's release is deferred so the next contact can inherit the press —
        // and to this guard that is indistinguishable from a leak. Healing it
        // blind sent the up that tap-then-hold exists to withhold, so the drag
        // began with nothing held and only glided the cursor.
        if (!(trackpadRef.current && tp.holds())) {
          for (const btn of pressedButtonsRef.current) {
            // Coordinate-free in TRACKPAD mode: a guest-px release taken from the
            // fingertip would teleport the very cursor this mode exists to keep put.
            if (trackpadRef.current) controlRef.current?.sendMouseButton(btn, false);
            else controlRef.current?.sendMouseButton(btn, false, x, y);
          }
          pressedButtonsRef.current.clear();
        }
        if (trackpadRef.current) {
          const res = controlRef.current?.getResolution() ?? { w: 0, h: 0 };
          tp.setBounds(res);
          // Re-read the picture's scale per contact: the exhibit can change
          // resolution and the stage can be resized or rotated under us.
          tp.setTrack(guestPerCssPx(stageRef.current, res, presentAspect));
          // Re-read the live pinch-zoom scale per contact: zoomed in, the same
          // finger travel must cover the same distance ON GLASS, so the cursor
          // gets finer the further the visitor magnifies.
          tp.setScale(gestureRef.current.s);
          // The ⊕ arm is the ONLY right-click here, and it also chooses the
          // button a tap-then-hold drags with — so armed, tap, hold and drag is
          // a real right press-drag-release.
          applyTp(tp.begin(id, cx, cy, t, right || takeArm()));
        } else {
          // Direct absolute: button DOWN immediately (drawing/dragging starts on
          // contact) — right-click when the S-Pen barrel is pressed or armed.
          apply(rec.begin({ id, x, y, cx, cy, t }, right));
        }
      },
      move(id, x, y, t, cx, cy) {
        if (trackpadRef.current) applyTp(tp.move(id, cx, cy));
        else apply(rec.move({ id, x, y, cx, cy, t }));
      },
      end(id, x, y, t, cx, cy) {
        clearRelease();
        if (!trackpadRef.current) { apply(rec.end({ id, x, y, cx, cy, t })); return; }
        applyTp(tp.end(id, t));
        // A tap leaves its button DOWN, waiting to see whether the next contact
        // inherits it. Nothing else on the glass can close it, so this timer is
        // the only thing that will — schedule it unconditionally; tapRelease()
        // is a no-op when there is nothing pending.
        releaseTimer.current = window.setTimeout(() => {
          releaseTimer.current = 0;
          applyTp(tp.tapRelease());
        }, TAP_RELEASE_MS);
      },
      takeArm,
      seedCursor(x, y) {
        tp.setBounds(controlRef.current?.getResolution() ?? { w: 0, h: 0 });
        tp.setCursor({ x, y });
      },
      cancel() {
        clearRelease();
        // Only one engine is ever active, so cancelling both is a safe no-op on
        // the idle one (each returns [] when it holds no touch).
        applyTp(tp.cancel());
        apply(rec.cancel());
      },
    };
  }

  const setArm = useCallback((mode: ArmMode) => {
    recognizerRef.current?.setArm(mode);
  }, []);

  // Never let a pending release fire into a torn-down surface. (The button it
  // would have closed is flushed by releaseHeldButtons on the way out.)
  useEffect(() => () => { if (releaseTimer.current) clearTimeout(releaseTimer.current); }, []);

  return {
    controller: controllerRef.current,
    badge: { armMode },
    setArm,
  };
}

/* eslint-disable react-hooks/exhaustive-deps -- lifted VERBATIM from
   useStreamInput with a byte-identical dependency array. */
import { useEffect, type Dispatch, type RefObject, type SetStateAction } from 'react';
import type { StreamControlHandle } from '../../../three/useStreamControl';
import { isTouchDevice } from './env';
import { classifyTwoFinger, scrollWheelDelta } from '../../../input/touchGestures';
import type { GestureState, Vec2, ZoomState } from './types';

// The LOCAL view transform: two-finger pinch/pan and the pinch-vs-scroll
// arbitration. Split out of useStreamInput because it is a separate job — it
// never calls a send primitive except the arbitrated guest wheel, and it is the
// only part of that file concerned with what the VISITOR sees rather than with
// what the guest receives.
export function usePinchZoom({
  streamable, live, directCanvas, setZoom,
  controlRef, containerRef, videoRef, canvasRef, zoomPointersRef, gestureRef,
  trackpadRef, stageRef,
}: {
  streamable: boolean;
  live: boolean;
  directCanvas: boolean;
  setZoom: Dispatch<SetStateAction<ZoomState>>;
  controlRef: RefObject<StreamControlHandle | null>;
  containerRef: RefObject<HTMLDivElement | null>;
  videoRef: RefObject<HTMLVideoElement | null>;
  canvasRef: RefObject<HTMLCanvasElement | null>;
  zoomPointersRef: RefObject<Map<number, Vec2>>;
  gestureRef: RefObject<GestureState>;
  // TRACKPAD MODE splits the two jobs cleanly by finger count: ONE finger is the
  // trackpad and nothing else, TWO fingers are the viewport and nothing else.
  //   - no single-finger view pan, even zoomed in — that gesture is the pointer,
  //     and stealing it once the visitor zooms would take the pointer away
  //     exactly when they are working closely;
  //   - no pinch-vs-scroll arbitration, so a two-finger drag NEVER reaches the
  //     guest as a wheel. It pans the magnified picture instead.
  // Direct mode keeps both, unchanged. The stage (picture + letterbox bars) is
  // the gesture surface in trackpad mode, matching the pointer surface.
  trackpadRef: RefObject<boolean>;
  stageRef: RefObject<HTMLDivElement | null>;
}) {
  // ---- CLIENT-SIDE PINCH-ZOOM + PAN (Item 5) — LOCAL view transform ONLY ------
  //  A self-contained two-finger pinch (scale 1..3, snap to 1 below 1.1×) + pan,
  //  and single-finger pan while zoomed, applied as a CSS transform on the <video>.
  //  It NEVER calls any send primitive — it is pure local magnification (makes
  //  640×480 / 720×400 retro stations legible on a phone). Listeners sit in the
  //  CAPTURE phase on the container (an ancestor of the <video>): while a gesture
  //  is active they stopPropagation, so the existing guest pointer-forwarder on the
  //  <video> never fires and NO input datagrams are sent. A single finger at scale 1
  //  is passed through untouched so normal touch control still works; when a second
  //  finger starts a pinch we synth-cancel that pass-through touch so it can't stick.
  useEffect(() => {
    if (!streamable || !isTouchDevice()) return;
    const root = containerRef.current;
    const vid: HTMLElement | null = directCanvas ? canvasRef.current : videoRef.current;
    if (!root || !vid) return;

    const pointers = zoomPointersRef.current;
    const g = gestureRef.current;
    const hypot = (a: { x: number; y: number }, b: { x: number; y: number }) => Math.hypot(a.x - b.x, a.y - b.y);
    const mid = (a: { x: number; y: number }, b: { x: number; y: number }) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
    const twoPoints = (): [{ x: number; y: number }, { x: number; y: number }] | null => {
      const it = pointers.values();
      const a = it.next().value; const b = it.next().value;
      return a && b ? [a, b] : null;
    };
    const clampPan = (s: number, x: number, y: number) => {
      const w = vid.offsetWidth || 1, h = vid.offsetHeight || 1;
      const mx = Math.max(0, ((s - 1) * w) / 2);
      const my = Math.max(0, ((s - 1) * h) / 2);
      return { x: Math.min(Math.max(x, -mx), mx), y: Math.min(Math.max(y, -my), my) };
    };

    const onDown = (e: PointerEvent) => {
      if (e.pointerType !== 'touch') return;
      // Only the picture (plus, in trackpad mode, the stage it sits in) drives
      // gestures — a touch that starts on the toolbar or a control is left
      // completely alone so its buttons keep working even while zoomed.
      if (e.target !== vid && !(trackpadRef.current && e.target === stageRef.current)) return;
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.size >= 2) {
        // Starting a pinch: if a single touch had passed through to the guest
        // forwarder, synth a pointercancel so its touch/button-down is released.
        if (g.passThrough != null) {
          // pointerType MUST be set: the forwarder routes on it, and an untyped
          // cancel takes the mouse branch, which releases the guest button but
          // never tells the touch engine its contact was stolen — leaving the
          // trackpad's tap-then-hold drag latched with nothing holding it.
          try { vid.dispatchEvent(new PointerEvent('pointercancel', { pointerId: g.passThrough, pointerType: 'touch', bubbles: true })); } catch { /* noop */ }
          g.passThrough = null;
        }
        const tp = twoPoints();
        if (tp) {
          // T-1 arbitration: DON'T assume pinch yet. Enter the '2f' detect state
          // and baseline both fingers; onMove classifies pinch vs scroll within
          // the first ~40ms/12px (classifyTwoFinger). The pinch baselines below
          // are kept so a pinch verdict starts without a jump.
          // In TRACKPAD mode there is nothing to arbitrate: two fingers belong to
          // the viewport, so commit to pinch/pan immediately and never send a
          // guest wheel.
          g.mode = trackpadRef.current ? 'pinch' : '2f';
          g.aStart = { x: tp[0].x, y: tp[0].y };
          g.bStart = { x: tp[1].x, y: tp[1].y };
          g.twoStartT = e.timeStamp;
          g.startDist = hypot(tp[0], tp[1]) || 1;
          g.startScale = g.s;
          g.startMid = mid(tp[0], tp[1]);
          g.startTx = g.x; g.startTy = g.y;
          g.scrollLast = g.startMid;
        }
        e.stopPropagation();
      } else if (g.s > 1.001 && !trackpadRef.current) {
        g.mode = 'pan';
        g.panStart = { x: e.clientX, y: e.clientY };
        g.startTx = g.x; g.startTy = g.y;
        e.stopPropagation();
      } else {
        g.mode = 'none';
        g.passThrough = e.pointerId; // let the guest forwarder own this touch
      }
    };

    const onMove = (e: PointerEvent) => {
      if (e.pointerType !== 'touch') return;
      const p = pointers.get(e.pointerId);
      if (!p) return;                       // only tracked (video-originated) touches
      p.x = e.clientX; p.y = e.clientY;
      // T-1 two-finger ARBITRATION: while '2f', watch the fingers and commit to
      // pinch (local zoom, unchanged) or scroll (guest wheel). Conservative —
      // ambiguous stays pinch, so the shipped pinch-to-zoom never regresses.
      if (g.mode === '2f' && pointers.size >= 2) {
        const tp = twoPoints();
        if (!tp) return;
        const kind = classifyTwoFinger(g.aStart, g.bStart, tp[0], tp[1], e.timeStamp - g.twoStartT);
        if (kind === 'pinch') {
          // Rebaseline from the CURRENT positions so the ≤12px detect pre-move
          // is never applied as a scale jump — pinch feels identical.
          g.mode = 'pinch';
          g.startDist = hypot(tp[0], tp[1]) || 1;
          g.startScale = g.s;
          g.startMid = mid(tp[0], tp[1]);
          g.startTx = g.x; g.startTy = g.y;
        } else if (kind === 'scroll') {
          g.mode = 'scroll';
          g.scrollLast = mid(tp[0], tp[1]);
        }
        e.stopPropagation();
        return;
      }
      if (g.mode === 'scroll' && pointers.size >= 2) {
        const tp = twoPoints();
        if (!tp) return;
        const m = mid(tp[0], tp[1]);
        const d = scrollWheelDelta(g.scrollLast, m);
        g.scrollLast = m;
        if (d.x || d.y) controlRef.current?.sendWheel(d.x, d.y);
        e.stopPropagation();
        return;
      }
      if (g.mode === 'pinch' && pointers.size >= 2) {
        const tp = twoPoints();
        if (!tp) return;
        const s = Math.min(3, Math.max(1, g.startScale * (hypot(tp[0], tp[1]) / g.startDist)));
        const m = mid(tp[0], tp[1]);
        const pan = clampPan(s, g.startTx + (m.x - g.startMid.x), g.startTy + (m.y - g.startMid.y));
        g.s = s; g.x = pan.x; g.y = pan.y;
        setZoom({ s, x: pan.x, y: pan.y, animated: false });
        e.stopPropagation();
      } else if (g.mode === 'pan' && pointers.size === 1 && g.s > 1.001) {
        const pan = clampPan(g.s, g.startTx + (e.clientX - g.panStart.x), g.startTy + (e.clientY - g.panStart.y));
        g.x = pan.x; g.y = pan.y;
        setZoom({ s: g.s, x: pan.x, y: pan.y, animated: false });
        e.stopPropagation();
      }
    };

    // pointerrawupdate is a SEPARATE event type: a pointermove stopPropagation does
    // not cover it, so block it explicitly during a gesture (else the raw-update
    // forwarder path could leak a move to the guest mid-pinch).
    const onRaw = (e: Event) => {
      const pe = e as PointerEvent;
      if (pe.pointerType === 'touch' && g.mode !== 'none') e.stopPropagation();
    };

    const onUp = (e: PointerEvent) => {
      if (e.pointerType !== 'touch') return;
      // ONLY A REAL LIFT ends a gesture. The pointercancel dispatched above to
      // release a passed-through touch is aimed at the guest forwarder, but it
      // bubbles back through this capture listener SYNCHRONOUSLY, mid-onDown —
      // and acting on it deleted the very finger the pinch was about to start
      // with, so twoPoints() came up empty and two-finger zoom stopped happening
      // altogether. It was invisible while the synth carried no pointerType (the
      // check above dropped it by accident); typing it correctly, which the touch
      // engine needs, made the eviction real.
      if (!e.isTrusted) return;
      if (!pointers.has(e.pointerId) && g.passThrough !== e.pointerId) return;
      const wasGesture = g.mode !== 'none';
      pointers.delete(e.pointerId);
      if (g.passThrough === e.pointerId) g.passThrough = null;
      // A two-finger scroll / arbitration ends the instant a finger lifts; the
      // survivor is NOT handed to the guest forwarder (its down was consumed).
      if ((g.mode === 'scroll' || g.mode === '2f') && pointers.size < 2) g.mode = 'none';
      if (wasGesture) e.stopPropagation();
      if (pointers.size === 1 && wasGesture && g.s > 1.001) {
        // Pinch → one finger left: KEEP PANNING, anchored on the survivor, until
        // it lifts too. A two-finger gesture rarely ends with both fingers
        // leaving at once, so ending the pan on the first lift stopped the view
        // dead mid-movement and left the last finger doing nothing. It is also
        // never handed to the trackpad: its pointerdown was consumed by the
        // gesture, so no contact was ever opened for it and a delta from here
        // would be a jump.
        const rest = pointers.values().next().value;
        if (rest) { g.mode = 'pan'; g.panStart = { x: rest.x, y: rest.y }; g.startTx = g.x; g.startTy = g.y; }
      } else if (pointers.size === 1) {
        g.mode = 'none'; // nothing left to pan (unzoomed): the survivor idles
      } else if (pointers.size === 0) {
        if (g.s > 1.001 || g.x !== 0 || g.y !== 0) {
          if (g.s < 1.1) {
            g.s = 1; g.x = 0; g.y = 0;
            setZoom({ s: 1, x: 0, y: 0, animated: true }); // snap back below 1.1×
          } else {
            const pan = clampPan(g.s, g.x, g.y);
            g.x = pan.x; g.y = pan.y;
            setZoom({ s: g.s, x: pan.x, y: pan.y, animated: true });
          }
        }
        g.mode = 'none';
      }
    };

    root.addEventListener('pointerdown', onDown, true);
    root.addEventListener('pointermove', onMove, true);
    root.addEventListener('pointerrawupdate', onRaw as EventListener, true);
    root.addEventListener('pointerup', onUp, true);
    root.addEventListener('pointercancel', onUp, true);
    return () => {
      root.removeEventListener('pointerdown', onDown, true);
      root.removeEventListener('pointermove', onMove, true);
      root.removeEventListener('pointerrawupdate', onRaw as EventListener, true);
      root.removeEventListener('pointerup', onUp, true);
      root.removeEventListener('pointercancel', onUp, true);
      pointers.clear();
    };
  }, [streamable, live, directCanvas]);
}

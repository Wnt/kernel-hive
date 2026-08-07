import { useEffect, useMemo, useRef } from 'react';
import { useLocation } from 'react-router-dom';
import { CatmullRomCurve3, PerspectiveCamera, Vector3 } from 'three';
import { useFrame, useThree, invalidate } from '@react-three/fiber';
import { shotFromUrl } from './shots';
import type { HallLayout } from './hallLayout';
import {
  setCurrentRailT,
  subscribeHoverZoom,
  subscribeRailApproach,
  subscribeRailDebugJump,
  type RailTarget,
} from './railNavigation';

// ============================================================================
//  SCENE V2 — rail camera (director's navigation model, 2026-07-28)
//  ---------------------------------------------------------------------------
//  The room is NOT freely roamable. The camera rides a fixed closed loop
//  through the corridors; the ONLY input is a left-button (or one-finger)
//  swipe: horizontal drag travels along the loop with momentum, vertical drag
//  bobs the eye height a little so it feels alive. No orbit, no pan, no
//  zoom, no secondary buttons, no collision system — the rail IS the
//  constraint. ?shot=<name> still pins a static pose for the harness.
// ============================================================================

const FOV_LANDSCAPE = 38; // editorial architectural feel when aspect >= 1
const FOV_PORTRAIT = 44; // preserve phone context without stretching frame edges
const EYE_BASE = 1.55; // resting eye height
const EYE_MIN = -0.25; // bob range below base…
const EYE_MAX = 0.35; // …and above it
const LOOK_HEIGHT = 0.95; // gaze settles on machine height (review r1: was 1.05, archive row sat low)
const DRAG_TO_T = 0.00022; // px of horizontal drag → loop fraction
const DRAG_TO_H = 0.0022; // px of vertical drag → meters of eye bob
const FRICTION = 3.2; // 1/s — momentum decay
const WHEEL_TO_T = 0.00009; // wheel deltaY px → loop fraction (scroll = travel)
const HOVER_DOLLY = 0.025;
const HOVER_FOV_SCALE = 0.975;
const wrap = (t: number) => ((t % 1) + 1) % 1;

// ?railT=<0..1> pins the camera exactly on the rail at that loop fraction —
// same pose the rider sees at that t. Harness hook for frame-series review.
function railTFromUrl(search: string): number | null {
  const raw = new URLSearchParams(search).get('railT');
  if (raw === null) return null;
  const t = Number(raw);
  return Number.isFinite(t) ? wrap(t) : null;
}

export default function CameraRig({
  layout,
  onRailMove,
}: {
  layout: HallLayout;
  onRailMove: () => void;
}) {
  const { camera, gl, size } = useThree();
  const { search, state: locationState } = useLocation();
  const baseFov = useRef(FOV_LANDSCAPE);

  // Portrait viewports widen modestly so machines retain context without the
  // edge stretch of the old panoramic response. Blend 38 -> 44 from aspect
  // 1 to 0.5, keeping both endpoints near the architectural-photo range.
  useEffect(() => {
    if (!(camera instanceof PerspectiveCamera)) return;
    const aspect = size.width / size.height;
    const fov =
      aspect >= 1
        ? FOV_LANDSCAPE
        : FOV_LANDSCAPE + (FOV_PORTRAIT - FOV_LANDSCAPE) * Math.min(1, (1 - aspect) / 0.5);
    if (camera.fov !== fov) {
      baseFov.current = fov;
      camera.fov = fov;
      camera.updateProjectionMatrix();
      invalidate();
    }
  }, [camera, size]);
  const curve = useMemo(() => {
    const c = new CatmullRomCurve3(
      layout.railSpec.loop.map((point) => new Vector3(...point)),
      true,
      'centripetal',
    );
    c.arcLengthDivisions = 400;
    return c;
  }, [layout]);
  const lookCurve = useMemo(() => {
    const c = new CatmullRomCurve3(
      layout.railSpec.look.map((point) => new Vector3(...point)),
      true,
      'centripetal',
    );
    c.arcLengthDivisions = 400;
    return c;
  }, [layout]);

  // rail state in refs — mutated by input handlers, consumed by useFrame
  const st = useRef({
    t: 0.13,
    vel: 0,
    bob: 0,
    bobTarget: 0,
    pinned: false,
    targetT: null as number | null,
    hoverTarget: null as RailTarget | null,
    hoverMix: 0,
    dragging: false,
  });
  const scratch = useRef({
    pos: new Vector3(),
    look: new Vector3(),
    hover: new Vector3(),
  });
  const restoredRailApplied = useRef(false);

  // ?shot= pins a static pose for the screenshot harness / deep links;
  // ?railT= pins the exact riding pose at a loop fraction (frame-series hook)
  useEffect(() => {
    const shot = shotFromUrl(search, layout);
    const railT = railTFromUrl(search);
    st.current.pinned = !!shot || railT !== null;
    if (shot) {
      camera.position.set(...shot.position);
      camera.lookAt(...shot.target);
    } else if (railT !== null) {
      st.current.t = railT;
      setCurrentRailT(railT);
      const pos = curve.getPointAt(railT, new Vector3());
      pos.y = EYE_BASE;
      camera.position.copy(pos);
      const look = lookCurve.getPoint(curve.getUtoTmapping(railT, 0), new Vector3());
      look.y += LOOK_HEIGHT; // curve y carries the per-node height delta
      camera.lookAt(look);
    } else if (!restoredRailApplied.current) {
      const restored = museumRailTFromState(locationState);
      restoredRailApplied.current = true;
      if (restored !== null) {
        st.current.t = restored;
        setCurrentRailT(restored);
        const pos = curve.getPointAt(restored, new Vector3());
        pos.y = EYE_BASE;
        camera.position.copy(pos);
        const look = lookCurve.getPoint(curve.getUtoTmapping(restored, 0), new Vector3());
        look.y += LOOK_HEIGHT;
        camera.lookAt(look);
      }
    }
    invalidate();
  }, [search, locationState, camera, curve, lookCurve, size, layout]);

  useEffect(() => subscribeRailApproach((target) => {
    const s = st.current;
    s.targetT = railTForTarget(curve, lookCurve, target);
    s.vel = 0;
    s.pinned = false;
    invalidate();
  }), [curve, lookCurve]);

  useEffect(() => subscribeRailDebugJump((railT) => {
    const s = st.current;
    s.t = wrap(railT);
    s.targetT = null;
    s.vel = 0;
    s.pinned = false;
    const pos = curve.getPointAt(s.t, new Vector3());
    pos.y = EYE_BASE + s.bob;
    camera.position.copy(pos);
    const look = lookCurve.getPoint(curve.getUtoTmapping(s.t, 0), new Vector3());
    look.y += LOOK_HEIGHT + s.bob * 0.5;
    camera.lookAt(look);
    setCurrentRailT(s.t);
    invalidate();
  }), [camera, curve, lookCurve]);

  useEffect(() => subscribeHoverZoom((target) => {
    st.current.hoverTarget = target;
    invalidate();
  }), []);

  useEffect(() => {
    if (!import.meta.env.DEV || !(camera instanceof PerspectiveCamera)) return undefined;
    const debugWindow = window as typeof window & {
      __museumCameraDebug?: () => {
        fov: number;
        position: [number, number, number];
        direction: [number, number, number];
      };
    };
    debugWindow.__museumCameraDebug = () => ({
      fov: camera.fov,
      position: camera.position.toArray() as [number, number, number],
      direction: camera.getWorldDirection(new Vector3()).toArray() as [number, number, number],
    });
    return () => {
      delete debugWindow.__museumCameraDebug;
    };
  }, [camera]);

  // single-gesture input: left button / one finger, nothing else
  useEffect(() => {
    const el = gl.domElement;
    let dragging = false;
    let lastX = 0;
    let lastY = 0;
    const down = (e: PointerEvent) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      dragging = true;
      st.current.dragging = true;
      lastX = e.clientX;
      lastY = e.clientY;
      el.setPointerCapture(e.pointerId);
    };
    const move = (e: PointerEvent) => {
      if (!dragging) return;
      const dx = e.clientX - lastX;
      const dy = e.clientY - lastY;
      if (dx !== 0 || dy !== 0) onRailMove();
      lastX = e.clientX;
      lastY = e.clientY;
      const s = st.current;
      s.t = wrap(s.t + dx * DRAG_TO_T);
      s.vel = dx * DRAG_TO_T * 60; // carry momentum from the last movement
      s.bobTarget = Math.min(EYE_MAX, Math.max(EYE_MIN, s.bobTarget - dy * DRAG_TO_H));
      invalidate();
    };
    const up = () => {
      dragging = false;
      st.current.dragging = false;
      invalidate();
    };
    const kill = (e: Event) => e.preventDefault();
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      onRailMove();
      // normalize line-mode deltas (Firefox) to pixel-ish units
      const dy = e.deltaMode === 1 ? e.deltaY * 16 : e.deltaY;
      const s = st.current;
      s.t = wrap(s.t + dy * WHEEL_TO_T);
      s.vel = dy * WHEEL_TO_T * 30; // gentle carry so notches glide together
      invalidate();
    };
    el.addEventListener('pointerdown', down);
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
    el.addEventListener('contextmenu', kill); // no right-button anything
    el.addEventListener('wheel', wheel, { passive: false }); // scroll = travel the rail
    return () => {
      el.removeEventListener('wheel', wheel);
      el.removeEventListener('pointerdown', down);
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', up);
      el.removeEventListener('contextmenu', kill);
    };
  }, [gl, onRailMove]);

  useFrame((_, rawDt) => {
    const s = st.current;
    if (s.pinned) return;
    const dt = Math.min(rawDt, 0.05);
    if (s.targetT !== null) {
      const delta = shortestWrappedDelta(s.t, s.targetT);
      if (Math.abs(delta) < 0.00008) {
        s.t = s.targetT;
        s.targetT = null;
      } else {
        s.t = wrap(s.t + delta * Math.min(1, dt * 2.8));
        s.vel = 0;
        invalidate();
      }
    }
    // momentum with decay; keep invalidating while it rolls
    if (Math.abs(s.vel) > 0.00001) {
      s.t = wrap(s.t + s.vel * dt);
      s.vel *= Math.max(0, 1 - FRICTION * dt);
      invalidate();
    }
    // eased eye bob
    if (Math.abs(s.bobTarget - s.bob) > 0.0005) invalidate();
    s.bob += (s.bobTarget - s.bob) * Math.min(1, dt * 6);
    const { pos, look, hover } = scratch.current;
    curve.getPointAt(s.t, pos);
    pos.y = EYE_BASE + s.bob;
    lookCurve.getPoint(curve.getUtoTmapping(s.t, 0), look);
    look.y += LOOK_HEIGHT + s.bob * 0.5; // curve y = per-node height delta
    const hoverGoal = s.hoverTarget && !s.dragging ? 1 : 0;
    if (Math.abs(hoverGoal - s.hoverMix) > 0.001) invalidate();
    s.hoverMix += (hoverGoal - s.hoverMix) * Math.min(1, dt * 8);
    if (s.hoverTarget && s.hoverMix > 0.001) {
      hover.set(...s.hoverTarget);
      pos.lerp(hover, HOVER_DOLLY * s.hoverMix);
      look.lerp(hover, 0.12 * s.hoverMix);
    }
    camera.position.copy(pos);
    camera.lookAt(look);
    if (camera instanceof PerspectiveCamera) {
      const fov = baseFov.current
        * (1 - (1 - HOVER_FOV_SCALE) * s.hoverMix);
      if (Math.abs(camera.fov - fov) > 0.001) {
        camera.fov = fov;
        camera.updateProjectionMatrix();
      }
    }
    setCurrentRailT(s.t);
  });

  return null;
}

function museumRailTFromState(state: unknown): number | null {
  if (typeof state !== 'object' || state === null) return null;
  const value = (state as { museumRailT?: unknown }).museumRailT;
  return typeof value === 'number' && Number.isFinite(value) ? wrap(value) : null;
}

function railTForTarget(
  curve: CatmullRomCurve3,
  lookCurve: CatmullRomCurve3,
  target: RailTarget,
): number {
  const point = new Vector3();
  const look = new Vector3();
  const gaze = new Vector3();
  const toTarget = new Vector3();
  const targetPoint = new Vector3(...target);
  let bestT = 0;
  let bestScore = Infinity;
  for (let index = 0; index < 800; index += 1) {
    const t = index / 800;
    curve.getPointAt(t, point);
    point.y = EYE_BASE;
    lookCurve.getPoint(curve.getUtoTmapping(t, 0), look);
    look.y += LOOK_HEIGHT;
    gaze.subVectors(look, point).normalize();
    toTarget.subVectors(targetPoint, point);
    const distance = toTarget.length();
    const score = gaze.angleTo(toTarget.normalize()) * 10 + distance * 0.02;
    if (score < bestScore) {
      bestScore = score;
      bestT = t;
    }
  }
  return bestT;
}

function shortestWrappedDelta(from: number, to: number) {
  return ((to - from + 0.5) % 1 + 1) % 1 - 0.5;
}
